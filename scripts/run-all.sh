#!/bin/bash
set -euo pipefail

# ============================================================
# VOC - One Script To Run Everything
# Creates the cluster, deploys the stack, waits for readiness,
# starts port-forwards, and (on a first run) kicks off scans.
#
# Warm-start design
# -----------------
# The expensive parts of a start are almost always no-ops on the second
# run: `helm repo update`, `helm upgrade` on an unchanged release, docker
# build, `k3d image import`, and the full 10-12 min scan pipeline. Each
# one is now guarded:
#
#   * component deploys are skipped when the release is installed, healthy
#     and its values file hash matches what was last applied to THIS
#     cluster (see the state cache in toolbox/profile.sh)
#   * deploys and readiness waits run in parallel instead of in series
#   * API keys are only re-provisioned when the existing ones do not work
#   * scans run automatically on first setup only
#
# Environment switches:
#   VOC_FORCE_DEPLOY=1       redeploy everything, ignore the state cache
#   VOC_SCAN_ON_START=1|0    force scans on / off (default: first run only)
#   VOC_ENABLE_MONITORING=1  bring up Grafana + Prometheus (off by default)
#   VOC_ENABLE_WAZUH=1       bring up the Wazuh manager (off by default)
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[VOC]${NC} $1"; }
log_success() { echo -e "${GREEN}[VOC]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[VOC]${NC} $1"; }
log_error()   { echo -e "${RED}[VOC]${NC} $1"; }
log_section() { echo -e "\n${CYAN}══════════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}══════════════════════════════════════════════════════${NC}\n"; }

RUN_START=$SECONDS

# Load .env
if [ -f /workspace/.env ]; then
  set -a; . /workspace/.env; set +a
fi

# Load profile functions (also brings in the deployment state cache)
source /workspace/toolbox/profile.sh

# ==========================================
# Helpers
# ==========================================

# wait_ready <kind> <name> <ns> <timeout-sec> <label>
# Waits for the object to exist, then for its rollout to finish. Replaces
# the old hand-rolled `for i in $(seq 1 180); sleep 5` loops, which cost up
# to 5s of latency per service even when everything was already up.
wait_ready() {
  local kind="$1" name="$2" ns="$3" timeout="$4" label="$5"
  local deadline=$((SECONDS + timeout))

  while [ "$SECONDS" -lt "$deadline" ]; do
    kubectl get "$kind" "$name" -n "$ns" >/dev/null 2>&1 && break
    sleep 3
  done

  local remaining=$((deadline - SECONDS))
  [ "$remaining" -lt 5 ] && remaining=5

  if kubectl rollout status "$kind/$name" -n "$ns" --timeout="${remaining}s" >/dev/null 2>&1; then
    log_success "$label is ready"
    return 0
  fi
  log_warning "$label did not become ready within ${timeout}s"
  return 1
}

# Run a deploy step in the background, buffering its output so parallel
# steps do not interleave their logs into an unreadable mess.
PARALLEL_PIDS=(); PARALLEL_LOGS=(); PARALLEL_LABELS=()
spawn() {
  local label="$1"; shift
  local logfile; logfile=$(mktemp)
  ( "$@" ) >"$logfile" 2>&1 &
  PARALLEL_PIDS+=($!); PARALLEL_LOGS+=("$logfile"); PARALLEL_LABELS+=("$label")
}

join_all() {
  local i rc
  for i in "${!PARALLEL_PIDS[@]}"; do
    rc=0; wait "${PARALLEL_PIDS[$i]}" || rc=$?
    echo -e "${CYAN}--- ${PARALLEL_LABELS[$i]} ---${NC}"
    sed 's/^/  /' "${PARALLEL_LOGS[$i]}" 2>/dev/null || true
    rm -f "${PARALLEL_LOGS[$i]}"
    [ "$rc" -ne 0 ] && log_warning "${PARALLEL_LABELS[$i]} exited with status $rc (continuing)"
  done
  PARALLEL_PIDS=(); PARALLEL_LOGS=(); PARALLEL_LABELS=()
}

# ==========================================
# PHASE 1: CLUSTER
# ==========================================
log_section "PHASE 1: Kubernetes Cluster"

if k3d cluster list voc 2>/dev/null | grep -q "voc"; then
  # Cluster exists in k3d's records — but is it actually reachable?
  if kubectl get nodes >/dev/null 2>&1; then
    log_success "k3d cluster 'voc' is running and reachable"
  else
    log_info "Attempting to start stopped k3d cluster 'voc'..."
    k3d cluster start voc 2>/dev/null || true
    # Poll instead of a flat sleep — a warm cluster answers in ~1-2s.
    for _ in $(seq 1 15); do
      kubectl get nodes >/dev/null 2>&1 && break
      sleep 1
    done
    if kubectl get nodes >/dev/null 2>&1; then
      log_success "k3d cluster 'voc' started successfully!"
    else
      log_warning "k3d cluster 'voc' is stale/unreachable even after start. Recreating..."
      k3d cluster delete voc 2>/dev/null || true
      docker network rm voc 2>/dev/null || true
      voc_up
    fi
  fi
else
  log_info "Creating k3d cluster..."
  voc_up
fi

# Final verify
if ! kubectl get nodes >/dev/null 2>&1; then
  log_error "Cluster still not reachable after setup. Exiting."
  exit 1
fi
log_success "Cluster is reachable"

# ==========================================
# PHASE 2: DEPLOY
#
# Independent components deploy concurrently. DefectDojo is the long pole
# (2-5 min cold), so everything else overlaps with it rather than queueing
# behind it.
# ==========================================
log_section "PHASE 2: Deploying Services"

# Is this a first run against this cluster, or a warm restart? Drives both
# the "skip the scan" decision and how loudly we narrate the wait.
FRESH_DEPLOY=1
if _voc_deploy_ready voc-core defectdojo-django && _voc_deploy_ready voc-core n8n; then
  FRESH_DEPLOY=0
  log_success "Existing deployment detected — taking the warm path"
else
  log_info "No healthy deployment found — running full setup (5-10 min)"
fi

log_info "Creating namespaces..."
kubectl apply -f /workspace/k8s/namespaces/namespaces.yaml >/dev/null 2>&1 || true

# Grafana/Prometheus is off by default now. If a previous run left the
# kube-prometheus-stack behind, take it down once to reclaim ~2 GB of RAM
# and its PVCs. Files and `voc-deploy monitoring` are untouched.
if [ "$VOC_ENABLE_MONITORING" != "1" ] && helm status kps -n monitoring >/dev/null 2>&1; then
  log_warning "Monitoring is disabled but kube-prometheus-stack is installed — removing it to free resources"
  voc_deploy no-monitoring 2>&1 | sed 's/^/  /' || true
fi

# Add every Helm repo serially FIRST. `helm repo add` rewrites
# repositories.yaml as a whole, so letting the parallel deploys below race
# on it can silently drop a repo. Once added, the calls inside voc_deploy
# short-circuit on a read-only check.
log_info "Ensuring Helm repositories..."
voc_helm_repo_ready defectdojo https://raw.githubusercontent.com/DefectDojo/django-DefectDojo/helm-charts || true
voc_helm_repo_ready community-charts https://community-charts.github.io/helm-charts || true
if [ "$VOC_ENABLE_MONITORING" = "1" ]; then
  voc_helm_repo_ready prometheus-community https://prometheus-community.github.io/helm-charts || true
fi

log_info "Deploying components in parallel..."
spawn "DefectDojo"  voc_deploy dd
spawn "n8n"         voc_deploy n8n
spawn "targets"     voc_deploy targets
spawn "TheHive"     voc_deploy thehive
spawn "prioritization" voc_deploy prio
if [ "$VOC_ENABLE_WAZUH" = "1" ]; then spawn "Wazuh" voc_deploy wazuh; fi
if [ "$VOC_ENABLE_MONITORING" = "1" ]; then spawn "monitoring" voc_deploy monitoring; fi

# Pre-pull scanner images alongside the deploys (skipped automatically once
# they are already on the k3d node).
spawn "scanner images" voc_prepull

join_all

# ==========================================
# PHASE 3: WAIT FOR READINESS
#
# All waits run concurrently. Total wall time is now the slowest single
# service rather than the sum of every service's wait.
# ==========================================
log_section "PHASE 3: Waiting For Services"

DD_TIMEOUT=900; [ "$FRESH_DEPLOY" = "0" ] && DD_TIMEOUT=180

wait_ready statefulset defectdojo-postgresql voc-core 300 "PostgreSQL" &
PG_PID=$!
wait_ready deployment defectdojo-django voc-core "$DD_TIMEOUT" "DefectDojo" &
DD_PID=$!
wait_ready deployment n8n voc-core 300 "n8n" &
N8N_PID=$!
wait_ready deployment thehive voc-core 300 "TheHive" &
TH_PID=$!
if [ "$VOC_ENABLE_WAZUH" = "1" ]; then
  wait_ready deployment wazuh-manager voc-core 600 "Wazuh manager" &
  WZ_PID=$!
fi
(
  kubectl wait --for=condition=Ready pod -n targets --all --timeout=180s >/dev/null 2>&1 \
    && log_success "Targets are ready!" \
    || log_warning "Some targets not ready"
) &
TG_PID=$!

wait "$PG_PID" || true
DD_READY=1; wait "$DD_PID" || DD_READY=0
wait "$N8N_PID" || true
wait "$TH_PID" || true
wait "$TG_PID" || true
if [ -n "${WZ_PID:-}" ]; then wait "$WZ_PID" || true; fi

if [ "$DD_READY" -eq 0 ]; then
  log_error "DefectDojo not ready. Current pod status:"
  kubectl get pods -n voc-core --no-headers 2>/dev/null || true
  log_error "Check logs: kubectl logs -n voc-core deploy/defectdojo-django"
  log_warning "Port-forwards and scans will not work until DefectDojo is running."
  log_warning "Wait for pods to be Running, then run: voc-run-all"
fi

# ==========================================
# PHASE 4: PORT FORWARDS
#
# Moved ahead of key provisioning: with the tunnel already up we can test
# the API key we already have over localhost, and skip re-minting it.
# ==========================================
log_section "PHASE 4: Port Forwards"

if [ "$DD_READY" -eq 0 ]; then
  log_warning "Skipping port-forwards — DefectDojo is not ready yet."
  log_warning "Once pods are Running, run: voc-run-all"
else
  log_info "Starting port-forwards (DefectDojo:8080, n8n:5678, Juice Shop:3000, TheHive:9000)..."
  _voc_start_pf voc-core defectdojo-django 8080:80
  _voc_start_pf voc-core n8n 5678:5678
  _voc_start_pf targets juice-shop 3000:3000
  _voc_start_pf voc-core thehive-svc 9000:9000
  if [ "$VOC_ENABLE_WAZUH" = "1" ]; then _voc_start_pf voc-core wazuh-manager 55000:55000; fi
  if [ "$VOC_ENABLE_MONITORING" = "1" ] && kubectl get svc -n monitoring kps-grafana >/dev/null 2>&1; then
    _voc_start_pf monitoring kps-grafana 3001:80
    log_info "Grafana port-forward started on :3001"
  fi

  # Poll rather than sleeping a flat 3s — the tunnel usually binds in <1s.
  PF_OK=0
  for _ in $(seq 1 15); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://localhost:8080/" 2>/dev/null) || HTTP_CODE="000"
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
      PF_OK=1
      log_success "DefectDojo is reachable at http://localhost:8080"
      break
    fi
    sleep 1
  done
  [ "$PF_OK" -eq 0 ] && log_warning "Port-forward not responding yet. Try: voc-scan"
fi

# ==========================================
# PHASE 5: CREDENTIALS
#
# Every provisioning step here is guarded by a "does it already work?"
# check. On a warm start this phase costs a couple of API calls instead of
# a dozen `kubectl exec`s into Django and TheHive.
# ==========================================
log_section "PHASE 5: Configuration"

DD_PASS=$(kubectl get secret defectdojo -n voc-core -o jsonpath='{.data.DD_ADMIN_PASSWORD}' 2>/dev/null | base64 --decode) || DD_PASS="unknown"

# --- DefectDojo API key ---
dd_key_works() {
  [ -n "${1:-}" ] || return 1
  [ "$1" != "changeme" ] || return 1
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    -H "Authorization: Token $1" "http://localhost:8080/api/v2/findings/?limit=1" 2>/dev/null) || return 1
  [ "$code" = "200" ]
}

if dd_key_works "${DD_API_KEY:-}"; then
  log_success "Existing DefectDojo API key still valid — skipping provisioning"
  export DD_API_KEY
else
  log_info "Fetching DefectDojo API key from cluster..."
  FETCHED_KEY=""
  for _ in $(seq 1 5); do
    FETCHED_KEY=$(kubectl exec deploy/defectdojo-django -n voc-core -c uwsgi -- \
      python manage.py drf_create_token admin 2>/dev/null | grep -oE '[a-f0-9]{40}' | head -1) || true
    [ -n "$FETCHED_KEY" ] && break
    sleep 3
  done
  if [ -n "$FETCHED_KEY" ]; then
    export DD_API_KEY="$FETCHED_KEY"
    log_success "API key fetched: ${FETCHED_KEY:0:8}..."
    if grep -q '^DD_API_KEY=' /workspace/.env 2>/dev/null; then
      sed -i "s|^DD_API_KEY=.*|DD_API_KEY=$FETCHED_KEY|" /workspace/.env
    else
      echo "DD_API_KEY=$FETCHED_KEY" >> /workspace/.env
    fi
  fi
fi

# --- TheHive org user + API key ---
# The platform admin (admin@thehive.local) has the "admin" profile, which
# CANNOT create alerts or cases. n8n must authenticate as an ORG user with
# the org-admin profile, so we ensure the "voc" org + vocadmin user exist
# and then mint a key for vocadmin. All of it is skipped when the secret is
# already in place and .env already carries a matching key.
if kubectl get secret thehive-creds -n voc-core >/dev/null 2>&1 && [ -n "${THEHIVE_API_KEY:-}" ]; then
  log_success "TheHive credentials already provisioned — skipping"
  THEHIVE_KEY="$THEHIVE_API_KEY"
else
  log_info "Provisioning TheHive org user + API key..."
  THEHIVE_KEY=""
  for _ in $(seq 1 10); do
    # Org (fails silently if it already exists)
    kubectl exec deploy/thehive -n voc-core -c thehive -- \
      curl -sf -X POST -u admin@thehive.local:secret \
      -H 'Content-Type: application/json' \
      http://localhost:9000/api/v1/organisation \
      -d '{"name":"voc","description":"VOC Security Operations"}' >/dev/null 2>&1 || true
    # Org user with org-admin profile (has manageAlert/create)
    kubectl exec deploy/thehive -n voc-core -c thehive -- \
      curl -sf -X POST -u admin@thehive.local:secret \
      -H 'Content-Type: application/json' \
      http://localhost:9000/api/v1/user \
      -d '{"login":"vocadmin@thehive.local","name":"VOC Admin","profile":"org-admin","organisation":"voc","password":"vocadmin123"}' >/dev/null 2>&1 || true
    THEHIVE_KEY=$(kubectl exec deploy/thehive -n voc-core -c thehive -- \
      curl -s -X POST -u admin@thehive.local:secret http://localhost:9000/api/v1/user/vocadmin@thehive.local/key/renew 2>/dev/null) || true
    [[ "$THEHIVE_KEY" =~ ^[a-zA-Z0-9]{32}$ ]] && break
    THEHIVE_KEY=""
    sleep 3
  done

  if [ -n "$THEHIVE_KEY" ]; then
    export THEHIVE_API_KEY="$THEHIVE_KEY"
    log_success "TheHive API key fetched: ${THEHIVE_KEY:0:8}..."
    kubectl -n voc-core create secret generic thehive-creds \
      --from-literal=api-key="$THEHIVE_KEY" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
    if grep -q '^THEHIVE_API_KEY=' /workspace/.env 2>/dev/null; then
      sed -i "s|^THEHIVE_API_KEY=.*|THEHIVE_API_KEY=$THEHIVE_KEY|" /workspace/.env
    else
      echo "THEHIVE_API_KEY=$THEHIVE_KEY" >> /workspace/.env
    fi
  else
    log_warning "Could not auto-fetch TheHive API key. n8n workflow alerts might fail."
  fi
fi

# ==========================================
# PHASE 5b: SCAN ORCHESTRATOR + n8n CREDENTIALS
#
# n8n triggers scans by launching the scan-orchestrator Job through the K8s
# API, so that Job needs its image in k3d, RBAC, and the DefectDojo
# credentials secret. n8n reads DD_API_KEY from a secret at pod start only,
# so it must be restarted AFTER the secret changes — but only then, because
# a restart costs ~40s and drops the port-forward.
# ==========================================
log_section "PHASE 5b: Scan Orchestrator Setup"

if [ -n "${DD_API_KEY:-}" ] && [ "${DD_API_KEY:-}" != "changeme" ]; then
  # Rebuild the orchestrator image only when what goes into it changed.
  ORCH_FP=$(_voc_sha /workspace/orchestrator/Dockerfile /workspace/scripts/*.sh /workspace/scripts/*.py /workspace/scanners/*.yaml)
  if [ "${VOC_FORCE_DEPLOY:-0}" = "1" ] || ! _voc_unchanged orchestrator-image "$ORCH_FP"; then
    log_info "Building voc-orchestrator image (for n8n-triggered scans)..."
    if docker build -q -t voc-orchestrator:latest -f /workspace/orchestrator/Dockerfile /workspace >/dev/null 2>&1; then
      if k3d image import voc-orchestrator:latest -c "${K3D_CLUSTER_NAME:-voc}" >/dev/null 2>&1; then
        log_success "Orchestrator image imported into k3d"
        _voc_mark_applied orchestrator-image "$ORCH_FP"
      else
        log_warning "k3d image import failed — n8n-triggered scans may not start"
      fi
    else
      log_warning "Orchestrator image build failed — n8n-triggered scans may not start"
    fi
  else
    log_success "Orchestrator image unchanged — skipping build/import"
  fi

  kubectl apply -f /workspace/scanners/orchestrator-rbac.yaml >/dev/null 2>&1 || true

  # Only touch the secrets (and restart n8n) when the credentials actually
  # changed. CREDS_FP covers both keys, so a rotated key still triggers it.
  CREDS_FP=$(printf '%s:%s' "${DD_API_KEY:-}" "${THEHIVE_KEY:-}" | sha256sum | cut -d' ' -f1)
  if [ "${VOC_FORCE_DEPLOY:-0}" = "1" ] || ! _voc_unchanged n8n-creds "$CREDS_FP"; then
    log_info "Provisioning DefectDojo credentials for n8n + orchestrator..."
    for ns in voc-core scanning; do
      kubectl -n "$ns" create secret generic defectdojo-creds \
        --from-literal=url=http://defectdojo-django.voc-core.svc.cluster.local \
        --from-literal=api-key="$DD_API_KEY" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
    done
    log_success "defectdojo-creds secrets provisioned"

    log_info "Restarting n8n to pick up credentials..."
    kubectl rollout restart deployment/n8n -n voc-core >/dev/null 2>&1 || true
    if kubectl rollout status deployment/n8n -n voc-core --timeout=120s >/dev/null 2>&1; then
      log_success "n8n restarted with credentials"
      # The old pod's tunnel died with it.
      _voc_start_pf voc-core n8n 5678:5678
    else
      log_warning "n8n restart timed out — check: kubectl get pods -n voc-core"
    fi

    # Keep the prioritization service's key in step with DefectDojo's.
    kubectl -n voc-core create secret generic prioritization-secrets \
      --from-literal=DEFECTDOJO_API_KEY="$DD_API_KEY" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
    kubectl rollout restart deployment/prioritization-service -n voc-core >/dev/null 2>&1 || true

    if [ "$VOC_ENABLE_MONITORING" = "1" ]; then
      kubectl -n monitoring create secret generic defectdojo-creds \
        --from-literal=api-key="$DD_API_KEY" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
      kubectl rollout restart deployment/voc-metrics-exporter -n monitoring >/dev/null 2>&1 || true
    fi

    _voc_mark_applied n8n-creds "$CREDS_FP"
  else
    log_success "Credentials unchanged — skipping secret refresh and n8n restart"
  fi
else
  log_warning "Skipping orchestrator setup — DD_API_KEY not available"
fi

# ==========================================
# PHASE 6: SCANS
#
# Default: run on first setup only. A warm restart drops you straight into
# the shell — run `voc-scan` when you actually want fresh findings.
# ==========================================
log_section "PHASE 6: Vulnerability Scans"

SHOULD_SCAN="${VOC_SCAN_ON_START:-auto}"
if [ "$SHOULD_SCAN" = "auto" ]; then
  SHOULD_SCAN=$([ "$FRESH_DEPLOY" = "1" ] && echo 1 || echo 0)
fi

if [ "$SHOULD_SCAN" != "1" ]; then
  log_info "Skipping scans (warm start). Run 'voc-scan' when you want fresh results,"
  log_info "or start with VOC_SCAN_ON_START=1 to always scan."
elif [ -n "${DD_API_KEY:-}" ] && [ "${DD_API_KEY:-}" != "changeme" ]; then
  log_info "Starting scan pipeline..."
  export DD_API_KEY
  bash /workspace/scripts/scan-all.sh 2>&1 || log_warning "Some scans may have failed — check output above"

  # Score the fresh findings so DefectDojo shows context-aware priorities
  # immediately instead of waiting for the hourly pass.
  if _voc_deploy_ready voc-core prioritization-service; then
    log_info "Running prioritization pass over the new findings..."
    voc_prio 2>&1 | sed 's/^/  /' || log_warning "Prioritization pass failed (non-critical)"
  fi
else
  log_warning "Skipping scans — DD_API_KEY not configured yet"
  log_warning "After setting the API key in .env, run: voc-scan"
fi

# ==========================================
# DONE
# ==========================================
log_section "ALL DONE!"

TOTAL=$((SECONDS - RUN_START))
log_success "Startup completed in $((TOTAL / 60))m $((TOTAL % 60))s"

echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  VOC is fully running!                                   ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}║  DefectDojo:  http://localhost:8080                      ║${NC}"
echo -e "${GREEN}║    User: admin  Password: ${DD_PASS:-check above}${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}║  n8n:         http://localhost:5678                      ║${NC}"
echo -e "${GREEN}║  Juice Shop:  http://localhost:3000                      ║${NC}"
echo -e "${GREEN}║  TheHive:     http://localhost:9000                      ║${NC}"
if [ "$VOC_ENABLE_WAZUH" = "1" ]; then
echo -e "${GREEN}║  Wazuh API:   https://localhost:55000                    ║${NC}"
fi
if [ "$VOC_ENABLE_MONITORING" = "1" ]; then
echo -e "${GREEN}║  Grafana:     http://localhost:3001                      ║${NC}"
fi
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}║  Run 'voc-scan'    to run scans                          ║${NC}"
echo -e "${GREEN}║  Run 'voc-prio'    to re-prioritize findings             ║${NC}"
echo -e "${GREEN}║  Run 'voc-assets'  to see asset criticality              ║${NC}"
echo -e "${GREEN}║  Run 'voc-status'  to check cluster                      ║${NC}"
echo -e "${GREEN}║  Run 'voc-help'    for everything else                   ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"

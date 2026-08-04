#!/bin/bash
# VOC helper functions — sourced by entrypoint.sh and available in the shell.

export KUBECONFIG="${KUBECONFIG:-/workspace/.kube/config}"
export REPO_DIR="/workspace"

# --- Feature switches -------------------------------------------------
# Grafana/Prometheus is off by default: kube-prometheus-stack costs ~2 GB
# of RAM plus a 20 Gi PVC, and DefectDojo + n8n already show everything
# this lab needs. Nothing was deleted — set VOC_ENABLE_MONITORING=1 (or
# run `voc-deploy monitoring`) to bring it back.
export VOC_ENABLE_MONITORING="${VOC_ENABLE_MONITORING:-0}"
# Wazuh (SIEM) is opt-in for the same reason: it is the single heaviest
# component in the stack. `voc-deploy wazuh` or VOC_ENABLE_WAZUH=1.
export VOC_ENABLE_WAZUH="${VOC_ENABLE_WAZUH:-0}"

# ======================================================================
# Deployment state cache
#
# Everything below exists to answer one question fast: "is this component
# already deployed, from exactly these inputs, into exactly this cluster?"
# If yes we skip the work entirely — that is where the warm-start time
# goes (helm repo update, helm upgrade, docker build, k3d image import all
# cost 30-90s each and are almost always no-ops).
#
# State is keyed on the kube-system namespace UID, so a `voc-down` +
# `voc-up` (new cluster, new UID) invalidates every entry automatically
# and the next start does a full deploy.
# ======================================================================
VOC_STATE_DIR="${VOC_STATE_DIR:-$REPO_DIR/.voc-state}"

_voc_cluster_id() {
  # Cached per shell — this is called once per component check.
  if [ -z "${_VOC_CLUSTER_ID:-}" ]; then
    _VOC_CLUSTER_ID=$(kubectl get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")
  fi
  echo "$_VOC_CLUSTER_ID"
}

_voc_sha() {
  # sha256 of the concatenation of the given files. A missing file is not an
  # error: it just changes the hash, which correctly forces a redeploy. The
  # `|| true` matters because callers run under `set -euo pipefail`, where a
  # failing `cat` in the pipeline would otherwise abort the whole deploy.
  { cat "$@" 2>/dev/null || true; } | sha256sum | cut -d' ' -f1
}

# _voc_unchanged <key> <fingerprint> : 0 if this exact fingerprint was
# already applied to this exact cluster.
_voc_unchanged() {
  local key="$1" fingerprint="$2"
  local cluster; cluster=$(_voc_cluster_id)
  [ -n "$cluster" ] || return 1
  [ -n "$fingerprint" ] || return 1
  [ "$(cat "$VOC_STATE_DIR/$key" 2>/dev/null)" = "${cluster}:${fingerprint}" ]
}

_voc_mark_applied() {
  local key="$1" fingerprint="$2"
  local cluster; cluster=$(_voc_cluster_id)
  [ -n "$cluster" ] && [ -n "$fingerprint" ] || return 0
  mkdir -p "$VOC_STATE_DIR"
  printf '%s:%s' "$cluster" "$fingerprint" > "$VOC_STATE_DIR/$key"
}

# _voc_helm_deployed <release> <ns> : 0 if the release is installed and
# in a good state (not failed / pending).
_voc_helm_deployed() {
  helm status "$1" -n "$2" 2>/dev/null | grep -q 'STATUS: deployed'
}

# _voc_deploy_ready <ns> <deployment> : 0 if it has at least one ready replica.
# Automatically syncs active DefectDojo & TheHive system API keys across all namespace secrets (.env, defectdojo-creds, thehive-creds, prioritization-secrets)
voc_sync_keys() {
  local dd_token th_token
  # 1. Fetch live DefectDojo admin API key
  dd_token=$(kubectl exec -n voc-core deploy/defectdojo-django -- python manage.py shell -c "from django.contrib.auth import get_user_model; from rest_framework.authtoken.models import Token; User = get_user_model(); u = User.objects.filter(username='admin').first(); t, _ = Token.objects.get_or_create(user=u); print(t.key)" 2>/dev/null | tail -n 1)
  
  # 2. Fetch live TheHive API key
  th_token=$(kubectl get secret -n voc-core thehive-creds -o jsonpath='{.data.api-key}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

  local synced=0

  # Sync DefectDojo API Key
  if [ -n "$dd_token" ] && [ "${#dd_token}" -ge 20 ]; then
    export DD_API_KEY="$dd_token"
    if [ -f "$REPO_DIR/.env" ]; then
      sed -i "s/^DD_API_KEY=.*/DD_API_KEY=$dd_token/" "$REPO_DIR/.env" 2>/dev/null || true
    fi
    for ns in voc-core scanning monitoring; do
      if kubectl get ns "$ns" >/dev/null 2>&1; then
        kubectl -n "$ns" create secret generic defectdojo-creds \
          --from-literal=url=http://defectdojo-django.voc-core.svc.cluster.local \
          --from-literal=api-key="$dd_token" \
          --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true
      fi
    done
    kubectl -n voc-core create secret generic prioritization-secrets \
      --from-literal=DEFECTDOJO_API_KEY="$dd_token" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true
    synced=1
  fi

  # Sync TheHive API Key
  if [ -n "$th_token" ]; then
    export THEHIVE_KEY="$th_token"
    export N8N_THEHIVE_API_KEY="$th_token"
    if [ -f "$REPO_DIR/.env" ]; then
      sed -i "s/^THEHIVE_KEY=.*/THEHIVE_KEY=$th_token/" "$REPO_DIR/.env" 2>/dev/null || true
    fi
    kubectl -n voc-core create secret generic thehive-creds \
      --from-literal=api-key="$th_token" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true
    synced=1
  fi

  if [ "$synced" = "1" ]; then
    # Restart pods consuming secret key env variables so they load the new token immediately
    kubectl rollout restart deployment/n8n -n voc-core >/dev/null 2>&1 || true
    kubectl rollout restart deployment/prioritization-service -n voc-core >/dev/null 2>&1 || true
    kubectl rollout restart deployment/voc-metrics-exporter -n monitoring >/dev/null 2>&1 || true
    echo "[VOC] All system API Keys (DefectDojo & TheHive) synchronized cleanly across namespaces and pod deployments."
  fi
}

_voc_deploy_ready() {
  local ready
  ready=$(kubectl get deploy "$2" -n "$1" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [ -n "$ready" ] && [ "$ready" -ge 1 ] 2>/dev/null
}

# _voc_start_pf <ns> <svc> <local:remote> [scheme]
# `scheme` defaults to http; pass `https` for services that only speak TLS
# (the Wazuh API), otherwise the readiness probe below never gets a response
# and burns a full minute of retries on a tunnel that is already working.
_voc_start_pf() {
  local ns="$1" svc="$2" ports="$3" scheme="${4:-http}"
  local local_port="${ports%%:*}"

  # Kill any existing port-forward process (and its supervisor loop)
  # for this local port using Python
  python3 -c "import os, signal
for p in os.listdir('/proc'):
  if p.isdigit():
    try:
      cmd = open(f'/proc/{p}/cmdline').read()
      if 'port-forward' in cmd and '${local_port}:' in cmd:
        os.kill(int(p), signal.SIGTERM)
    except:
      pass" 2>/dev/null || true

  sleep 1 # Wait for the port to be released by the kernel

  echo "[VOC] Waiting for service '$svc' in namespace '$ns' to be ready..."
  local attempts=0
  until kubectl get endpoints "$svc" -n "$ns" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | grep -q '.' || [ $attempts -ge 60 ]; do
    sleep 2
    attempts=$((attempts + 1))
  done

  # Start the new port-forward in the background, wrapped in a
  # self-healing supervisor loop: if kubectl port-forward drops
  # (target pod restart, API blip, long-running scan saturating the
  # tunnel), it is restarted within ~2s instead of silently breaking
  # every localhost URL that depends on it.
  nohup bash -c "while true; do kubectl port-forward --address 0.0.0.0 -n '$ns' 'svc/$svc' '$ports' >/dev/null 2>&1; sleep 2; done" >/dev/null 2>&1 &

  # Wait until local HTTP port actually responds
  local http_attempts=0
  until curl -sk -o /dev/null -w "%{http_code}" "${scheme}://localhost:${local_port}/" 2>/dev/null | grep -E -q "^(200|302|401|403)$" || [ $http_attempts -ge 30 ]; do
    sleep 2
    http_attempts=$((http_attempts + 1))
  done
}

voc_up() {
  bash "$REPO_DIR/scripts/k3d-up.sh"
}

voc_down() {
  local cluster="${K3D_CLUSTER_NAME:-voc}"
  echo "[VOC] Deleting k3d cluster '$cluster'..."
  k3d cluster delete "$cluster" 2>/dev/null || echo "Cluster not found."
  docker network rm "$cluster" 2>/dev/null || true
  echo "[VOC] Done."
}

voc_status() {
  echo "=== Nodes ==="
  kubectl get nodes 2>/dev/null || echo "No cluster. Run 'voc-up'."
  echo ""
  echo "=== Pods (all namespaces) ==="
  kubectl get pods -A 2>/dev/null || true
  echo ""
  echo "=== Services (non-system) ==="
  kubectl get svc -A 2>/dev/null | grep -v -E "kubernetes|kube-system" || true
}

voc_helm_repo_add() {
  local name="$1" url="$2"
  local max_attempts=3
  local attempt=1

  # Already configured? Return without writing. `helm repo add` rewrites
  # repositories.yaml wholesale, so two components deploying in parallel
  # could otherwise clobber each other's entry. run-all.sh pre-adds every
  # repo serially before the parallel phase; this read-only check is what
  # makes the concurrent calls safe no-ops.
  if helm repo list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$name"; then
    return 0
  fi

  while [ $attempt -le $max_attempts ]; do
    if helm repo add "$name" "$url" >/dev/null 2>&1; then
      return 0
    fi
    echo "[VOC] WARNING: Failed to add Helm repo '$name' ($url). Retrying in 2 seconds..."
    sleep 2
    attempt=$((attempt + 1))
  done
  echo "[VOC] ERROR: Could not add Helm repo '$name' after $max_attempts attempts."
  return 1
}

# voc_helm_repo_ready <name> <url> : add the repo, and only hit the network
# for `helm repo update` when the cached index is missing or older than
# VOC_HELM_REPO_TTL_HOURS. `helm repo update` refreshes EVERY configured
# repo and takes 10-30s; charts we pin do not change between two starts on
# the same afternoon.
VOC_HELM_REPO_TTL_HOURS="${VOC_HELM_REPO_TTL_HOURS:-24}"
voc_helm_repo_ready() {
  local name="$1" url="$2"
  voc_helm_repo_add "$name" "$url" || return 1

  local index="${HELM_REPOSITORY_CACHE:-/root/.cache/helm/repository}/${name}-index.yaml"
  if [ -f "$index" ] && [ -z "$(find "$index" -mmin "+$((VOC_HELM_REPO_TTL_HOURS * 60))" 2>/dev/null)" ]; then
    return 0
  fi
  echo "[VOC] Refreshing Helm repo index for '$name'..."
  helm repo update "$name" >/dev/null 2>&1 || helm repo update >/dev/null 2>&1 || true
}

voc_deploy() {
  local target="${1:-all}"
  case "$target" in
    ns|namespaces)
      kubectl apply -f "$REPO_DIR/k8s/namespaces/namespaces.yaml"
      ;;
    dd|defectdojo)
      # Skip the whole helm round-trip when the release is already deployed
      # from these exact values. This is the single biggest warm-start win:
      # a no-op `helm upgrade` on the DefectDojo chart still costs ~60-90s.
      local dd_fp; dd_fp=$(_voc_sha "$REPO_DIR/k8s/defectdojo/values.yaml")
      if [ "${VOC_FORCE_DEPLOY:-0}" != "1" ] && _voc_unchanged defectdojo "$dd_fp" \
         && _voc_helm_deployed defectdojo voc-core && _voc_deploy_ready voc-core defectdojo-django; then
        echo "[VOC] DefectDojo already deployed and unchanged — skipping"
        _voc_start_pf voc-core defectdojo-django 8080:80
        return 0
      fi
      voc_helm_repo_ready defectdojo https://raw.githubusercontent.com/DefectDojo/django-DefectDojo/helm-charts
      if ! helm upgrade --install defectdojo defectdojo/defectdojo -n voc-core --create-namespace -f "$REPO_DIR/k8s/defectdojo/values.yaml"; then
        echo "[VOC] Helm upgrade failed. If changing persistence, statefulsets cannot be patched."
        echo "[VOC] Deleting defectdojo-postgresql statefulset and retrying..."
        kubectl delete statefulset defectdojo-postgresql -n voc-core || true
        helm upgrade --install defectdojo defectdojo/defectdojo -n voc-core --create-namespace -f "$REPO_DIR/k8s/defectdojo/values.yaml"
      fi
      _voc_mark_applied defectdojo "$dd_fp"
      echo "[VOC] Establishing DefectDojo port-forward..."
      _voc_start_pf voc-core defectdojo-django 8080:80
      ;;
    n8n)
      local n8n_fp; n8n_fp=$(_voc_sha "$REPO_DIR/k8s/n8n/values.yaml" "$REPO_DIR/k8s/n8n/n8n-rbac.yaml" "$REPO_DIR/n8n-workflows/voc-master-dashboard.json")
      if [ "${VOC_FORCE_DEPLOY:-0}" != "1" ] && _voc_unchanged n8n "$n8n_fp" \
         && _voc_helm_deployed n8n voc-core && _voc_deploy_ready voc-core n8n; then
        echo "[VOC] n8n already deployed and unchanged (workflow already imported) — skipping"
        _voc_start_pf voc-core n8n 5678:5678
        return 0
      fi
      voc_helm_repo_ready community-charts https://community-charts.github.io/helm-charts
      helm upgrade --install n8n community-charts/n8n -n voc-core \
        --create-namespace -f "$REPO_DIR/k8s/n8n/values.yaml"
      kubectl apply -f "$REPO_DIR/k8s/n8n/n8n-rbac.yaml"

      echo "[VOC] Configuring n8n credentials and importing workflow..."
      local attempt=1
      while [ $attempt -le 15 ]; do
        local n8n_pod
        n8n_pod=$(kubectl get pods -n voc-core -l app.kubernetes.io/name=n8n --no-headers 2>/dev/null | grep -v postgresql | grep "Running" | head -n 1 | awk '{print $1}' || true)
        if [ -n "$n8n_pod" ]; then
          # 1. Provision TheHive credentials using vocadmin (org-admin) user
          if ! kubectl get secret thehive-creds -n voc-core > /dev/null 2>&1; then
            # Create the 'voc' org if it doesn't exist
            kubectl exec deploy/thehive -n voc-core -c thehive -- \
              curl -sf -X POST -u admin@thehive.local:secret \
              -H 'Content-Type: application/json' \
              http://localhost:9000/api/v1/organisation \
              -d '{"name":"voc","description":"VOC Security Operations"}' > /dev/null 2>&1 || true
            # Create vocadmin user with org-admin profile (has manageAlert/create)
            kubectl exec deploy/thehive -n voc-core -c thehive -- \
              curl -sf -X POST -u admin@thehive.local:secret \
              -H 'Content-Type: application/json' \
              http://localhost:9000/api/v1/user \
              -d '{"login":"vocadmin@thehive.local","name":"VOC Admin","profile":"org-admin","organisation":"voc","password":"vocadmin123"}' > /dev/null 2>&1 || true
            # Generate API key for vocadmin
            local thehive_key
            thehive_key=$(kubectl exec deploy/thehive -n voc-core -c thehive -- \
              curl -sf -X POST -u admin@thehive.local:secret \
              http://localhost:9000/api/v1/user/vocadmin@thehive.local/key/renew 2>/dev/null) || thehive_key=""
            if [[ "$thehive_key" =~ ^[a-zA-Z0-9/+=]{20,64}$ ]]; then
              kubectl -n voc-core create secret generic thehive-creds \
                --from-literal=api-key="$thehive_key" \
                --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1
              echo "[VOC] TheHive vocadmin key provisioned"
            fi
          fi

          # 2. Copy and import workflow
          #
          # The import is NOT silenced. n8n validates workflow structure and
          # refuses the whole file on a single bad connection; hiding that
          # behind `|| true` means the cluster quietly keeps running an old
          # version of the workflow while the repo says otherwise.
          kubectl cp "$REPO_DIR/n8n-workflows/voc-master-dashboard.json" "voc-core/$n8n_pod:/tmp/voc-master-dashboard.json" 2>/dev/null || true
          # The helm upgrade above can still be bouncing n8n-postgresql when we
          # get here, and the import fails with "There was an error
          # initializing DB". That is transient, so retry a few times before
          # calling it a real failure — but a structural error in the workflow
          # will fail all three attempts and then get reported.
          local wf_imported=0 wf_try=1 wf_out=""
          while [ $wf_try -le 3 ]; do
            if wf_out=$(kubectl exec -n voc-core "$n8n_pod" -- \
                 n8n import:workflow --input=/tmp/voc-master-dashboard.json 2>&1); then
              echo "$wf_out" | sed 's/^/  /'
              wf_imported=1
              # `import:workflow` DEACTIVATES the workflow it imports (it says
              # so: "Deactivating workflow ..."), and an inactive workflow
              # registers no webhooks at all — every /webhook/voc/* path
              # returns 404, including the Wazuh SIEM ingest. `publish:workflow`
              # alone did NOT bring it back; only update:workflow --active=true
              # did, verified against a live cluster. publish is kept for the
              # version pointer, update is what actually re-activates. The
              # latter is deprecated upstream, hence both, hence the probe
              # further down that turns a silent 404 into a visible warning.
              kubectl exec -n voc-core "$n8n_pod" -- n8n publish:workflow --id=VdT8S1MTBinkKnEH >/dev/null 2>&1 || true
              kubectl exec -n voc-core "$n8n_pod" -- n8n update:workflow --id=VdT8S1MTBinkKnEH --active=true >/dev/null 2>&1 || true
              break
            fi
            echo "[VOC] Workflow import attempt $wf_try/3 failed, retrying in 15s..."
            sleep 15
            wf_try=$((wf_try + 1))
          done
          if [ "$wf_imported" != "1" ]; then
            echo "$wf_out" | tail -5 | sed 's/^/  /'
            echo "[VOC] ERROR: workflow import failed — n8n is still running the previously imported version."
            echo "[VOC]        Webhooks added or renamed in voc-master-dashboard.json will not exist."
          fi

          # 3. Restart n8n so the imported workflow's triggers register.
          #    `n8n publish:workflow` says it outright: changes do not take
          #    effect while n8n is running. Without this a re-imported
          #    workflow looks correct in the UI but its webhooks 404. This
          #    only runs when the workflow or values actually changed — the
          #    fingerprint check above short-circuits a warm start.
          if [ "$wf_imported" = "1" ]; then
            echo "[VOC] Restarting n8n so the imported workflow's triggers register..."
            kubectl rollout restart deployment/n8n -n voc-core >/dev/null 2>&1 || true
            kubectl rollout status deployment/n8n -n voc-core --timeout=180s >/dev/null 2>&1 || \
              echo "[VOC] WARNING: n8n restart timed out — check 'kubectl get pods -n voc-core'"

            # Prove the workflow actually came back active. An inactive
            # workflow looks completely healthy — pod Running, `n8n
            # list:workflow` shows it — while every webhook 404s and Wazuh
            # alerts vanish into nothing. Probe one known path rather than
            # trusting the activation command's exit code.
            local wh_code=""
            for _ in $(seq 1 10); do
              wh_code=$(kubectl exec -n voc-core deploy/n8n -- \
                wget -qS -O /dev/null http://localhost:5678/webhook/voc/dashboard 2>&1 \
                | awk '/HTTP\//{print $2; exit}') || wh_code=""
              [ -n "$wh_code" ] && break
              sleep 5
            done
            if [ "$wh_code" = "200" ]; then
              echo "[VOC] Workflow is active — webhooks are registered"
            else
              echo "[VOC] WARNING: /webhook/voc/dashboard returned '${wh_code:-no response}'."
              echo "[VOC]          The workflow is imported but NOT active: every webhook"
              echo "[VOC]          will 404, including Wazuh SIEM ingest. Fix with:"
              echo "[VOC]          kubectl exec -n voc-core deploy/n8n -- \\"
              echo "[VOC]            n8n update:workflow --id=VdT8S1MTBinkKnEH --active=true"
              echo "[VOC]          then: kubectl rollout restart deployment/n8n -n voc-core"
            fi
          fi

          echo "[VOC] Establishing n8n port-forward on :5678..."
          _voc_start_pf voc-core n8n 5678:5678

          # 4. Verify accessibility and restart ONLY if broken
          sleep 2
          if ! curl -s -o /dev/null -w "%{http_code}" http://localhost:5678/healthz | grep -q "200"; then
            echo "[VOC] n8n is not accessible! Performing recovery restart..."
            kubectl rollout restart deployment/n8n -n voc-core > /dev/null 2>&1 || true
            kubectl rollout status deployment/n8n -n voc-core --timeout=60s > /dev/null 2>&1 || true
            _voc_start_pf voc-core n8n 5678:5678
          fi
          echo "[VOC] n8n is accessible at http://localhost:5678"
          _voc_mark_applied n8n "$n8n_fp"
          break
        fi
        sleep 2
        attempt=$((attempt + 1))
      done
      ;;
    thehive)
      echo "[VOC] Deploying TheHive 5 (lightweight, no Cassandra)..."
      # kubectl apply is cheap and idempotent, so this one always runs —
      # but the port-forward is what actually matters on a warm start.
      kubectl apply -f "$REPO_DIR/k8s/thehive/thehive-deployment.yaml"
      echo "[VOC] Establishing TheHive port-forward..."
      _voc_start_pf voc-core thehive-svc 9000:9000
      ;;
    wazuh|siem)
      # Opt-in SIEM: manager (voc-core) + one agent per node (voc-siem).
      # See the header of k8s/wazuh/wazuh-manager.yaml for why there is no
      # indexer and how alerts reach n8n and TheHive.
      local wz_fp
      wz_fp=$(_voc_sha "$REPO_DIR/k8s/wazuh/wazuh-manager.yaml" "$REPO_DIR/k8s/wazuh/wazuh-agent.yaml")
      if [ "${VOC_FORCE_DEPLOY:-0}" != "1" ] && _voc_unchanged wazuh "$wz_fp" \
         && _voc_deploy_ready voc-core wazuh-manager; then
        echo "[VOC] Wazuh already deployed and unchanged — skipping"
        _voc_start_pf voc-core wazuh-manager 55000:55000 https
        return 0
      fi

      echo "[VOC] Deploying Wazuh (SIEM): manager + node agent..."
      # The agent lives in voc-siem, which only exists once namespaces.yaml
      # has been applied — `voc-deploy wazuh` is a valid entry point on its own.
      kubectl apply -f "$REPO_DIR/k8s/namespaces/namespaces.yaml" >/dev/null 2>&1 || true
      kubectl apply -f "$REPO_DIR/k8s/wazuh/wazuh-manager.yaml"

      # Agents enrol with the manager's authd password. Secrets do not cross
      # namespaces, so mirror that one key into voc-siem; the value in
      # wazuh-manager.yaml stays the single source of truth.
      local authd_pass
      authd_pass=$(kubectl get secret wazuh-api-creds -n voc-core \
        -o jsonpath='{.data.authd\.pass}' 2>/dev/null | base64 -d 2>/dev/null) || authd_pass=""
      if [ -n "$authd_pass" ]; then
        kubectl -n voc-siem create secret generic wazuh-enrollment \
          --from-literal=authd.pass="$authd_pass" \
          --dry-run=client -o yaml | kubectl apply -f - >/dev/null
      else
        echo "[VOC] WARNING: could not read the enrolment password — agents will not register."
      fi
      kubectl apply -f "$REPO_DIR/k8s/wazuh/wazuh-agent.yaml"

      # A ConfigMap change does not roll the pods that read it, and the whole
      # manager configuration (rules, integration webhook, agent policy) lives
      # in one. Only bounce pods that were already running: on a first deploy
      # they have not started yet and a restart would just cost 90 seconds.
      if _voc_deploy_ready voc-core wazuh-manager; then
        echo "[VOC] Configuration changed — restarting manager and agents..."
        kubectl rollout restart deployment/wazuh-manager -n voc-core >/dev/null 2>&1 || true
        kubectl rollout restart daemonset/wazuh-agent -n voc-siem >/dev/null 2>&1 || true
      fi
      _voc_mark_applied wazuh "$wz_fp"

      echo "[VOC] Waiting for the Wazuh manager (first boot takes 2-3 min)..."
      kubectl rollout status deployment/wazuh-manager -n voc-core --timeout=600s || \
        echo "[VOC] WARNING: manager not ready yet — check 'voc-wazuh logs'"

      echo "[VOC] Wazuh API: https://localhost:55000  (user: wazuh-wui  password: VocLabWazuh1!)"
      echo "[VOC] Alerts at level >= 7 are POSTed to n8n and become TheHive alerts."
      echo "[VOC] Try: voc-wazuh status | voc-wazuh agents | voc-wazuh test"
      _voc_start_pf voc-core wazuh-manager 55000:55000 https
      ;;
    no-wazuh|wazuh-off)
      # Frees ~2 GB of RAM and the 5 Gi manager PVC. Mirrors `no-monitoring`:
      # the manifests stay, so `voc-deploy wazuh` brings it all back.
      echo "[VOC] Removing Wazuh (manager + agents)..."
      kubectl delete daemonset wazuh-agent -n voc-siem --ignore-not-found >/dev/null 2>&1 || true
      kubectl delete -f "$REPO_DIR/k8s/wazuh/wazuh-manager.yaml" --ignore-not-found >/dev/null 2>&1 || true
      # The PVC holds the agent keys and alert history; deleting it is the
      # point of this command (that is where the disk goes).
      kubectl delete pvc wazuh-manager-data -n voc-core --ignore-not-found >/dev/null 2>&1 || true
      # The mirrored enrolment secret is not in any manifest, so nothing else
      # would ever clean it up.
      kubectl delete secret wazuh-enrollment -n voc-siem --ignore-not-found >/dev/null 2>&1 || true
      rm -f "$VOC_STATE_DIR/wazuh" 2>/dev/null || true
      echo "[VOC] Wazuh removed. Re-enable with: voc-deploy wazuh"
      ;;
    targets)
      kubectl apply -f "$REPO_DIR/k8s/targets/"
      ;;
    scanners)
      local cluster="${K3D_CLUSTER_NAME:-voc}"
      echo "[VOC] Building voc-orchestrator image..."
      docker build -t voc-orchestrator:latest -f "$REPO_DIR/orchestrator/Dockerfile" "$REPO_DIR"
      echo "[VOC] Importing image into k3d cluster '$cluster'..."
      k3d image import voc-orchestrator:latest -c "$cluster"

      kubectl -n scanning create secret generic defectdojo-creds \
        --from-literal=url=http://defectdojo-django.voc-core.svc.cluster.local \
        --from-literal=api-key="${DD_API_KEY:-changeme}" \
        --dry-run=client -o yaml | kubectl apply -f -
      kubectl -n voc-core create secret generic defectdojo-creds \
        --from-literal=url=http://defectdojo-django.voc-core.svc.cluster.local \
        --from-literal=api-key="${DD_API_KEY:-changeme}" \
        --dry-run=client -o yaml | kubectl apply -f -
      for f in "$REPO_DIR/scanners/"*.yaml; do
        if ! grep -q "__JOB_NAME__" "$f"; then
          kubectl apply -f "$f" || true
        fi
      done
      ;;
    prio|prioritization)
      local cluster="${K3D_CLUSTER_NAME:-voc}"
      # docker build + k3d image import costs ~60s and is a no-op unless the
      # service source actually changed, so gate it on a source fingerprint.
      local prio_fp
      prio_fp=$(_voc_sha \
        "$REPO_DIR/prioritization-service/Dockerfile" \
        "$REPO_DIR/prioritization-service/requirements.txt" \
        "$REPO_DIR/prioritization-service"/*.py)
      if [ "${VOC_FORCE_DEPLOY:-0}" = "1" ] || ! _voc_unchanged prio-image "$prio_fp"; then
        echo "[VOC] Building prioritization-service image..."
        docker build -t prioritization-service:0.1.0 "$REPO_DIR/prioritization-service/"
        echo "[VOC] Importing image into k3d cluster '$cluster'..."
        k3d image import prioritization-service:0.1.0 -c "$cluster"
        _voc_mark_applied prio-image "$prio_fp"
      else
        echo "[VOC] prioritization-service image unchanged — skipping build/import"
      fi
      # Provision the DD API key secret so the prio service can authenticate
      kubectl -n voc-core create secret generic prioritization-secrets \
        --from-literal=DEFECTDOJO_API_KEY="${DD_API_KEY:-changeme}" \
        --dry-run=client -o yaml | kubectl apply -f -
      # Business context (asset criticality / internet exposure) lives in a
      # ConfigMap so it can be edited and reloaded without an image rebuild.
      kubectl -n voc-core create configmap voc-asset-inventory \
        --from-file=asset-inventory.yaml="$REPO_DIR/prioritization-service/asset-inventory.yaml" \
        --dry-run=client -o yaml | kubectl apply -f -
      kubectl apply -f "$REPO_DIR/prioritization-service/deployment.yaml"
      # A ConfigMap change does not restart the pod by itself, so bounce it
      # when the inventory or deployment spec moved — but only then, since a
      # restart costs ~15s and drops the in-memory KEV catalogue.
      local prio_cfg_fp
      prio_cfg_fp=$(_voc_sha \
        "$REPO_DIR/prioritization-service/asset-inventory.yaml" \
        "$REPO_DIR/prioritization-service/deployment.yaml")
      if [ "${VOC_FORCE_DEPLOY:-0}" = "1" ] || ! _voc_unchanged prio-config "$prio_cfg_fp"; then
        kubectl rollout restart deployment/prioritization-service -n voc-core >/dev/null 2>&1 || true
        _voc_mark_applied prio-config "$prio_cfg_fp"
      fi
      ;;
    monitoring)
      # Not deployed automatically any more (see VOC_ENABLE_MONITORING at the
      # top of this file). Running `voc-deploy monitoring` explicitly still
      # brings the whole Grafana + Prometheus stack up exactly as before.
      echo "[VOC] Deploying kube-prometheus-stack (Grafana + Prometheus)."
      echo "[VOC] NOTE: this is off by default — it costs ~2 GB RAM and a 10 Gi PVC."
      voc_helm_repo_ready prometheus-community https://prometheus-community.github.io/helm-charts
      kubectl apply -f "$REPO_DIR/k8s/monitoring/" 2>/dev/null || true

      echo "[VOC] Creating Grafana dashboard ConfigMaps..."
      kubectl -n monitoring create configmap voc-grafana-dashboards \
        --from-file=voc-vulnerabilities.json="$REPO_DIR/k8s/monitoring/dashboard-voc-vulnerabilities.json" \
        --from-file=voc-health.json="$REPO_DIR/k8s/monitoring/dashboard-voc-health.json" \
        --from-file=voc-resources.json="$REPO_DIR/k8s/monitoring/dashboard-voc-resources.json" \
        --dry-run=client -o yaml | kubectl apply -f -

      helm upgrade --install kps prometheus-community/kube-prometheus-stack -n monitoring \
        --create-namespace -f "$REPO_DIR/k8s/monitoring/values.yaml"
      # Deploy VOC metrics exporter (ConfigMap with script + Deployment)
      echo "[VOC] Creating metrics exporter ConfigMap..."
      kubectl -n monitoring create configmap voc-metrics-exporter-script \
        --from-file=voc-metrics-exporter.py="$REPO_DIR/scripts/voc-metrics-exporter.py" \
        --dry-run=client -o yaml | kubectl apply -f -
      # Create defectdojo-creds secret in monitoring namespace
      kubectl -n monitoring create secret generic defectdojo-creds \
        --from-literal=api-key="${DD_API_KEY:-changeme}" \
        --dry-run=client -o yaml | kubectl apply -f -
      kubectl apply -f "$REPO_DIR/k8s/monitoring/voc-exporter-deployment.yaml" 2>/dev/null || true
      _voc_start_pf monitoring kps-grafana 3001:80
      echo "[VOC] Grafana: http://localhost:3001 (admin / voclab2026)"
      ;;
    no-monitoring|monitoring-off)
      # Frees ~2 GB of RAM plus the Prometheus/Grafana PVCs. Files and the
      # `voc-deploy monitoring` path are untouched, so this is reversible.
      echo "[VOC] Removing kube-prometheus-stack (Grafana + Prometheus)..."
      helm uninstall kps -n monitoring 2>/dev/null || echo "[VOC] No 'kps' release installed."
      kubectl delete deployment voc-metrics-exporter -n monitoring --ignore-not-found >/dev/null 2>&1 || true
      # Helm leaves PVCs behind by design; they are the bulk of the disk use.
      kubectl delete pvc -n monitoring --all --ignore-not-found >/dev/null 2>&1 || true
      rm -f "$VOC_STATE_DIR/monitoring" 2>/dev/null || true
      echo "[VOC] Monitoring removed. Re-enable with: voc-deploy monitoring"
      ;;
    all)
      echo "[VOC] Full deployment..."
      voc_deploy ns
      echo "[VOC] Deploying DefectDojo (this is the heaviest)..."
      voc_deploy dd
      echo "[VOC] Deploying n8n..."
      voc_deploy n8n
      echo "[VOC] Deploying targets..."
      voc_deploy targets
      echo "[VOC] Waiting for DefectDojo to be ready (up to 5 min)..."
      kubectl wait --for=condition=Ready pod -n voc-core -l app.kubernetes.io/component=django \
        --timeout=300s 2>/dev/null || echo "  (timeout — check pods with 'voc-status')"
      echo "[VOC] Deploying scanners..."
      voc_deploy scanners
      echo "[VOC] Deploying prioritization service..."
      voc_deploy prio
      echo "[VOC] Deploying TheHive..."
      voc_deploy thehive
      if [ "$VOC_ENABLE_WAZUH" = "1" ]; then echo "[VOC] Deploying Wazuh..."; voc_deploy wazuh; fi
      if [ "$VOC_ENABLE_MONITORING" = "1" ]; then echo "[VOC] Deploying monitoring..."; voc_deploy monitoring; fi
      echo ""
      echo "[VOC] Deployment complete. Run 'voc-status' to check."
      echo "[VOC] Get DefectDojo admin password:"
      echo "  kubectl -n voc-core get secret defectdojo-django-secret -o jsonpath='{.data.DD_ADMIN_PASSWORD}' | base64 -d"
      ;;
    *)
      echo "Usage: voc-deploy [ns|dd|n8n|thehive|wazuh|no-wazuh|targets|scanners|prio|monitoring|no-monitoring|all]"
      ;;
  esac
}

# Source .env before running any voc-* command that needs DD_API_KEY or
# other config. Without this, the user must run `set -a; . /workspace/.env;
# set +a` manually every time they open a new shell or edit .env -- a
# common foot-gun (a stale DD_API_KEY=changeme left in the env returns
# HTTP 403 with no clue why).
_voc_load_env() {
  local env_file="$REPO_DIR/.env"
  if [ -f "$env_file" ]; then
    # shellcheck disable=SC1090
    set -a; . "$env_file"; set +a
  fi
  voc_sync_keys >/dev/null 2>&1 || true
}

voc_scan() {
  _voc_load_env
  bash "$REPO_DIR/scripts/scan-all.sh" "$@"
}

voc_history() {
  bash "$REPO_DIR/scripts/voc-history.sh" "$@"
}

# Pre-pull scanner images into the k3d cluster so the first voc-scan
# doesn't spend 1-2 min waiting for containerd to pull them.
voc_prepull() {
  local cluster="${K3D_CLUSTER_NAME:-voc}"
  local images=(
    "projectdiscovery/nuclei:v3.10.0"
    "projectdiscovery/katana:v1.6.1"
    "parrotsec/sqlmap:7.1"
    "parrotsec/ffuf:7.1"
    "anchore/grype:v0.115.0-debug"
    "femtopixel/xsstrike:3.1.6"
  )

  # Images live on the k3d node and survive cluster stop/start, so this only
  # needs to run once per cluster. `k3d image import` alone costs ~60-90s for
  # this set even when every layer is already cached locally.
  local images_fp; images_fp=$(printf '%s\n' "${images[@]}" | sha256sum | cut -d' ' -f1)
  if [ "${VOC_FORCE_DEPLOY:-0}" != "1" ] && _voc_unchanged prepull "$images_fp"; then
    echo "[VOC] Scanner images already imported into '$cluster' — skipping pre-pull"
    return 0
  fi

  echo "[VOC] Pre-pulling ${#images[@]} scanner images (parallel)..."
  local pids=()
  for img in "${images[@]}"; do
    docker pull "$img" >/dev/null 2>&1 &
    pids+=($!)
  done
  local failed=0
  for pid in "${pids[@]}"; do
    wait "$pid" || failed=$((failed + 1))
  done
  [ "$failed" -gt 0 ] && echo "[VOC] WARNING: $failed image(s) failed to pull (may already be cached)"
  echo "[VOC] Importing images into k3d cluster '$cluster'..."
  if k3d image import "${images[@]}" -c "$cluster" 2>/dev/null; then
    _voc_mark_applied prepull "$images_fp"
  else
    echo "[VOC] WARNING: k3d image import had errors (images may already exist)"
  fi
  echo "[VOC] Pre-pull complete."
}

voc_test_tool() {
  _voc_load_env
  bash "$REPO_DIR/scripts/test-tool.sh" "$@"
}

voc_run_all() {
  _voc_load_env
  bash "$REPO_DIR/scripts/run-all.sh" "$@"
}

voc_forward() {
  if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: voc-forward <namespace/service> <local-port:remote-port>"
    echo "  e.g.  voc-forward voc-core/defectdojo-django 8080:8080"
    echo "        voc-forward voc-core/n8n 5678:5678"
    return 1
  fi
  local svc="$1" ports="$2"
  local ns="${svc%%/*}" name="${svc##*/}"
  echo "[VOC] Port-forwarding svc/$name in ns/$ns -> localhost:$ports"
  kubectl port-forward --address 0.0.0.0 -n "$ns" "svc/$name" "$ports"
}

voc_logs() {
  if [ -z "$1" ]; then
    echo "Usage: voc-logs <namespace> [pod-name]"
    return 1
  fi
  local ns="$1" pod="${2:-}"
  if [ -z "$pod" ]; then
    kubectl logs -n "$ns" --tail=50 -l app.kubernetes.io/name="$ns" 2>/dev/null || \
    kubectl logs -n "$ns" --tail=50 --all-containers=true 2>/dev/null || \
    echo "Specify a pod name: voc-logs $ns <pod-name>"
  else
    kubectl logs -n "$ns" "$pod" --tail=50 -f
  fi
}

voc_help() {
  cat << 'EOF'
==============================================================================
                VOC — Vulnerability Operations Center CLI                      
==============================================================================

Core Management:
  voc-up                Start local k3d Kubernetes cluster
  voc-down              Tear down k3d Kubernetes cluster
  voc-status            Display cluster status, pods, and services
  voc-deploy <comp>     Deploy component: all | n8n | defectdojo | thehive |
                        prio | monitoring | wazuh | no-monitoring | no-wazuh
  voc-refresh           Clear cached state to force a clean redeploy

Scanning & Security Automation:
  voc-scan              Trigger full vulnerability scan across all targets
  voc-scan --quick      Trigger quick scan (bypasses long DAST brute-forcing)
  voc-test-tool <t> <u> Run one tool: katana | ffuf | sqlmap | xss | nuclei
                        (katana only crawls — it produces URLs, not findings)
  voc-history           View historical scan runs and finding counts
  voc-history --run <N> View detailed breakdown for a specific scan run

Prioritization Engine (CVSS + EPSS + KEV × Asset Context):
  voc-prio              Run prioritization scoring pass over DefectDojo
  voc-assets            List configured business assets & criticality factors
  voc-prio-explain <ID> Explain priority score calculation for finding ID

SIEM / Host Intrusion Detection (opt-in: VOC_ENABLE_WAZUH=1):
  voc-wazuh status      Wazuh manager, enrolled agents, alert forwarding
  voc-wazuh agents      List agents and their connection state
  voc-wazuh alerts [N]  Show the last N alerts the manager recorded
  voc-wazuh test        Fire benign test events and follow them through the
                        pipeline into TheHive
  voc-wazuh api <path>  Raw Wazuh REST API call

Cluster & Troubleshooting Helpers:
  voc-sync-keys         Synchronize DefectDojo & TheHive API keys across pods
  voc-prepull           Pre-pull scanner container images into cluster
  voc-forward <s/s> <p> Manually port-forward a service (e.g. voc-core/n8n 5678:5678)
  voc-logs <ns> [pod]   Stream container logs for a pod or deployment
  voc-help              Display this menu

Live Portals (accessible after deployment):
  DefectDojo:          http://localhost:8080  (admin / vaimallK7w0ldXPgYV5oRM)
  n8n Orchestration:   http://localhost:5678  (zrty admin@voc.local / voclab2026)
  TheHive Incident Mgmt: http://localhost:9000 (vocadmin@thehive.local / vocadmin123)
  Grafana Observability: http://localhost:3001 (admin / voclab2026)
  Juice Shop Target:    http://localhost:3000

==============================================================================
EOF
}

# --- Prioritization helpers -------------------------------------------
_voc_prio_curl() {
  kubectl exec -n voc-core deploy/prioritization-service -- \
    python3 -c "
import sys, urllib.request, urllib.error
data = b'' if '$2' == 'POST' else None
req = urllib.request.Request('http://localhost:8000$1', data=data, method='$2')
try:
    with urllib.request.urlopen(req, timeout=120) as resp:
        print(resp.read().decode())
except urllib.error.HTTPError as e:
    res = e.read().decode()
    if e.code == 409:
        print('[VOC] A prioritization pass is already running in the background.')
    else:
        print(f'[VOC] Error {e.code}: {res}')
except Exception as e:
    print('[VOC] prioritization-service error:', e)
" 2>/dev/null || echo "[VOC] prioritization-service not reachable (is it deployed?)"
}

voc_prio()         { echo "[VOC] Running prioritization pass..."; _voc_prio_curl "/score" POST; }
voc_prio_explain() {
  [ -z "${1:-}" ] && { echo "Usage: voc-prio-explain <defectdojo-finding-id>"; return 1; }
  _voc_prio_curl "/explain/$1" GET
}
voc_assets()       { _voc_prio_curl "/assets" GET; }

# --- Wazuh / SIEM helpers ---------------------------------------------
_voc_wazuh_pod() {
  kubectl get pod -n voc-core -l app=wazuh-manager \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

_voc_wazuh_agent_pod() {
  kubectl get pod -n voc-siem -l app=wazuh-agent \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# _voc_wazuh_api <path> [method] : call the Wazuh REST API from inside the
# manager pod. Doing it in-cluster means this works whether or not the
# :55000 port-forward is up, and the credentials never leave the pod.
_voc_wazuh_api() {
  local path="${1:-/}" method="${2:-GET}"
  local pod; pod=$(_voc_wazuh_pod)
  if [ -z "$pod" ]; then
    echo "[VOC] Wazuh manager is not deployed. Run: voc-deploy wazuh"
    return 1
  fi
  local user pass
  user=$(kubectl get secret wazuh-api-creds -n voc-core -o jsonpath='{.data.API_USERNAME}' 2>/dev/null | base64 -d)
  pass=$(kubectl get secret wazuh-api-creds -n voc-core -o jsonpath='{.data.API_PASSWORD}' 2>/dev/null | base64 -d)
  # Credentials go through env rather than string interpolation so a password
  # containing shell metacharacters cannot break (or escape) the command.
  kubectl exec -n voc-core "$pod" -- env WZ_USER="$user" WZ_PASS="$pass" \
    WZ_PATH="$path" WZ_METHOD="$method" sh -c '
      TOKEN=$(curl -sku "$WZ_USER:$WZ_PASS" -X POST \
        "https://localhost:55000/security/user/authenticate?raw=true")
      if [ -z "$TOKEN" ]; then
        echo "[VOC] Wazuh API authentication failed (check the wazuh-api-creds secret)."
        exit 1
      fi
      curl -sk -X "$WZ_METHOD" -H "Authorization: Bearer $TOKEN" \
        "https://localhost:55000${WZ_PATH}"
    ' 2>/dev/null
}

voc_wazuh() {
  local cmd="${1:-status}"; shift 2>/dev/null || true
  case "$cmd" in
    status)
      echo "=== Wazuh pods ==="
      kubectl get pods -n voc-core -l app=wazuh-manager 2>/dev/null || true
      kubectl get pods -n voc-siem -l app=wazuh-agent 2>/dev/null || true
      echo ""
      echo "=== Manager ==="
      _voc_wazuh_api "/manager/info?pretty=true" | \
        grep -E '"version"|"type"|"max_agents"' || echo "  (API not reachable)"
      echo ""
      echo "=== Enrolled agents ==="
      voc_wazuh agents
      echo ""
      echo "=== Alert forwarding ==="
      local pod; pod=$(_voc_wazuh_pod)
      if [ -n "$pod" ]; then
        kubectl exec -n voc-core "$pod" -- sh -c \
          'grep -c . /var/ossec/logs/alerts/alerts.json 2>/dev/null || echo 0' | \
          sed 's/^/  alerts recorded: /'
        kubectl exec -n voc-core "$pod" -- sh -c \
          'grep -o "<hook_url>.*</hook_url>" /var/ossec/etc/ossec.conf' 2>/dev/null | \
          sed 's/^/  webhook: /'
      fi
      ;;
    agents)
      # One line per agent instead of 40 lines of JSON envelope.
      _voc_wazuh_api "/agents?select=id,name,ip,status,version,lastKeepAlive&sort=id" | \
        python3 -c '
import json, sys
try:
    items = json.load(sys.stdin)["data"]["affected_items"]
except Exception:
    print("  (no agent data — is the manager running?)"); raise SystemExit(0)
print("  %-4s %-34s %-15s %-10s %s" % ("ID", "NAME", "IP", "STATUS", "VERSION"))
for a in items:
    print("  %-4s %-34s %-15s %-10s %s" % (
        a.get("id", "?"), a.get("name", "?")[:34], a.get("ip", "-"),
        a.get("status", "?"), a.get("version", "-")))
' 2>/dev/null || echo "  (agent list unavailable)"
      ;;
    alerts)
      local n="${1:-20}"
      local pod; pod=$(_voc_wazuh_pod)
      if [ -z "$pod" ]; then echo "[VOC] Wazuh manager is not deployed."; return 1; fi
      # Alerts live in the manager's own log, not the API — there is no
      # indexer to query. See k8s/wazuh/wazuh-manager.yaml.
      kubectl exec -n voc-core "$pod" -- sh -c \
        "tail -n $n /var/ossec/logs/alerts/alerts.json 2>/dev/null" | \
        python3 -c '
import json, sys
rows = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        a = json.loads(line)
    except Exception:
        continue
    rows += 1
    rule = a.get("rule", {})
    print("  [%s] L%-2s rule %-6s %s  (agent: %s)" % (
        a.get("timestamp", "")[:19], rule.get("level", "?"), rule.get("id", "?"),
        (rule.get("description") or "")[:70], a.get("agent", {}).get("name", "-")))
if not rows:
    print("  (no alerts yet — try: voc-wazuh test)")
' 2>/dev/null || echo "  (could not read alerts)"
      ;;
    test)
      # Proves the whole chain without touching anything real:
      #   agent event -> manager rules -> integrator -> n8n -> TheHive
      local apod; apod=$(_voc_wazuh_agent_pod)
      if [ -z "$apod" ]; then
        echo "[VOC] No Wazuh agent pod found in voc-siem. Run: voc-deploy wazuh"
        return 1
      fi
      echo "[VOC] Generating test events on agent pod $apod..."

      # 1. Authentication attack. Eight failures inside two minutes is what
      #    rule 5712 ("sshd brute force") looks for; level 10, well above the
      #    level 7 forwarding threshold.
      kubectl exec -n voc-siem "$apod" -- sh -c '
        # The syslog pre-decoder needs "<date> <host> <program>[pid]:" — with
        # an empty hostname the line never reaches a rule. `hostname` is not
        # in the agent image, so take the one Docker puts in the environment.
        HOST=${HOSTNAME:-voc-agent}
        STAMP=$(date "+%b %d %H:%M:%S")
        i=1
        while [ $i -le 10 ]; do
          echo "$STAMP $HOST sshd[4242]: Failed password for invalid user admin from 203.0.113.77 port 5$i ssh2" \
            >> /var/log/voc-audit.log
          i=$((i + 1))
        done
      ' 2>/dev/null && echo "  - 10 failed SSH logins written (expect rule 5710 + 5712)"

      # 2. File integrity. Creating a file is only level 5; modifying one
      #    that syscheck has already baselined is rule 550 at level 7.
      kubectl exec -n voc-siem "$apod" -- sh -c '
        mkdir -p /var/ossec/fim-test
        echo "voc-baseline" > /var/ossec/fim-test/canary.txt
      ' 2>/dev/null
      echo "  - FIM canary created, waiting for the realtime baseline..."
      sleep 10
      kubectl exec -n voc-siem "$apod" -- sh -c \
        'echo "tampered-by-voc-wazuh-test" >> /var/ossec/fim-test/canary.txt' 2>/dev/null \
        && echo "  - FIM canary modified (expect rule 550)"

      echo "[VOC] Waiting 25s for the manager to correlate and forward..."
      sleep 25
      echo ""
      echo "=== Most recent alerts ==="
      voc_wazuh alerts 15
      echo ""
      echo "=== Alerts forwarded to n8n ==="
      local pod; pod=$(_voc_wazuh_pod)
      kubectl exec -n voc-core "$pod" -- sh -c \
        'tail -n 5 /var/ossec/logs/integrations.log 2>/dev/null || echo "  (no integrations.log yet)"' 2>/dev/null
      echo ""
      echo "[VOC] Check TheHive for the resulting alerts: http://localhost:9000"
      ;;
    logs)
      local pod; pod=$(_voc_wazuh_pod)
      [ -z "$pod" ] && { echo "[VOC] Wazuh manager is not deployed."; return 1; }
      kubectl exec -n voc-core "$pod" -- tail -n "${1:-60}" /var/ossec/logs/ossec.log
      ;;
    api)
      # Escape hatch: voc-wazuh api /agents/summary/status
      [ -z "${1:-}" ] && { echo "Usage: voc-wazuh api <path> [METHOD]"; return 1; }
      _voc_wazuh_api "$1" "${2:-GET}"
      ;;
    *)
      cat << 'EOF'
Usage: voc-wazuh <command>

  status          Manager, agents, and where alerts are being forwarded
  agents          Enrolled agents and their connection state
  alerts [N]      Last N alerts recorded by the manager (default 20)
  test            Generate benign attack + file-tampering events and show
                  what the pipeline made of them
  logs [N]        Tail the manager's ossec.log
  api <path>      Raw Wazuh REST API call, e.g. api /agents/summary/status
EOF
      ;;
  esac
}

voc_refresh() {
  rm -rf "$VOC_STATE_DIR"
  echo "[VOC] Deployment state cleared — next start will do a full redeploy."
}

# Standard CLI Aliases
alias voc-up="voc_up"
alias voc-down="voc_down"
alias voc-status="voc_status"
alias voc-deploy="voc_deploy"
alias voc-scan="voc_scan"
alias voc-prepull="voc_prepull"
alias voc-forward="voc_forward"
alias voc-logs="voc_logs"
alias voc-help="voc_help"
alias voc-run-all="voc_run_all"
alias voc-test-tool="voc_test_tool"
alias voc-history="voc_history"
alias voc-sync-keys="voc_sync_keys"
alias voc-prio="voc_prio"
alias voc-prio-explain="voc_prio_explain"
alias voc-assets="voc_assets"
alias voc-wazuh="voc_wazuh"
alias voc-siem="voc_wazuh"
alias voc-refresh="voc_refresh"

# Short Shorthand Aliases
alias vu="voc_up"
alias vd="voc_down"
alias vs="voc_status"
alias vscan="voc_scan"
alias vh="voc_history"

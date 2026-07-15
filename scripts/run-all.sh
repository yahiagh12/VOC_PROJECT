#!/bin/bash
set -euo pipefail

# ============================================================
# VOC - One Script To Run Everything
# Creates cluster, deploys all services, waits for readiness,
# starts port-forwards in the background, and runs scans.
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[VOC]${NC} $1"; }
log_success() { echo -e "${GREEN}[VOC]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[VOC]${NC} $1"; }
log_section() { echo -e "\n${CYAN}══════════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}══════════════════════════════════════════════════════${NC}\n"; }

# Load .env
if [ -f /workspace/.env ]; then
  set -a; . /workspace/.env; set +a
fi

# Load profile functions
source /workspace/toolbox/profile.sh

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
    sleep 5
    if kubectl get nodes >/dev/null 2>&1; then
      log_success "k3d cluster 'voc' started successfully!"
    else
      log_warning "k3d cluster 'voc' is stale/unreachable even after start. Recreating..."
      k3d cluster delete voc 2>/dev/null || true
      docker network rm voc 2>/dev/null || true
      sleep 2
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
# PHASE 2: DEPLOY EVERYTHING
# ==========================================
log_section "PHASE 2: Deploying Services"

log_info "Creating namespaces..."
kubectl apply -f /workspace/k8s/namespaces/namespaces.yaml 2>/dev/null || true

log_info "Deploying DefectDojo (this takes 2-5 min)..."
voc_deploy dd

log_info "Deploying n8n..."
voc_deploy n8n

log_info "Deploying targets (Juice Shop + DVWA)..."
voc_deploy targets

log_info "Deploying prioritization service..."
voc_deploy prio 2>/dev/null || log_warning "Prioritization service deploy failed (may need image build)"

log_info "Deploying TheHive 5..."
voc_deploy thehive 2>/dev/null || log_warning "TheHive deploy failed (non-critical)"

# Pre-pull scanner images in background (overlaps with Phase 3 readiness waits).
# This eliminates the 1-2 min cold-start penalty on the first voc-scan.
log_info "Pre-pulling scanner images (background)..."
voc_prepull &
PREPULL_PID=$!


# ==========================================
# PHASE 3: WAIT FOR READINESS
# ==========================================
log_section "PHASE 3: Waiting For Services"

log_info "Waiting for PostgreSQL to be ready (up to 5 min)..."
for i in $(seq 1 60); do
  if kubectl get pods -n voc-core --no-headers 2>/dev/null | grep "defectdojo-postgresql" | grep -q "1/1.*Running"; then
    log_success "PostgreSQL is ready!"
    break
  fi
  sleep 5
  printf "."
done
echo ""

log_info "Waiting for DefectDojo to be ready (up to 15 min — first deploy is slow)..."
DD_READY=0
for i in $(seq 1 180); do
  if kubectl get pods -n voc-core --no-headers 2>/dev/null | grep "defectdojo-django" | grep -q "2/2.*Running"; then
    DD_READY=1
    log_success "DefectDojo is ready!"
    break
  fi
  sleep 5
  printf "."
done
echo ""
if [ "$DD_READY" -eq 0 ]; then
  log_error "DefectDojo not ready after 15 min. Current pod status:"
  kubectl get pods -n voc-core --no-headers 2>/dev/null || true
  log_error "Check logs: kubectl logs -n voc-core deploy/defectdojo-django"
  log_warning "Port-forwards and scans will not work until DefectDojo is running."
  log_warning "Wait for pods to be Running, then run: voc-run-all"
fi

log_info "Waiting for n8n to be ready (up to 5 min)..."
for i in $(seq 1 60); do
  if kubectl get pods -n voc-core --no-headers 2>/dev/null | grep "n8n" | grep -v postgresql | grep -q "1/1.*Running"; then
    log_success "n8n is ready!"
    break
  fi
  sleep 5
  printf "."
done
echo ""

log_info "Waiting for targets to be ready (up to 2 min)..."
kubectl wait --for=condition=Ready pod -n targets --all --timeout=120s 2>/dev/null \
  && log_success "Targets are ready!" \
  || log_warning "Some targets not ready"

log_info "Waiting for TheHive to be ready (up to 5 min)..."
for i in $(seq 1 60); do
  if kubectl get pods -n voc-core --no-headers 2>/dev/null | grep "thehive" | grep -q "1/1.*Running"; then
    log_success "TheHive is ready!"
    break
  fi
  sleep 5
  printf "."
done
echo ""


# ==========================================
# PHASE 4: GET API KEY (auto-fetched)
# ==========================================
log_section "PHASE 4: Configuration"

# Get the DD admin password
DD_PASS=$(kubectl get secret defectdojo -n voc-core -o jsonpath='{.data.DD_ADMIN_PASSWORD}' 2>/dev/null | base64 --decode) || DD_PASS="unknown"
log_info "DefectDojo admin password: $DD_PASS"

# Auto-fetch the real API key from the running DefectDojo instance
log_info "Fetching DefectDojo API key from cluster..."
FETCHED_KEY=""
for attempt in $(seq 1 5); do
  FETCHED_KEY=$(kubectl exec deploy/defectdojo-django -n voc-core -c uwsgi -- \
    python manage.py drf_create_token admin 2>/dev/null | grep -oE '[a-f0-9]{40}' | head -1) || true
  if [ -n "$FETCHED_KEY" ]; then
    break
  fi
  sleep 3
done

if [ -n "$FETCHED_KEY" ]; then
  export DD_API_KEY="$FETCHED_KEY"
  log_success "API key fetched: ${FETCHED_KEY:0:8}..."
  # Update the .env file so voc-scan works in future sessions too
  if grep -q '^DD_API_KEY=' /workspace/.env 2>/dev/null; then
    sed -i "s|^DD_API_KEY=.*|DD_API_KEY=$FETCHED_KEY|" /workspace/.env
  fi
fi

# Auto-fetch the real API key from the running TheHive instance
log_info "Fetching TheHive API key from cluster..."
THEHIVE_KEY=""
for attempt in $(seq 1 10); do
  THEHIVE_KEY=$(kubectl exec deploy/thehive -n voc-core -c thehive -- \
    curl -s -X POST -u admin@thehive.local:secret http://localhost:9000/api/v1/user/admin@thehive.local/key/renew 2>/dev/null) || true
  if [[ "$THEHIVE_KEY" =~ ^[a-zA-Z0-9]{32}$ ]]; then
    break
  fi
  THEHIVE_KEY=""
  sleep 3
done

if [ -n "$THEHIVE_KEY" ]; then
  export THEHIVE_API_KEY="$THEHIVE_KEY"
  log_success "TheHive API key fetched: ${THEHIVE_KEY:0:8}..."
  # Provision the secret in voc-core namespace for n8n to read
  kubectl -n voc-core create secret generic thehive-creds \
    --from-literal=api-key="$THEHIVE_KEY" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
  # Update the .env file so the user can use it
  if grep -q '^THEHIVE_API_KEY=' /workspace/.env 2>/dev/null; then
    sed -i "s|^THEHIVE_API_KEY=.*|THEHIVE_API_KEY=$THEHIVE_KEY|" /workspace/.env
  else
    echo "THEHIVE_API_KEY=$THEHIVE_KEY" >> /workspace/.env
  fi
else
  log_warning "Could not auto-fetch TheHive API key. n8n workflow alerts might fail."
fi


# ==========================================
# PHASE 5: PORT FORWARDS (background)
# ==========================================
log_section "PHASE 5: Port Forwards"

# Only start port-forwards if DefectDojo is actually running
if [ "$DD_READY" -eq 0 ]; then
  log_warning "Skipping port-forwards — DefectDojo is not ready yet."
  log_warning "Once pods are Running, run: voc-run-all"
else
  # Kill any existing port-forwards
  pkill -f "kubectl port-forward" 2>/dev/null || true
  sleep 1

  # Launch all port-forwards simultaneously
  log_info "Starting port-forwards (DefectDojo:8080, n8n:5678, Juice Shop:3000, TheHive:9000)..."
  kubectl port-forward --address 0.0.0.0 -n voc-core svc/defectdojo-django 8080:80 >/dev/null 2>&1 &
  kubectl port-forward --address 0.0.0.0 -n voc-core svc/n8n 5678:5678 >/dev/null 2>&1 &
  kubectl port-forward --address 0.0.0.0 -n targets svc/juice-shop 3000:3000 >/dev/null 2>&1 &
  kubectl port-forward --address 0.0.0.0 -n voc-core svc/thehive-svc 9000:9000 >/dev/null 2>&1 &
  # Grafana port-forward (monitoring namespace) — only if the service exists
  if kubectl get svc -n monitoring kps-grafana >/dev/null 2>&1; then
    kubectl port-forward --address 0.0.0.0 -n monitoring svc/kps-grafana 3001:80 >/dev/null 2>&1 &
    log_info "Grafana port-forward started on :3001"
  fi
  sleep 3  # single wait for all to bind

  # Verify DefectDojo port-forward is working (tight loop: 5 attempts, 1s)
  log_info "Verifying DefectDojo is reachable on localhost:8080..."
  PF_OK=0
  for i in $(seq 1 5); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:8080/" 2>/dev/null) || HTTP_CODE="000"
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
      PF_OK=1
      log_success "DefectDojo is reachable at http://localhost:8080"
      break
    fi
    sleep 1
  done
  if [ "$PF_OK" -eq 0 ]; then
    log_warning "Port-forward not responding yet. Try: voc-scan"
  fi
fi



# ==========================================
# PHASE 6: RUN SCANS
# ==========================================
log_section "PHASE 6: Running Vulnerability Scans"

# Ensure pre-pull finished before scanning
if [ -n "${PREPULL_PID:-}" ]; then
  wait "$PREPULL_PID" 2>/dev/null || true
  log_success "Scanner images pre-pulled"
fi

if [ -n "${DD_API_KEY:-}" ] && [ "${DD_API_KEY:-}" != "changeme" ]; then
  log_info "Starting scan pipeline..."
  # Export the key so scan-all.sh inherits it, and run exactly once
  export DD_API_KEY
  bash /workspace/scripts/scan-all.sh 2>&1 || log_warning "Some scans may have failed — check output above"
else
  log_warning "Skipping scans — DD_API_KEY not configured yet"
  log_warning "After setting the API key in .env, run: voc-scan"
fi

# ==========================================
# DONE
# ==========================================
log_section "ALL DONE!"

echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  VOC is fully running!                                   ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}║  DefectDojo:  http://localhost:8080                       ║${NC}"
echo -e "${GREEN}║    User: admin  Password: ${DD_PASS:-check above}                ║${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}║  n8n:         http://localhost:5678                       ║${NC}"
echo -e "${GREEN}║  Juice Shop:  http://localhost:3000                       ║${NC}"
echo -e "${GREEN}║  TheHive:     http://localhost:9000                       ║${NC}"
echo -e "${GREEN}║  Grafana:     http://localhost:3001                       ║${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}║  Run 'voc-scan' to re-run scans                          ║${NC}"
echo -e "${GREEN}║  Run 'voc-history' to view scan history                  ║${NC}"
echo -e "${GREEN}║  Run 'voc-status' to check cluster                       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"

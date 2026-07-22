#!/bin/bash
# VOC helper functions — sourced by entrypoint.sh and available in the shell.

export KUBECONFIG="${KUBECONFIG:-/workspace/.kube/config}"
export REPO_DIR="/workspace"

_voc_start_pf() {
  local ns="$1" svc="$2" ports="$3"
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

  # Start the new port-forward in the background, wrapped in a
  # self-healing supervisor loop: if kubectl port-forward drops
  # (target pod restart, API blip, long-running scan saturating the
  # tunnel), it is restarted within ~2s instead of silently breaking
  # every localhost URL that depends on it.
  nohup bash -c "while true; do kubectl port-forward --address 0.0.0.0 -n '$ns' 'svc/$svc' '$ports' >/dev/null 2>&1; sleep 2; done" >/dev/null 2>&1 &
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

voc_deploy() {
  local target="${1:-all}"
  case "$target" in
    ns|namespaces)
      kubectl apply -f "$REPO_DIR/k8s/namespaces/namespaces.yaml"
      ;;
    dd|defectdojo)
      voc_helm_repo_add defectdojo https://raw.githubusercontent.com/DefectDojo/django-DefectDojo/helm-charts
      helm repo update
      if ! helm upgrade --install defectdojo defectdojo/defectdojo -n voc-core --create-namespace -f "$REPO_DIR/k8s/defectdojo/values.yaml"; then
        echo "[VOC] Helm upgrade failed. If changing persistence, statefulsets cannot be patched."
        echo "[VOC] Deleting defectdojo-postgresql statefulset and retrying..."
        kubectl delete statefulset defectdojo-postgresql -n voc-core || true
        helm upgrade --install defectdojo defectdojo/defectdojo -n voc-core --create-namespace -f "$REPO_DIR/k8s/defectdojo/values.yaml"
      fi
      echo "[VOC] Establishing DefectDojo port-forward..."
      _voc_start_pf voc-core defectdojo-django 8080:80
      ;;
    n8n)
      voc_helm_repo_add community-charts https://community-charts.github.io/helm-charts
      helm repo update
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
          kubectl cp "$REPO_DIR/n8n-workflows/voc-master-dashboard.json" "voc-core/$n8n_pod:/tmp/voc-master-dashboard.json" 2>/dev/null || true
          kubectl exec -n voc-core "$n8n_pod" -- n8n import:workflow --input=/tmp/voc-master-dashboard.json >/dev/null 2>&1 || true
          kubectl exec -n voc-core "$n8n_pod" -- n8n publish:workflow --id=VdT8S1MTBinkKnEH >/dev/null 2>&1 || true
          # 3. Establish port-forward on the active pod
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
          break
        fi
        sleep 2
        attempt=$((attempt + 1))
      done
      ;;
    thehive)
      echo "[VOC] Deploying TheHive 5 (lightweight, no Cassandra)..."
      kubectl apply -f "$REPO_DIR/k8s/thehive/thehive-deployment.yaml"
      echo "[VOC] Establishing TheHive port-forward..."
      _voc_start_pf voc-core thehive-svc 9000:9000
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
      echo "[VOC] Building prioritization-service image..."
      docker build -t prioritization-service:0.1.0 "$REPO_DIR/prioritization-service/"
      echo "[VOC] Importing image into k3d cluster '$cluster'..."
      k3d image import prioritization-service:0.1.0 -c "$cluster"
      # Provision the DD API key secret so the prio service can authenticate
      kubectl -n voc-core create secret generic prioritization-secrets \
        --from-literal=DEFECTDOJO_API_KEY="${DD_API_KEY:-changeme}" \
        --dry-run=client -o yaml | kubectl apply -f -
      kubectl apply -f "$REPO_DIR/prioritization-service/deployment.yaml"
      ;;
    monitoring)
      voc_helm_repo_add prometheus-community https://prometheus-community.github.io/helm-charts
      helm repo update
      kubectl apply -f "$REPO_DIR/k8s/monitoring/" 2>/dev/null || true

      echo "[VOC] Creating Grafana dashboard ConfigMap..."
      kubectl -n monitoring create configmap voc-grafana-dashboards \
        --from-file=voc-master.json="$REPO_DIR/k8s/monitoring/grafana-dashboard.json" \
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
      echo "[VOC] Deploying monitoring (Grafana + Prometheus)..."
      voc_deploy monitoring
      echo ""
      echo "[VOC] Deployment complete. Run 'voc-status' to check."
      echo "[VOC] Get DefectDojo admin password:"
      echo "  kubectl -n voc-core get secret defectdojo-django-secret -o jsonpath='{.data.DD_ADMIN_PASSWORD}' | base64 -d"
      ;;
    *)
      echo "Usage: voc-deploy [ns|dd|n8n|thehive|targets|scanners|prio|monitoring|all]"
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
  k3d image import "${images[@]}" -c "$cluster" 2>/dev/null || echo "[VOC] WARNING: k3d image import had errors (images may already exist)"
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
  cat <<'EOF'
VOC Toolbox Commands:
  voc-up                  Create k3d cluster + namespaces
  voc-down                Delete k3d cluster
  voc-status              Show cluster status (nodes, pods, services)
  voc-deploy <component>  Deploy: ns, dd, n8n, thehive, targets, scanners, prio, monitoring, all
  voc-scan                Run full scan pipeline (~10-12 min)
  voc-scan --quick        Quick scan: skip nuclei + xss (~6 min)
  voc-test-tool <tool> <target>  Run a single scanner (ffuf, sqlmap, etc.) to refine configs
  voc-history             Show scan history from SQLite database
  voc-history --run <N>   Show details for a specific scan run
  voc-prepull             Pre-pull scanner images into k3d (runs automatically on first setup)
  voc-forward <ns/svc> <local:remote>  Port-forward a service
  voc-logs <ns> [pod]     Get pod logs
  voc-help                This message

Workflow:
  1. voc-up                    # create the k3d cluster
  2. voc-deploy all            # deploy the full stack
  3. voc-forward voc-core/defectdojo-django 8080:8080  # access UI
  4. voc-scan                  # run scans and import to DefectDojo
  5. voc-scan --quick          # quick iteration mode

Service URLs (after voc-deploy all):
  DefectDojo:  http://localhost:8080
  n8n:         http://localhost:5678
  Juice Shop:  http://localhost:3000
  TheHive:     http://localhost:9000
  Grafana:     http://localhost:3001

From Windows host (outside toolbox):
  $env:KUBECONFIG = "<repo-root>\.kube\config"
  kubectl get nodes
EOF
}

# Aliases — hyphenated names (as shown in banner)
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

# Short aliases
alias vu="voc_up"
alias vd="voc_down"
alias vs="voc_status"
alias vscan="voc_scan"
alias vh="voc_history"
alias voc-test-tool="bash \$REPO_DIR/scripts/test-tool.sh"

#!/bin/bash
# VOC helper functions — sourced by entrypoint.sh and available in the shell.

export KUBECONFIG="${KUBECONFIG:-/workspace/.kube/config}"
export REPO_DIR="/workspace"

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
      ;;
    n8n)
      voc_helm_repo_add community-charts https://community-charts.github.io/helm-charts
      helm repo update
      helm upgrade --install n8n community-charts/n8n -n voc-core \
        --create-namespace -f "$REPO_DIR/k8s/n8n/values.yaml"
      kubectl apply -f "$REPO_DIR/k8s/n8n/n8n-rbac.yaml"
      ;;
    thehive)
      voc_helm_repo_add thehive https://thehive-project.github.io/TheHive/
      helm repo update
      helm upgrade --install thehive thehive/thehive -n voc-core \
        --create-namespace -f "$REPO_DIR/k8s/thehive/values.yaml"
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
      helm upgrade --install kps prometheus-community/kube-prometheus-stack -n monitoring \
        --create-namespace -f "$REPO_DIR/k8s/monitoring/values.yaml"
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
      echo "[VOC] Deploying monitoring..."
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

# Pre-pull scanner images into the k3d cluster so the first voc-scan
# doesn't spend 1-2 min waiting for containerd to pull them.
voc_prepull() {
  local cluster="${K3D_CLUSTER_NAME:-voc}"
  local images=(
    "projectdiscovery/nuclei:v3.10.0"
    "projectdiscovery/katana:v1.6.1"
    "parrotsec/sqlmap:7.1"
    "parrotsec/ffuf:7.1"
    "anchore/grype:v0.115.0"
    "nenadzaric/gospider:a4244c8"
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

# Short aliases
alias vu="voc_up"
alias vd="voc_down"
alias vs="voc_status"
alias vscan="voc_scan"
alias voc-test-tool="bash \$REPO_DIR/scripts/test-tool.sh"


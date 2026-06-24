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

voc_deploy() {
  local target="${1:-all}"
  case "$target" in
    ns|namespaces)
      kubectl apply -f "$REPO_DIR/k8s/namespaces/namespaces.yaml"
      ;;
    dd|defectdojo)
      helm repo add defectdojo https://raw.githubusercontent.com/DefectDojo/django-DefectDojo/helm-charts 2>/dev/null || true
      helm repo update
      helm upgrade --install defectdojo defectdojo/defectdojo -n voc-core \
        --create-namespace -f "$REPO_DIR/k8s/defectdojo/values.yaml"
      ;;
    n8n)
      helm repo add community-charts https://community-charts.github.io/helm-charts 2>/dev/null || true
      helm repo update
      helm upgrade --install n8n community-charts/n8n -n voc-core \
        --create-namespace -f "$REPO_DIR/k8s/n8n/values.yaml"
      ;;
    thehive)
      helm repo add thehive https://thehive-project.github.io/TheHive/ 2>/dev/null || true
      helm repo update
      helm upgrade --install thehive thehive/thehive -n voc-core \
        --create-namespace -f "$REPO_DIR/k8s/thehive/values.yaml"
      ;;
    targets)
      kubectl apply -f "$REPO_DIR/k8s/targets/"
      ;;
    scanners)
      kubectl -n scanning create secret generic defectdojo-creds \
        --from-literal=url=http://defectdojo-django-svc.voc-core.svc.cluster.local:8080 \
        --from-literal=api-key="${DD_API_KEY:-changeme}" \
        --dry-run=client -o yaml | kubectl apply -f -
      kubectl apply -f "$REPO_DIR/scanners/"
      ;;
    prio|prioritization)
      local cluster="${K3D_CLUSTER_NAME:-voc}"
      echo "[VOC] Building prioritization-service image..."
      docker build -t prioritization-service:0.1.0 "$REPO_DIR/prioritization-service/"
      echo "[VOC] Importing image into k3d cluster '$cluster'..."
      k3d image import prioritization-service:0.1.0 -c "$cluster"
      kubectl apply -f "$REPO_DIR/prioritization-service/deployment.yaml"
      ;;
    monitoring)
      helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
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

voc_scan() {
  bash "$REPO_DIR/scripts/scan-all.sh" "$@"
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
  voc-scan                Run scan pipeline (Grype + Nuclei + ZAP → DefectDojo)
  voc-forward <ns/svc> <local:remote>  Port-forward a service
  voc-logs <ns> [pod]     Get pod logs
  voc-help                This message

Workflow:
  1. voc-up                    # create the k3d cluster
  2. voc-deploy all            # deploy the full stack
  3. voc-forward voc-core/defectdojo-django 8080:8080  # access UI
  4. voc-scan                  # run scans and import to DefectDojo

From Windows host (outside toolbox):
  $env:KUBECONFIG = "C:\Users\Regal\Desktop\voc\.kube\config"
  kubectl get nodes
EOF
}

# Aliases — hyphenated names (as shown in banner)
alias voc-up="voc_up"
alias voc-down="voc_down"
alias voc-status="voc_status"
alias voc-deploy="voc_deploy"
alias voc-scan="voc_scan"
alias voc-forward="voc_forward"
alias voc-logs="voc_logs"
alias voc-help="voc_help"

# Short aliases
alias vu="voc_up"
alias vd="voc_down"
alias vs="voc_status"
alias vscan="voc_scan"

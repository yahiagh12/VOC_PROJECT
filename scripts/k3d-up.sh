#!/bin/bash
set -euo pipefail

# ============================================================
# VOC - k3d cluster setup
# Creates a k3d (k3s-in-docker) cluster + namespaces.
# Runs inside the VOC toolbox container.
# ============================================================

CLUSTER_NAME="${K3D_CLUSTER_NAME:-voc}"
API_PORT="${K3D_API_PORT:-6550}"
HOST="${K3D_HOST:-host.docker.internal}"
KUBE_DIR="/workspace/.kube"

echo "[VOC] Creating k3d cluster '$CLUSTER_NAME' (API port $API_PORT)..."

# Create docker network if it doesn't exist
docker network inspect "$CLUSTER_NAME" >/dev/null 2>&1 || docker network create "$CLUSTER_NAME"

# Create k3d cluster if it doesn't exist
if k3d cluster list "$CLUSTER_NAME" 2>/dev/null | grep -q "$CLUSTER_NAME"; then
  echo "[VOC] Cluster '$CLUSTER_NAME' already exists."
else
  k3d cluster create "$CLUSTER_NAME" \
    --api-port "$API_PORT" \
    --network "$CLUSTER_NAME" \
    --agents 0 \
    --wait \
    --timeout 120s
  echo "[VOC] Cluster created."
fi

# Connect the toolbox container to the cluster network (so it can reach
# k3d services and port-forwards via container DNS)
docker network connect "$CLUSTER_NAME" voc 2>/dev/null || true

# Write kubeconfig to /workspace/.kube/config (accessible from Windows host too)
mkdir -p "$KUBE_DIR"
k3d kubeconfig merge "$CLUSTER_NAME" --output "$KUBE_DIR/config" --overwrite

# Fix the server URL: k3d writes 0.0.0.0 which doesn't work from inside
# another container. Replace with host.docker.internal (Docker host).
sed -i "s|server: https://0.0.0.0:${API_PORT}|server: https://${HOST}:${API_PORT}|g" "$KUBE_DIR/config"
sed -i "s|server: https://localhost:${API_PORT}|server: https://${HOST}:${API_PORT}|g" "$KUBE_DIR/config"

export KUBECONFIG="$KUBE_DIR/config"

# Wait for the node to be Ready
echo "[VOC] Waiting for cluster to be ready..."
kubectl wait --for=condition=Ready node --all --timeout=120s

# Create namespaces
echo "[VOC] Creating namespaces..."
kubectl apply -f /workspace/k8s/namespaces/namespaces.yaml

# Done
echo ""
echo "[VOC] Cluster is ready!"
kubectl get nodes
echo ""
echo "[VOC] Namespaces:"
kubectl get ns | grep voc
echo ""
echo "Next steps:"
echo "  1. voc-deploy all           # deploy the full stack"
echo "  2. voc-status               # check pod status"
echo ""
echo "From Windows host (outside toolbox):"
echo "  \$env:KUBECONFIG = 'C:\Users\Regal\Desktop\voc\.kube\config'"
echo "  kubectl get nodes"

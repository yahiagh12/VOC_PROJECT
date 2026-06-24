#!/usr/bin/env bash
# Run INSIDE the WSL Ubuntu shell (after admin-setup.ps1 + first launch of Ubuntu).
# Installs k3s, helm, kubectl, and docker (docker is only for local image builds;
# k3s itself runs its own containerd).
set -euo pipefail

WIN_USER="Regal"
REPO="/mnt/c/${WIN_USER}/Desktop/voc"

echo "==> apt update + upgrade"
sudo apt update
sudo apt -y upgrade

echo "==> base tools"
sudo apt -y install curl ca-certificates

echo "==> helm"
if ! command -v helm >/dev/null 2>&1; then
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
helm version

echo "==> k3s (single-node cluster)"
if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | sh -
fi
echo "==> waiting for k3s node to be Ready..."
sleep 5
sudo k3s kubectl get nodes

echo "==> standalone kubectl"
if ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL_VER="$(curl -L -s https://dl.k8s.io/release/stable.txt)"
  curl -LO "https://dl.k8s.io/release/${KUBECTL_VER}/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm -f kubectl
fi

echo "==> docker (for local image builds)"
if ! command -v docker >/dev/null 2>&1; then
  sudo apt -y install docker.io
  sudo usermod -aG docker "$USER"
  echo "  (docker group added; log out/in of WSL if 'docker ps' needs no sudo)"
fi

echo "==> kubeconfig for current user"
mkdir -p "$HOME/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
sudo chown "$USER:$USER" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"
grep -q 'KUBECONFIG' "$HOME/.bashrc" || echo 'export KUBECONFIG="$HOME/.kube/config"' >> "$HOME/.bashrc"
export KUBECONFIG="$HOME/.kube/config"
kubectl get nodes

echo ""
echo "WSL setup done. Now on Windows PowerShell run:"
echo "  powershell -ExecutionPolicy Bypass -File ${REPO}/scripts/wire-kubeconfig.ps1"
echo "Then continue with docs/setup.md from section 4 (Namespaces)."

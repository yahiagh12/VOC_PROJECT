#!/bin/bash
set -e

# Source .env if present
if [ -f /workspace/.env ]; then
  set -a
  . /workspace/.env
  set +a
fi

# Source helper functions
source /opt/voc/profile.sh

# Welcome banner
cat <<'BANNER'
╔══════════════════════════════════════════════════════════╗
║                  VOC Dev Toolbox                         ║
╠══════════════════════════════════════════════════════════╣
║  voc-up         Create k3d cluster + namespaces          ║
║  voc-down       Delete k3d cluster                       ║
║  voc-status     Show cluster status                      ║
║  voc-deploy     Deploy components (ns/dd/n8n/th/targets) ║
║  voc-scan       Run scan pipeline (Grype+Nuclei)         ║
║  voc-forward    Port-forward a service                   ║
║  voc-logs       Get pod logs                             ║
║  voc-help       Show all commands                        ║
╚══════════════════════════════════════════════════════════╝
BANNER

# Check docker socket
if [ -S /var/run/docker.sock ]; then
  echo "[VOC] Docker socket: OK"
else
  echo "[VOC] WARNING: /var/run/docker.sock not found."
  echo "       Start with: docker compose run --rm voc"
fi

# Check kubeconfig
if [ -f "$KUBECONFIG" ]; then
  echo "[VOC] Kubeconfig: found at $KUBECONFIG"
else
  echo "[VOC] No kubeconfig yet. Run 'voc-up' to create a k3d cluster."
fi

echo ""

# Drop to interactive shell
exec "$@"

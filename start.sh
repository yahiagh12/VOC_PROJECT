#!/bin/bash
# VOC - One Click Start (Linux/macOS)
# Run: chmod +x start.sh && ./start.sh

set -e

echo ""
echo "========================================"
echo "  VOC - Starting Everything...          "
echo "========================================"
echo ""

# Build the toolbox image
echo "[VOC] Building toolbox image..."
docker compose build

# Clean up any leftover containers that might hold ports
echo "[VOC] Cleaning up old containers..."
docker compose down 2>/dev/null || true
docker rm -f juice-shop dvwa 2>/dev/null || true

# Run the toolbox: source profile, run the full setup, then drop into interactive bash
echo "[VOC] Starting toolbox and deploying everything..."
echo "[VOC] This will take 5-10 minutes on first run."
echo ""

docker compose run --service-ports --rm voc bash -c '
  source /workspace/toolbox/profile.sh
  bash /workspace/scripts/run-all.sh
  echo ""
  echo "=============================================="
  echo "  VOC is ready! You are now in the toolbox."
  echo "  Port-forwards are running in the background."
  echo "  Type voc-scan to re-run scans."
  echo "  Type voc-status to check the cluster."
  echo "=============================================="
  echo ""
  exec bash --init-file /workspace/toolbox/profile.sh
'

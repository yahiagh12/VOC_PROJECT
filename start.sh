#!/bin/bash
# VOC - One Click Start (Linux/macOS)
# Run: chmod +x start.sh && ./start.sh

set -e

echo ""
echo "========================================"
echo "  VOC - Starting Everything...          "
echo "========================================"
echo ""

# Only rebuild if toolbox files changed (saves ~30s on restarts)
if command -v sha256sum >/dev/null 2>&1; then
  HASH=$(cat toolbox/Dockerfile toolbox/entrypoint.sh toolbox/profile.sh | sha256sum | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1; then
  HASH=$(cat toolbox/Dockerfile toolbox/entrypoint.sh toolbox/profile.sh | shasum -a 256 | cut -d' ' -f1)
else
  HASH="fallback-hash-$(date +%s)"
fi
CACHE_FILE=".toolbox-build-hash"
CACHED=$(cat "$CACHE_FILE" 2>/dev/null || echo "")
if [ "$HASH" != "$CACHED" ]; then
    echo "[VOC] Toolbox files changed — rebuilding image..."
    docker compose build
    echo -n "$HASH" > "$CACHE_FILE"
else
    echo "[VOC] Toolbox image up to date (skipping build)"
fi

# Clean up any leftover containers that might hold ports
echo "[VOC] Cleaning up old containers..."
docker compose down --remove-orphans 2>/dev/null || true
docker rm -f $(docker ps -q --filter name=voc) 2>/dev/null || true
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

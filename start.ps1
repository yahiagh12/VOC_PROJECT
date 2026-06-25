# VOC - One Click Start
# Double-click this file or run it in PowerShell to start everything.
# It builds the container, enters it, deploys all services, and drops you into a shell.

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  VOC - Starting Everything...          " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Build the toolbox image
Write-Host "[VOC] Building toolbox image..." -ForegroundColor Yellow
docker compose build

# Clean up any leftover containers that might hold ports
Write-Host "[VOC] Cleaning up old containers..." -ForegroundColor Yellow
docker compose down 2>$null
docker rm -f juice-shop dvwa 2>$null

# Run the toolbox: source profile, run the full setup, then drop into interactive bash
Write-Host "[VOC] Starting toolbox and deploying everything..." -ForegroundColor Green
Write-Host "[VOC] This will take 5-10 minutes on first run." -ForegroundColor Yellow
Write-Host ""

docker compose run --service-ports --rm voc bash -c "
  source /workspace/toolbox/profile.sh
  bash /workspace/scripts/run-all.sh
  echo ''
  echo '=============================================='
  echo '  VOC is ready! You are now in the toolbox.'
  echo '  Port-forwards are running in the background.'
  echo '  Type voc-scan to re-run scans.'
  echo '  Type voc-status to check the cluster.'
  echo '=============================================='
  echo ''
  exec bash --init-file /workspace/toolbox/profile.sh
"

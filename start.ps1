# VOC - One Click Start
# Double-click this file or run it in PowerShell to start everything.
# It builds the container, enters it, deploys all services, and drops you into a shell.

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  VOC - Starting Everything...          " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Only rebuild if toolbox files changed (saves ~30s on restarts)
$toolboxFiles = @(".\toolbox\Dockerfile", ".\toolbox\entrypoint.sh", ".\toolbox\profile.sh")
$hash = ($toolboxFiles | ForEach-Object { (Get-FileHash $_).Hash }) -join ""
$cacheFile = ".\.toolbox-build-hash"
$cached = if (Test-Path $cacheFile) { Get-Content $cacheFile -Raw } else { "" }
if ($hash -ne $cached.Trim()) {
    Write-Host "[VOC] Toolbox files changed - rebuilding image..." -ForegroundColor Yellow
    docker compose build
    $hash | Set-Content $cacheFile -NoNewline
} else {
    Write-Host "[VOC] Toolbox image up to date (skipping build)" -ForegroundColor Green
}

# Clean up any leftover containers that might hold ports
Write-Host "[VOC] Cleaning up old containers..." -ForegroundColor Yellow
docker compose down 2>$null
docker rm -f juice-shop dvwa 2>$null

# Run the toolbox: source profile, run the full setup, then drop into interactive bash
Write-Host "[VOC] Starting toolbox and deploying everything..." -ForegroundColor Green
Write-Host "[VOC] This will take 5-10 minutes on first run." -ForegroundColor Yellow
Write-Host ""

# PowerShell keeps CRLF in the here-string (this file is CRLF per
# .gitattributes), but bash inside the container chokes on the \r that
# ends up inside the multi-line `bash -c` argument. Strip \r before
# passing the script to docker so bash sees clean LF line endings.
$bashScript = @"
  source /workspace/toolbox/profile.sh
  bash /workspace/scripts/run-all.sh
  echo ''
  echo '=============================================='
  echo '  VOC is ready! You are now in the toolbox.'
  echo '  Port-forwards are running in the background.'
  echo '  Type voc-scan to re-run scans.'
  echo '  Type voc-history to view scan history.'
  echo '  Type voc-status to check the cluster.'
  echo '=============================================='
  echo ''
  exec bash --init-file /workspace/toolbox/profile.sh
"@
$bashScript = $bashScript -replace "`r`n", "`n"

docker compose run --service-ports --rm voc bash -c $bashScript

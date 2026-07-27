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
docker compose down --remove-orphans 2>$null
$oldVocContainers = docker ps -q --filter name=voc
if ($oldVocContainers) { docker rm -f $oldVocContainers 2>$null }
docker rm -f juice-shop dvwa 2>$null

# Run the toolbox: source profile, run the full setup, then drop into interactive bash
Write-Host "[VOC] Starting toolbox and deploying everything..." -ForegroundColor Green
Write-Host "[VOC] First run takes 5-10 min. Later starts reuse the existing cluster" -ForegroundColor Yellow
Write-Host "[VOC] and skip unchanged deploys - typically well under a minute." -ForegroundColor Yellow
Write-Host ""
Write-Host '[VOC] Optional switches (set before running this script):' -ForegroundColor DarkGray
Write-Host '        $env:VOC_ENABLE_WAZUH=1       # Wazuh SIEM manager' -ForegroundColor DarkGray
Write-Host '        $env:VOC_ENABLE_MONITORING=1  # Grafana + Prometheus' -ForegroundColor DarkGray
Write-Host '        $env:VOC_SCAN_ON_START=1      # always run scans on start' -ForegroundColor DarkGray
Write-Host '        $env:VOC_FORCE_DEPLOY=1       # ignore the deploy state cache' -ForegroundColor DarkGray
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
  echo '  Type voc-scan    to run scans.'
  echo '  Type voc-prio    to re-prioritize findings.'
  echo '  Type voc-history to view scan history.'
  echo '  Type voc-status  to check the cluster.'
  echo '  Type voc-help    for everything else.'
  echo '=============================================='
  echo ''
  exec bash --init-file /workspace/toolbox/profile.sh
"@
$bashScript = $bashScript -replace "`r`n", "`n"

docker compose run --service-ports --rm voc bash -c $bashScript

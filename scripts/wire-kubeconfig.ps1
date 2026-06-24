# Run on Windows (NOT admin needed). Copies the kubeconfig from WSL Ubuntu
# and points the server at localhost so Windows kubectl can reach the WSL2 k3s.
$ErrorActionPreference = 'Stop'

$winUser = $env:USERNAME
$kubeDir = Join-Path $env:USERPROFILE '.kube'
New-Item -ItemType Directory -Path $kubeDir -Force | Out-Null

Write-Host "Copying kubeconfig from WSL to $kubeDir\config ..."
wsl bash -c "cp -- `"`$HOME/.kube/config`" `"/mnt/c/Users/$winUser/.kube/config`""

if (-not (Test-Path (Join-Path $kubeDir 'config'))) {
  throw "kubeconfig not copied. Did wsl-setup.sh complete? Is $winUser your Windows username?"
}

$config = Join-Path $kubeDir 'config'
(Get-Content $config) -replace 'server:\s*https://127\.0\.0\.1:6443', 'server: https://localhost:6443' |
  Set-Content $config

Write-Host 'Verifying cluster from Windows:'
& "$env:USERPROFILE\scoop\shims\kubectl.exe" get nodes

Write-Host ''
Write-Host 'If the node is listed, kubectl is wired up. Continue with docs/setup.md.'
Write-Host 'If "localhost:6443" is unreachable, set a portproxy (elevated):'
Write-Host "  netsh interface portproxy add v4tov4 listenport=6443 connectaddress=$(wsl hostname -I | ForEach-Object { $_.Trim().Split(' ')[0] }) connectport=6443"

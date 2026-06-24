#Requires -RunAsAdministrator
# Run this in an ELEVATED PowerShell (Right-click PowerShell -> Run as administrator).
# Enables WSL2 and installs the Ubuntu distro (does not launch it).
$ErrorActionPreference = 'Stop'

Write-Host 'Installing WSL2 + Ubuntu (enables the required Windows features)...'
wsl --install -d Ubuntu --no-launch
wsl --set-default-version 2

Write-Host ''
Write-Host 'If Windows prompted you to reboot, REBOOT NOW.'
Write-Host 'Then launch "Ubuntu" from the Start menu to set your UNIX username + password.'
Write-Host 'After that, inside the Ubuntu shell run:'
Write-Host '  bash /mnt/c/Users/Regal/Desktop/voc/scripts/wsl-setup.sh'

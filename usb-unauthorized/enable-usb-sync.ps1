#Requires -RunAsAdministrator
<#
  enable-usb-sync.ps1  - one-time per-agent onboarding for the USB whitelist sync (Windows).
  Does everything needed on an agent in one run:
    1. deploys hybrid_sync_usb.ps1 into the Wazuh AR bin folder
    2. enables logcollector.remote_commands=1 (REQUIRED - agents ignore the
       manager's <command> without it; it can ONLY be set locally, by design)
    3. restarts the Wazuh agent
    4. runs the sync once to prove it works

  Run:  powershell -ExecutionPolicy Bypass -File .\enable-usb-sync.ps1
  Uses hybrid_sync_usb.ps1 sitting next to this file if present, else downloads it.
#>
param(
    [string]$SyncUrl = "https://cdn.jsdelivr.net/gh/yekyawhan/wazuh@git-home/usb-unauthorized/hybrid_sync_usb.ps1",
    [switch]$SkipRun
)
$ErrorActionPreference = "Stop"

$agentDir = "C:\Program Files (x86)\ossec-agent"
$binDir   = "$agentDir\active-response\bin"
$dest     = "$binDir\hybrid_sync_usb.ps1"
$lio      = "$agentDir\local_internal_options.conf"

if (-not (Test-Path $agentDir)) { Write-Host "Wazuh agent not found at $agentDir - is the agent installed?" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }

# 1. deploy the sync script (local copy next to this installer first, else download)
$localCopy = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'hybrid_sync_usb.ps1' } else { $null }
if ($localCopy -and (Test-Path $localCopy)) {
    Copy-Item $localCopy $dest -Force
    Write-Host "[1/4] deployed hybrid_sync_usb.ps1 from local copy -> $dest"
} else {
    [Net.ServicePointManager]::SecurityProtocol = 'Tls12'
    Invoke-WebRequest -Uri $SyncUrl -OutFile $dest -UseBasicParsing
    Write-Host "[1/4] downloaded hybrid_sync_usb.ps1 -> $dest"
}

# 2. enable remote commands (idempotent - can only be set locally on the agent)
if (-not (Test-Path $lio)) { New-Item -ItemType File -Path $lio -Force | Out-Null }
if (-not (Select-String -Path $lio -Pattern '^\s*logcollector\.remote_commands\s*=\s*1' -Quiet)) {
    Add-Content -Path $lio -Value "logcollector.remote_commands=1"
    Write-Host "[2/4] enabled logcollector.remote_commands=1"
} else {
    Write-Host "[2/4] logcollector.remote_commands=1 already set"
}

# 3. restart the agent so the new setting takes effect
Restart-Service WazuhSvc -Force
Start-Sleep -Seconds 3
Write-Host "[3/4] WazuhSvc restarted (status: $((Get-Service WazuhSvc).Status))"

# 4. run the sync once now to prove it works
if (-not $SkipRun) {
    Write-Host "[4/4] running sync once..."
    & powershell -ExecutionPolicy Bypass -File $dest
} else {
    Write-Host "[4/4] skipped immediate run (will run on the agent.conf schedule)"
}

Write-Host ""
Write-Host "DONE - this agent is onboarded." -ForegroundColor Green
Write-Host "Manager side (once): put usb_whitelist.txt in /var/ossec/etc/shared/default/ and add the agent.conf <command> block."
Write-Host "If the sync said 'Whitelist file not found', that's expected until the manager pushes usb_whitelist.txt."

# Start-UsbWatcher.ps1 — Long-lived watcher (run interactively or via Wazuh).
# Triggers a re-sync within 3s of any change to usb_whitelist.txt.
# Ctrl+C to stop.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot 'config\config.ps1')

Import-Module (Join-Path $ScriptRoot 'modules\Logger.psm1')   -Force
Import-Module (Join-Path $ScriptRoot 'modules\Utils.psm1')    -Force
Import-Module (Join-Path $ScriptRoot 'modules\Parser.psm1')   -Force
Import-Module (Join-Path $ScriptRoot 'modules\Registry.psm1') -Force
Import-Module (Join-Path $ScriptRoot 'modules\Policy.psm1')   -Force
Import-Module (Join-Path $ScriptRoot 'modules\Watcher.psm1')  -Force

Initialize-Logger -LogDir $UsbSync.LogDir -LogFileName $UsbSync.WatcherLogFile `
    -EventSource $UsbSync.EventLogSource -EventLogName $UsbSync.EventLogName

if ($UsbSync.RequireAdmin -and -not (Test-IsAdministrator)) {
    Write-LogError 'Administrator privileges required.'
    exit 1
}

# Run once at startup
[void](Invoke-HybridUsbSync)

# Then watch
$path = Get-UsbWhitelistPath
$cb = {
    Write-LogInfo "Whitelist change detected. Re-syncing."
    [void](Invoke-HybridUsbSync)
}
[void](Start-UsbWhitelistWatcher -Path $path -OnChange $cb)
Write-LogInfo "Watcher active on $path. Ctrl+C to stop."

try {
    while ($true) { Start-Sleep -Seconds 60 }
} finally {
    Stop-UsbWhitelistWatcher
}

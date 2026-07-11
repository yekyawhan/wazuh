# hybrid_sync_usb_v2.ps1 — Entry point
# Modes:
#   (default)   — one-shot sync
#   --watch     — run sync + start FileSystemWatcher (used by Scheduled Task)

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

function Invoke-HybridUsbSync {
    [CmdletBinding()]
    param()

    Initialize-Logger -LogDir $UsbSync.LogDir -LogFileName $UsbSync.LogFile `
        -EventSource $UsbSync.EventLogSource -EventLogName $UsbSync.EventLogName

    if ($UsbSync.RequireAdmin -and -not (Test-IsAdministrator)) {
        Write-LogError 'Administrator privileges required. Aborting.'
        return $false
    }

    $whitelistPath = Get-UsbWhitelistPath
    Write-LogInfo "Sync started. Whitelist: $whitelistPath"

    try {
        $entries = Merge-Whitelist -Path $whitelistPath
        Write-LogInfo "Parsed $($entries.Count) unique device(s)."

        if ($entries.Count -eq 0) {
            Write-LogWarning "Whitelist is empty. Blocking ALL USB devices (Deny-mode: enabled + empty list)."
            Set-UsbAllowList -DeviceIds @()
        } else {
            Set-UsbAllowList -DeviceIds $entries.DeviceId
        }

        # Refresh device install policy so new allow-list takes effect immediately
        Invoke-GpUpdate

        Write-LogAudit "Sync completed. Devices: $($entries.Count)"
        return $true
    } catch {
        Write-LogError "Sync failed: $($_.Exception.Message)"
        return $false
    }
}

function Start-HybridUsbWatcher {
    [CmdletBinding()]
    param()
    Initialize-Logger -LogDir $UsbSync.LogDir -LogFileName $UsbSync.LogFile `
        -EventSource $UsbSync.EventLogSource -EventLogName $UsbSync.EventLogName

    if ($UsbSync.RequireAdmin -and -not (Test-IsAdministrator)) {
        Write-LogError 'Administrator privileges required. Aborting watcher.'
        return
    }

    # Run once at startup, then watch
    [void](Invoke-HybridUsbSync)

    $path = Get-UsbWhitelistPath
    $callback = {
        Write-LogInfo "Whitelist change detected. Re-syncing."
        [void](Invoke-HybridUsbSync)
    }
    [void](Start-UsbWhitelistWatcher -Path $path -OnChange $callback)

    Write-LogInfo "Watcher mode. Press Ctrl+C to stop."
    try {
        while ($true) { Start-Sleep -Seconds 60 }
    } finally {
        Stop-UsbWhitelistWatcher
    }
}

# Run when invoked directly (not when dot-sourced)
if ($MyInvocation.InvocationName -ne '.') {
    if ($args -contains '--watch') {
        Start-HybridUsbWatcher
    } else {
        $ok = Invoke-HybridUsbSync
        exit $(if ($ok) { 0 } else { 1 })
    }
}

Export-ModuleMember -Function @(
    'Invoke-HybridUsbSync',
    'Start-HybridUsbWatcher'
)

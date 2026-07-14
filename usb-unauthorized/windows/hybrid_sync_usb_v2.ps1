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

<#
.SYNOPSIS
    Performs a one-shot sync: read whitelist, apply allow-list policy, refresh.

.DESCRIPTION
    Reads the Wazuh-shared usb_whitelist.txt, parses/dedupes device IDs, and
    applies them via the device-install allow-list. Empty whitelist => block
    all. Runs gpupdate /force afterward. Logs to file + Event Log.

.OUTPUTS
    [bool] true on success.
#>
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
        $entries = @(Merge-Whitelist -Path $whitelistPath)
        Write-LogInfo "Parsed $($entries.Count) unique device(s)."

        if ($entries.Count -eq 0) {
            Write-LogWarning "Whitelist is empty. Blocking ALL USB devices (Deny-mode: enabled + empty list)."
            Set-UsbAllowList -DeviceIds @()
        } else {
            Set-UsbAllowList -DeviceIds $entries.DeviceId
        }

        # Refresh device install policy so new allow-list takes effect immediately
        Invoke-GpUpdate

        # Enforce policy on pre-existing devices (Option 3: boot-time check)
        # Devices plugged in before policy was set remain allowed by Windows.
        # This scan runs on every boot and every 5-min sync to catch pre-existing devices.
        try {
            $connectedDevices = Get-PnpDevice -Class USB -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'OK' }
            $whitelistedIds = @($entries.DeviceId) + @($UsbSync.StorageLayerIds)
            $blocked = 0
            foreach ($dev in $connectedDevices) {
                # Extract device ID from InstanceId (format: USB\VID_XXXX&PID_YYYY\serial)
                # We match against VID_XXXX&PID_YYYY or the first two parts
                $devId = $dev.InstanceId -replace '^([^\\]+\\[^\\]+).*', '$1'
                $allowed = $false
                foreach ($wl in $whitelistedIds) {
                    if ($devId -like "*$wl*" -or $wl -like "*$devId*") {
                        $allowed = $true
                        break
                    }
                }
                if (-not $allowed) {
                    Write-LogWarning "Non-whitelisted USB device detected: $($dev.FriendlyName) [$devId]. Disabling."
                    try {
                        Disable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction Stop
                        $blocked++
                    } catch {
                        Write-LogError "Failed to disable $($dev.InstanceId): $($_.Exception.Message)"
                    }
                }
            }
            if ($blocked -gt 0) {
                Write-LogAudit "Boot-time enforcement: disabled $blocked non-whitelisted device(s)."
            }
        } catch {
            Write-LogWarning "Boot-time enforcement check failed: $($_.Exception.Message)"
        }

        Write-LogAudit "Sync completed. Devices: $($entries.Count)"
        return $true
    } catch {
        Write-LogError "Sync failed: $($_.Exception.Message)"
        return $false
    }
}

<#
.SYNOPSIS
    Runs the sync once, then watches the whitelist file for changes.

.DESCRIPTION
    Intended for the scheduled task. Performs an initial sync, starts a
    FileSystemWatcher (3s debounce) that re-syncs on edit, and blocks until
    Ctrl+C (stopping the watcher cleanly on exit).

#>
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

# Run when invoked directly (not when dot-sourced).
# NOTE: no Export-ModuleMember here — this is a .ps1, not a module. Calling it
# would throw and break both -File execution and dot-sourcing from the installer.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        # --watch is deprecated for task-scheduler use (long-lived processes
        # under SYSTEM exit non-zero after the task window ends). The dedicated
        # Start-UsbWatcher.ps1 is the long-lived watcher entry-point.
        if ($args -contains '--watch') {
            Start-HybridUsbWatcher
            exit 0
        } else {
            $ok = Invoke-HybridUsbSync
            exit $(if ($ok) { 0 } else { 1 })
        }
    } catch {
        # Last-resort logging so a scheduled-task failure is never invisible.
        try {
            $bootLog = Join-Path $env:ProgramData 'Wazuh\Logs\UsbSync\bootstrap-error.log'
            $dir = Split-Path $bootLog -Parent
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
            Add-Content -LiteralPath $bootLog -Value "$stamp FATAL $($_.Exception.Message)`n$($_.ScriptStackTrace)" -Encoding UTF8
        } catch { }
        exit 1
    }
}

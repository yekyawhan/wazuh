# uninstall_usb_sync_windows.ps1 — Uninstaller
# Idempotent. Unregisters task, restores default device install policy.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppRoot    = Split-Path -Parent $ScriptRoot
. (Join-Path $AppRoot 'config\config.ps1')

Import-Module (Join-Path $AppRoot 'modules\Logger.psm1')   -Force
Import-Module (Join-Path $AppRoot 'modules\Utils.psm1')    -Force
Import-Module (Join-Path $AppRoot 'modules\Policy.psm1')   -Force

<#
.SYNOPSIS
    Uninstalls the Wazuh Hybrid USB Sync.

.DESCRIPTION
    Idempotent. Stops and unregisters the scheduled task, restores the default
    device-install policy (all-allowed), and optionally purges logs. Must run
    elevated.

.PARAMETER PurgeLogs
    Also delete C:\ProgramData\Wazuh\Logs\UsbSync.

.OUTPUTS
    [int] 0 success, 1 not-admin, 2 uninstall error.
#>
function Uninstall-UsbSync {
    [CmdletBinding()]
    param(
        [switch]$PurgeLogs,
        [switch]$PurgeAll
    )

    Initialize-Logger -LogDir $UsbSync.LogDir -LogFileName $UsbSync.InstallLogFile `
        -EventSource $UsbSync.EventLogSource -EventLogName $UsbSync.EventLogName

    if (-not (Test-IsAdministrator)) {
        Write-LogError 'Uninstaller requires Administrator.'
        return 1
    }

    try {
        # 1. Stop + unregister task
        $task = Get-ScheduledTask -TaskName $UsbSync.TaskName -ErrorAction SilentlyContinue
        if ($task) {
            Stop-ScheduledTask -TaskName $UsbSync.TaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $UsbSync.TaskName -Confirm:$false
            Write-LogInfo "Task unregistered: $($UsbSync.TaskName)"
        } else {
            Write-LogInfo "Task not present (already uninstalled). Skipping."
        }

        # 2. Restore default policy (Remove-UsbAllowList deletes the Restrictions key
        #    entirely so Windows returns fully to "all devices allowed" state)
        try { Remove-UsbAllowList }
        catch { Write-LogWarning "Policy remove failed: $($_.Exception.Message)" }

        # 3. Optional log purge
        if (($PurgeLogs -or $PurgeAll) -and (Test-Path -LiteralPath $UsbSync.LogDir)) {
            Remove-Item -LiteralPath (Join-Path $UsbSync.LogDir '*') -Recurse -Force -ErrorAction SilentlyContinue
            Write-LogInfo 'Logs purged.'
        }

        # 4. --purge-all: also wipe the app install dir (C:\ProgramData\Wazuh\UsbSync)
        if ($PurgeAll -and (Test-Path -LiteralPath $UsbSync.AppRoot)) {
            Remove-Item -LiteralPath $UsbSync.AppRoot -Recurse -Force -ErrorAction SilentlyContinue
            Write-LogInfo "App data purged: $($UsbSync.AppRoot)"
        }

        Write-LogAudit "Uninstall complete. Version $($UsbSync.Version)"
        Write-Host "[OK] Wazuh Hybrid USB Sync uninstalled."
        return 0
    } catch {
        Write-LogError "Uninstall failed: $($_.Exception.Message)"
        return 2
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $purge = $args -contains '--purge-logs'
    $purgeAll = $args -contains '--purge-all'
    exit (Uninstall-UsbSync -PurgeLogs:$purge -PurgeAll:$purgeAll)
}

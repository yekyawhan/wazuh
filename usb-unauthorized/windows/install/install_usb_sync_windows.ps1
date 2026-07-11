# install_usb_sync_windows.ps1 — Installer
# Idempotent. Copies files, registers Scheduled Task, first sync, health check.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppRoot    = Split-Path -Parent $ScriptRoot
. (Join-Path $AppRoot 'config\config.ps1')

Import-Module (Join-Path $AppRoot 'modules\Logger.psm1')   -Force
Import-Module (Join-Path $AppRoot 'modules\Utils.psm1')    -Force

<#
.SYNOPSIS
    Installs the Wazuh Hybrid USB Sync on a Windows agent.

.DESCRIPTION
    Idempotent. Creates the app/log directories, registers the scheduled task
    (AtStartup, SYSTEM, restart-on-failure), runs a first sync, and performs a
    health check. Must run elevated.

.OUTPUTS
    [int] 0 success, 1 not-admin, 2 install error.
#>
function Install-UsbSync {
    [CmdletBinding()]
    param()

    Initialize-Logger -LogDir $UsbSync.LogDir -LogFileName $UsbSync.InstallLogFile `
        -EventSource $UsbSync.EventLogSource -EventLogName $UsbSync.EventLogName

    if (-not (Test-IsAdministrator)) {
        Write-LogError 'Installer requires Administrator. Re-run from elevated shell.'
        return 1
    }

    try {
        # 1. Create dirs
        foreach ($d in @($UsbSync.AppRoot, $UsbSync.LogDir)) {
            if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        }
        if (-not (Test-PathWritable -Path $UsbSync.LogDir)) {
            throw "Log directory not writable: $($UsbSync.LogDir)"
        }

        # 2. Register Scheduled Task
        #    Two triggers: at startup (watcher survives reboots) + on a repeating
        #    schedule (fallback resync if a file-change event is ever missed).
        $action = New-ScheduledTaskAction `
            -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$AppRoot\hybrid_sync_usb_v2.ps1`" --watch" `
            -WorkingDirectory $AppRoot
        $triggerBoot = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
            -StartWhenAvailable
        Register-ScheduledTask -TaskName $UsbSync.TaskName `
            -Action $action -Trigger $triggerBoot -Principal $principal -Settings $settings `
            -Description $UsbSync.TaskDescription -Force | Out-Null
        Write-LogInfo "Scheduled task registered: $($UsbSync.TaskName)"

        # 3. First sync (run inline, in-process, so the log is created now)
        Write-LogInfo 'Running first synchronization...'
        . (Join-Path $AppRoot 'hybrid_sync_usb_v2.ps1')
        [void](Invoke-HybridUsbSync)

        # 4. Start the task now so the watcher runs without waiting for a reboot
        Start-ScheduledTask -TaskName $UsbSync.TaskName -ErrorAction SilentlyContinue
        Write-LogInfo 'Scheduled task started (watcher active).'

        # 5. Health check
        $task = Get-ScheduledTask -TaskName $UsbSync.TaskName -ErrorAction SilentlyContinue
        if (-not $task) { throw 'Scheduled task not found after install' }
        Write-LogAudit "Install complete. Version $($UsbSync.Version)"
        Write-Host "[OK] Wazuh Hybrid USB Sync installed. Task: $($UsbSync.TaskName)"
        return 0
    } catch {
        Write-LogError "Install failed: $($_.Exception.Message)"
        return 2
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    exit (Install-UsbSync)
}

Export-ModuleMember -Function 'Install-UsbSync'

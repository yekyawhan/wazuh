# install_usb_sync_windows.ps1 — Installer
# Idempotent. Copies files, registers Scheduled Task, first sync, health check.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppRoot    = Split-Path -Parent $ScriptRoot
. (Join-Path $AppRoot 'config\config.ps1')

Import-Module (Join-Path $AppRoot 'modules\Logger.psm1')   -Force
Import-Module (Join-Path $AppRoot 'modules\Utils.psm1')    -Force

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
        $action = New-ScheduledTaskAction `
            -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$AppRoot\hybrid_sync_usb_v2.ps1`" --watch" `
            -WorkingDirectory $AppRoot
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
            -StartWhenAvailable
        Register-ScheduledTask -TaskName $UsbSync.TaskName `
            -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
            -Description $UsbSync.TaskDescription -Force | Out-Null
        Write-LogInfo "Scheduled task registered: $($UsbSync.TaskName)"

        # 3. First sync
        Write-LogInfo 'Running first synchronization...'
        & (Join-Path $AppRoot 'hybrid_sync_usb_v2.ps1')

        # 4. Health check
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

#Requires -RunAsAdministrator
<#
  install-usb-v3.ps1 - one-shot per-agent setup for STORAGE-ONLY USB control.

  What it does:
    1. removes the old/broken v2 install (scheduled task, watcher, ProgramData\Wazuh)
    2. repairs devices the v2 script wrongly disabled (camera, Bluetooth, ...)
    3. installs hybrid_sync_usb.ps1 (v3) to C:\ProgramData\WazuhUsbSync
    4. registers TWO scheduled tasks (run as SYSTEM):
         "Wazuh USB Sync v3"        - at startup + every 5 minutes
         "Wazuh USB Sync v3 OnPlug" - fires the moment ANY device is plugged in
                                      (Kernel-PnP event) -> near-realtime enforcement
    5. runs the first sync now and prints verification

  Centralization: the whitelist stays on the MANAGER (shared usb_whitelist.txt).
  If the manager also pushes hybrid_sync_usb.ps1 into the shared folder, the
  local copy self-updates from it on every sync - no GitHub, no reinstall.
  NOTE: no wazuh remote_commands flag is needed - Task Scheduler runs the sync,
  not the Wazuh agent, so that security flag can stay OFF.

  Run:  powershell -ExecutionPolicy Bypass -File .\install-usb-v3.ps1
#>
$ErrorActionPreference = 'Continue'
Write-Host "=== USB storage-only control - v3 install ===" -ForegroundColor Cyan

# resolve source next to this script (guard: empty when pasted into a console)
$srcDir = $PSScriptRoot
if (-not $srcDir) { $srcDir = "C:\Users\AGB\Desktop\usb-fix-v2" }
$src = Join-Path $srcDir "hybrid_sync_usb.ps1"
if (-not (Test-Path $src)) { Write-Host "ERROR: $src not found" -ForegroundColor Red; exit 1 }

$dstDir = "C:\ProgramData\WazuhUsbSync"
$dst = "$dstDir\hybrid_sync_usb.ps1"

# [1] remove old v2/v1 leftovers ---------------------------------------------
foreach ($tn in @('Wazuh Hybrid USB Sync', 'Wazuh USB Sync v3', 'Wazuh USB Sync v3 OnPlug')) {
    if (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "[1] removed scheduled task '$tn'"
    }
}
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'Start-UsbWatcher|hybrid_sync_usb_v2' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host "[1] killed watcher process $($_.ProcessId)" }
# v2 package install (only if it really is the v2 layout - be surgical)
if (Test-Path "C:\ProgramData\Wazuh\hybrid_sync_usb_v2.ps1") {
    Remove-Item "C:\ProgramData\Wazuh" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "[1] removed v2 package install C:\ProgramData\Wazuh"
}

# [2] repair devices v2 wrongly disabled (Code 22 on NON-storage USB) --------
Get-CimInstance Win32_PnPEntity -Filter "ConfigManagerErrorCode = 22" -ErrorAction SilentlyContinue |
    Where-Object { $_.PNPDeviceID -like 'USB\VID_*' } |
    ForEach-Object {
        $isStorage = ($_.Service -eq 'USBSTOR')
        foreach ($c in @($_.CompatibleID)) { if ($c -and $c -match '^USB\\Class_08') { $isStorage = $true } }
        if (-not $isStorage) {
            Enable-PnpDevice -InstanceId $_.PNPDeviceID -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "[2] re-enabled wrongly-disabled device: $($_.Name)" -ForegroundColor Green
        }
    }

# [3] install v3 sync script --------------------------------------------------
if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
Copy-Item -Path $src -Destination $dst -Force
Write-Host "[3] installed $dst"

# [4] scheduled tasks (SYSTEM) ------------------------------------------------
$runCmd = "-NoProfile -ExecutionPolicy Bypass -File $dst"
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $runCmd
$trgBoot   = New-ScheduledTaskTrigger -AtStartup
$trgRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
             -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
             -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName 'Wazuh USB Sync v3' -Action $action -Trigger $trgBoot, $trgRepeat `
    -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "[4] registered task 'Wazuh USB Sync v3' (startup + every 5 min)"

# on-plug trigger: Kernel-PnP configuration events = device arrival/install.
# schtasks (not Register-ScheduledTask) because only it exposes ONEVENT simply.
$xpath = "*[System[Provider[@Name='Microsoft-Windows-Kernel-PnP'] and (EventID=400 or EventID=410 or EventID=411 or EventID=430)]]"
& schtasks.exe /Create /F /TN "Wazuh USB Sync v3 OnPlug" /RU "SYSTEM" /RL HIGHEST /SC ONEVENT `
    /EC "Microsoft-Windows-Kernel-PnP/Configuration" /MO $xpath `
    /TR "powershell.exe $runCmd" | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "[4] registered task 'Wazuh USB Sync v3 OnPlug' (device-plug event -> instant sync)"
} else {
    Write-Host "[4] WARNING: on-plug task failed to register (5-min sync still active)" -ForegroundColor Yellow
}

# [5] first sync + verification ----------------------------------------------
Write-Host "[5] running first sync..." -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dst

Write-Host ""
Write-Host "=== verification ===" -ForegroundColor Cyan
$reg = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions"
Write-Host "--- policy root (expect AllowDenyLayered=1 DenyDeviceIDs=1 DenyDeviceIDsRetroactive=1 AllowInstanceIDs=1, NO DenyUnspecified) ---"
Get-ItemProperty $reg -ErrorAction SilentlyContinue | Select-Object AllowDenyLayered, DenyDeviceIDs, DenyDeviceIDsRetroactive, AllowInstanceIDs, DenyUnspecified | Format-List
Write-Host "--- deny list (expect only USB\Class_08) ---"
(Get-Item "$reg\DenyDeviceIDs" -ErrorAction SilentlyContinue).Property | ForEach-Object {
    "  $_ = $((Get-ItemProperty "$reg\DenyDeviceIDs").$_)"
}
Write-Host "--- allowed instance paths (your whitelisted drives' serials) ---"
(Get-Item "$reg\AllowInstanceIDs" -ErrorAction SilentlyContinue).Property | ForEach-Object {
    "  $_ = $((Get-ItemProperty "$reg\AllowInstanceIDs").$_)"
}
Write-Host "--- devices still in error state (expect NONE except blocked non-whitelisted sticks) ---"
Get-CimInstance Win32_PnPEntity -Filter "ConfigManagerErrorCode <> 0" | Select-Object Name, ConfigManagerErrorCode, PNPDeviceID | Format-Table -AutoSize

Write-Host "DONE. Storage-only USB control is active." -ForegroundColor Green
Write-Host "Camera/keyboard/mouse/Bluetooth/hubs are OUTSIDE this policy now."

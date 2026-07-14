#Requires -RunAsAdministrator
# uninstall-usb-control.ps1
# Removes EVERYTHING the USB device-control testing put on this agent and returns
# Windows to its default state (all USB allowed). Run in an Administrator PowerShell.

$ErrorActionPreference = 'Continue'
Write-Host "=== USB device-control cleanup ===" -ForegroundColor Cyan

# 1. delete the whole Device Installation Restrictions key
#    (removes DenyUnspecified, AllowDeviceIDs, AllowDeviceClasses + all their subkeys)
$reg = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions"
if (Test-Path $reg) {
    Remove-Item -Path $reg -Recurse -Force
    Write-Host "[1] removed policy key: $reg" -ForegroundColor Green
} else {
    Write-Host "[1] policy key already gone"
}
& gpupdate /force | Out-Null
Write-Host "    gpupdate applied - Windows is back to default (all USB allowed)"

# 2. remove the deployed sync script + the synced whitelist file + v3 workdir
foreach ($p in @(
    "C:\Program Files (x86)\ossec-agent\active-response\bin\hybrid_sync_usb.ps1",
    "C:\Program Files (x86)\ossec-agent\shared\usb_whitelist.txt",
    "C:\ProgramData\WazuhUsbSync"
)) {
    if (Test-Path $p) { Remove-Item $p -Recurse -Force; Write-Host "[2] removed $p" -ForegroundColor Green }
}
# v2 package install (only if it really is the v2 layout)
if (Test-Path "C:\ProgramData\Wazuh\hybrid_sync_usb_v2.ps1") {
    Get-CimInstance Win32_Process -EA SilentlyContinue |
        Where-Object { $_.CommandLine -match 'Start-UsbWatcher|hybrid_sync_usb_v2' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
    Remove-Item "C:\ProgramData\Wazuh" -Recurse -Force -EA SilentlyContinue
    Write-Host "[2] removed v2 package install C:\ProgramData\Wazuh" -ForegroundColor Green
}

# 3. strip the remote_commands flag(s) we added to local_internal_options.conf
$lio = "C:\Program Files (x86)\ossec-agent\local_internal_options.conf"
if (Test-Path $lio) {
    $kept = Get-Content $lio | Where-Object { $_ -notmatch 'remote_commands\s*=\s*1' }
    Set-Content -Path $lio -Value $kept -Encoding ascii
    Write-Host "[3] removed remote_commands flag from local_internal_options.conf" -ForegroundColor Green
}

# 4. remove any USB scheduled task (only present if yekyawhan's v2 was ever installed)
Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'USB' } | ForEach-Object {
    Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "[4] removed scheduled task '$($_.TaskName)'" -ForegroundColor Green
}

# 5. re-scan USB storage so any drive that was blocked/cached installs normally
#    now, and re-enable anything that was left DISABLED (Code 22)
$targets = Get-PnpDevice -PresentOnly -EA SilentlyContinue | Where-Object {
    $_.InstanceId -like 'USBSTOR\*' -or ($_.Class -eq 'USB' -and $_.FriendlyName -match 'Mass Storage')
}
foreach ($t in $targets) { & pnputil /remove-device "$($t.InstanceId)" 2>&1 | Out-Null }
& pnputil /scan-devices 2>&1 | Out-Null
Get-CimInstance Win32_PnPEntity -Filter "ConfigManagerErrorCode = 22" -EA SilentlyContinue |
    Where-Object { $_.PNPDeviceID -like 'USB\VID_*' } |
    ForEach-Object {
        Enable-PnpDevice -InstanceId $_.PNPDeviceID -Confirm:$false -EA SilentlyContinue
        Write-Host "[5] re-enabled disabled device: $($_.Name)" -ForegroundColor Green
    }
Write-Host "[5] re-scanned USB - previously-blocked drives will install normally now"

# 6. restart the agent so the removed flag takes effect
Restart-Service WazuhSvc -Force -EA SilentlyContinue
Write-Host "[6] WazuhSvc restarted"

Write-Host "`nDONE - USB control fully removed from this agent. It's a clean slate." -ForegroundColor Green
Write-Host "Verify: Get-Item '$reg'  should say 'Cannot find path' (key gone)."

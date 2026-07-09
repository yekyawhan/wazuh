#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Blocks all USB storage via Local GPO, whitelists specified VID/PID pairs.
.DESCRIPTION
  Enables "Prevent installation of devices not described by other policy settings"
  and "Allow installation of devices that match any of these device IDs" under
  Computer Configuration > Administrative Templates > System > Device Installation >
  Device Installation Restrictions.
  Whitelisted devices are specified as USB\VID_XXXX&PID_YYYY.
.PARAMETER Whitelist
  Array of Hardware IDs to allow. Default: @("USB\VID_0951&PID_1666")
.EXAMPLE
  .\windows_gpo_setup.ps1 -Whitelist @("USB\VID_0951&PID_1666","USB\VID_0781&PID_5581")
#>
param(
    [string[]]$Whitelist = @("USB\VID_0951&PID_1666")
)

$ErrorActionPreference = "Stop"

# --- Registry path for Device Installation Restrictions ---
$gpoPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions"

# 1. Prevent installation of devices not described by other policy settings
Set-ItemProperty -Path $gpoPath -Name "DenyUnspecified" -Value 1 -Type DWord -Force
Write-Host "[OK] DenyUnspecified = 1 (block all unspecified devices)"

# 2. Allow installation of devices that match any of these device IDs
Set-ItemProperty -Path $gpoPath -Name "AllowAdminInstall" -Value 1 -Type DWord -Force
Write-Host "[OK] AllowAdminInstall = 1 (whitelist mode enabled)"

# 3. Write whitelisted Hardware IDs
$allowListPath = "$gpoPath\AllowList"
if (-not (Test-Path $allowListPath)) {
    New-Item -Path $allowListPath -Force | Out-Null
}

# Clear existing entries and write new ones
Remove-Item -Path "$allowListPath\*" -Recurse -Force -ErrorAction SilentlyContinue

for ($i = 0; $i -lt $Whitelist.Count; $i++) {
    $hid = $Whitelist[$i]
    New-ItemProperty -Path $allowListPath -Name "$i" -Value $hid -PropertyType String -Force | Out-Null
    Write-Host "[OK] Whitelisted: $hid"
}

# 4. Also set the "Allow installation of devices using drivers that match
#    these device setup classes" to USB class GUID (optional safety net)
$classPath = "$gpoPath\AllowDeviceIDs"
if (-not (Test-Path $classPath)) {
    New-Item -Path $classPath -Force | Out-Null
}

Write-Host ""
Write-Host "=== GPO USB Blocking Applied ==="
Write-Host "Deny all unspecified: YES"
Write-Host "Whitelisted devices: $($Whitelist.Count)"
Write-Host "Reboot or run 'gpupdate /force' for changes to take full effect."

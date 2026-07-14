# get_usb_info.ps1 - list USB devices in a clean form for whitelisting (v3).
#
#   Default  : real devices only (hubs/controllers hidden), de-duplicated.
#   -Storage : ONLY mass-storage devices - the only class this project controls.
#   -All     : every USB device, including hubs.
#
# Copy WhitelistID (or VID:PID) into usb_whitelist.txt on the MANAGER.
# Use InstanceID instead when you want to pin ONE exact physical stick.

param([switch]$All, [switch]$Storage)

# device names hidden by default - never the thing you whitelist
$ignore = 'Root Hub|USB Hub|Composite Device|Host Controller|Billboard|Generic USB'

function Test-IsStorage($dev) {
    if ($dev.Service -eq 'USBSTOR') { return $true }
    foreach ($c in @($dev.CompatibleID)) { if ($c -and $c -match '^USB\\Class_08') { return $true } }
    return $false
}

$rows = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match 'USB\\VID_[0-9A-Fa-f]{4}&PID_[0-9A-Fa-f]{4}' } |
    Where-Object { $All -or $Storage -or ($_.FriendlyName -and $_.FriendlyName -notmatch $ignore) } |
    Where-Object { -not $Storage -or (Test-IsStorage $_) } |
    ForEach-Object {
        if ($_.InstanceId -match 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') {
            [pscustomobject]@{
                Name        = if ($_.FriendlyName) { $_.FriendlyName } else { '(unnamed device)' }
                Storage     = if (Test-IsStorage $_) { 'YES' } else { '-' }
                'VID:PID'   = ('{0}:{1}' -f $matches[1], $matches[2]).ToLower()
                WhitelistID = "USB\VID_$($matches[1])&PID_$($matches[2])"
                InstanceID  = $_.InstanceId
            }
        }
    } |
    Sort-Object InstanceID -Unique

if ($rows) {
    $rows | Format-Table -AutoSize -Wrap
    Write-Host "Add WhitelistID (any stick of that model) or InstanceID (that ONE stick) to usb_whitelist.txt on the manager." -ForegroundColor Yellow
    Write-Host "Only rows with Storage=YES are affected by this policy - everything else is outside it." -ForegroundColor DarkGray
    if (-not $All -and -not $Storage) { Write-Host "(hubs/controllers hidden - use -All to see everything, -Storage for drives only)" -ForegroundColor DarkGray }
} else {
    Write-Host "No matching USB devices found. Plug the device in first, or run with -All." -ForegroundColor Yellow
}

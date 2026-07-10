# get_usb_info.ps1 - list USB devices in a clean form for whitelisting.
#
#   Default : shows only real devices (hides hubs / controllers) and
#             de-duplicates, so you don't drown in entries.
#   -All    : show EVERY USB device, including hubs.
#
# Copy the value under WhitelistID (Windows format) OR VID:PID (Linux format)
# into usb_whitelist.txt on the manager.

param([switch]$All)

# device names we hide by default - they are never the thing you whitelist
$ignore = 'Root Hub|USB Hub|Composite Device|Host Controller|Billboard|Generic USB'

$rows = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match 'USB\\VID_[0-9A-Fa-f]{4}&PID_[0-9A-Fa-f]{4}' } |
    Where-Object { $All -or ($_.FriendlyName -and $_.FriendlyName -notmatch $ignore) } |
    ForEach-Object {
        if ($_.InstanceId -match 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') {
            [pscustomobject]@{
                Name        = if ($_.FriendlyName) { $_.FriendlyName } else { '(unnamed device)' }
                'VID:PID'   = ('{0}:{1}' -f $matches[1], $matches[2]).ToLower()
                WhitelistID = "USB\VID_$($matches[1])&PID_$($matches[2])"
            }
        }
    } |
    Sort-Object WhitelistID -Unique

if ($rows) {
    $rows | Format-Table -AutoSize
    Write-Host "Add the WhitelistID (or VID:PID) of the device you want to allow into usb_whitelist.txt." -ForegroundColor Yellow
    if (-not $All) { Write-Host "(hubs/controllers hidden - run with -All to see everything)" -ForegroundColor DarkGray }
} else {
    Write-Host "No matching USB devices found. Plug the device in first, or run with -All." -ForegroundColor Yellow
}

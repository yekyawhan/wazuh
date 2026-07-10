# hybrid_sync_usb.ps1
# Reads usb_whitelist.txt from Wazuh shared folder and applies to Windows GPO

$whitelistFile = "C:\Program Files (x86)\ossec-agent\shared\usb_whitelist.txt"
$logFile = "C:\Program Files (x86)\ossec-agent\active-response\active-responses.log"

function Write-Log($message) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - hybrid_sync_usb - $message"
    Write-Host $logMessage

    # Retry mechanism for file locking (Wazuh agent might be reading the log)
    $retryCount = 0
    $maxRetries = 3
    while ($retryCount -lt $maxRetries) {
        try {
            Add-Content -Path $logFile -Value $logMessage -ErrorAction Stop
            break
        } catch {
            $retryCount++
            Start-Sleep -Seconds 1
        }
    }
}

if (-not (Test-Path $whitelistFile)) {
    Write-Log "Error: Whitelist file not found in Wazuh shared folder."
    exit
}

# Read lines, ignore empty lines and comments (lines starting with #)
$allowedIds = Get-Content $whitelistFile | Where-Object { $_ -match "\S" -and $_ -notmatch "^#" }

$regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions"
# FIX: Windows reads the allow-list from the "AllowDeviceIDs" SUBKEY - NOT from
# "AllowInstallationOfMatchingDeviceIDs" (that string is the policy's display
# name, not a real registry key). Writing IDs to the wrong subkey left the
# whitelist empty, so even the approved device was blocked.
$allowPath = "$regPath\AllowDeviceIDs"

# Create base keys if missing
if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
if (-not (Test-Path $allowPath)) { New-Item -Path $allowPath -Force | Out-Null }

# Enable Device Installation Restrictions (Block All + turn the allow-list on)
Set-ItemProperty -Path $regPath -Name "DenyUnspecified" -Value 1 -Type DWord
Set-ItemProperty -Path $regPath -Name "AllowDeviceIDs" -Value 1 -Type DWord
Set-ItemProperty -Path $regPath -Name "AllowDeviceIDsRetroactive" -Value 1 -Type DWord

# Clear existing whitelist values
Get-Item -Path $allowPath | Select-Object -ExpandProperty Property | ForEach-Object {
    Remove-ItemProperty -Path $allowPath -Name $_ -Force
}

# Add new whitelist IDs from Centralized file (Windows expects 1-indexed REG_SZ)
$i = 1
$processedIds = @()
foreach ($id in $allowedIds) {
    $cleanId = $id.Trim()

    # Handle Linux format (0951:1666) -> Windows format (USB\VID_0951&PID_1666)
    if ($cleanId -match "^([0-9a-fA-F]{4}):([0-9a-fA-F]{4})$") {
        $cleanId = "USB\VID_$($matches[1])&PID_$($matches[2])"
    }

    Set-ItemProperty -Path $allowPath -Name $i.ToString() -Value $cleanId -Type String
    $processedIds += $cleanId
    $i++
}

# STORAGE-LAYER ENABLERS (required, or approved drives never MOUNT).
# A USB drive is a 3-node stack: USB device -> USBSTOR disk -> STORAGE volume,
# each gated separately by DenyUnspecified. Whitelisting only USB\VID&PID allows
# the USB node, but the disk + volume children stay blocked (Code 28) and no
# drive letter appears. These two generic IDs allow the disk + volume LAYERS.
# SAFE: an unauthorized drive is blocked at its USB\VID&PID parent, so its
# disk/volume children are never created - these only ever apply to a drive
# already allowed at the USB layer. (Class-based allows do NOT work here: a
# blocked node has no class yet, so only DEVICE-ID allows can match it.)
foreach ($storId in @("USBSTOR\GenDisk", "STORAGE\Volume")) {
    Set-ItemProperty -Path $allowPath -Name $i.ToString() -Value $storId -Type String
    $i++
}

gpupdate /force | Out-Null
Write-Log "Success: USB GPO updated from Wazuh Centralized Config. Authorized IDs: $($processedIds -join ', ')"

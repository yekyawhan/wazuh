# hybrid_sync_usb.ps1
# Reads usb_whitelist.txt from Wazuh shared folder and applies to Windows GPO

$whitelistFile = "C:\Program Files (x86)\ossec-agent\shared\usb_whitelist.txt"
$logFile = "C:\Program Files (x86)\ossec-agent\active-response\active-responses.log"

function Write-Log($message) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - hybrid_sync_usb - $message"
    Write-Host $logMessage
    Add-Content -Path $logFile -Value $logMessage
}

if (-not (Test-Path $whitelistFile)) {
    Write-Log "Error: Whitelist file not found in Wazuh shared folder."
    exit
}

# Read lines, ignore empty lines and comments (lines starting with #)
$allowedIds = Get-Content $whitelistFile | Where-Object { $_ -match "\S" -and $_ -notmatch "^#" }

$regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions"
$allowPath = "$regPath\AllowInstallationOfMatchingDeviceIDs"

# Create base keys if missing
if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
if (-not (Test-Path $allowPath)) { New-Item -Path $allowPath -Force | Out-Null }

# Enable Device Installation Restrictions (Block All)
Set-ItemProperty -Path $regPath -Name "DenyUnspecified" -Value 1 -Type DWord
Set-ItemProperty -Path $regPath -Name "AllowDeviceIDs" -Value 1 -Type DWord

# Clear existing whitelist values
Get-Item -Path $allowPath | Select-Object -ExpandProperty Property | ForEach-Object {
    Remove-ItemProperty -Path $allowPath -Name $_ -Force
}

# Add new whitelist IDs from Centralized file
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

gpupdate /force | Out-Null
Write-Log "Success: USB GPO updated from Wazuh Centralized Config. Authorized IDs: $($processedIds -join ', ')"

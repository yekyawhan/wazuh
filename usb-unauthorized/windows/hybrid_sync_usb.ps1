# hybrid_sync_usb.ps1  (v3 - STORAGE-ONLY USB device control)
#
# Reads usb_whitelist.txt from the Wazuh shared folder and enforces it with the
# Windows Device Installation Restrictions policy - scoped to USB MASS STORAGE
# devices ONLY. Keyboards, mice, cameras, Bluetooth, hubs, printers, phones are
# NEVER touched by this policy in any way (no DenyUnspecified, no class lists).
#
# DESIGN (v3 - replaces the old DenyUnspecified block-all design):
#   DENY  : DenyDeviceIDs = "USB\Class_08" (the USB mass-storage interface
#           class, matched via the device's COMPATIBLE IDs) with
#           DenyDeviceIDsRetroactive=1 so already-installed drives are also
#           yanked when policy applies - not just new installs.
#   ALLOW : AllowInstanceIDs = the full instance paths (VID&PID\SERIAL) of the
#           whitelisted drives. With AllowDenyLayered=1 Windows evaluates
#           Instance-ID allows ABOVE Device-ID denies, so the whitelist wins.
#           (A plain AllowDeviceIDs VID&PID allow can NOT win here: allow and
#           deny at the same Device-ID layer -> deny takes precedence.)
#   PURGE : every sync also deletes the cached devnodes of NON-whitelisted USB
#           storage (present AND absent). Windows only re-checks this policy at
#           INSTALL time, so a stick that was ever used before keeps its old
#           devnode and would sail straight through on replug - THE bug that
#           made the whitelist look ignored. With the devnode purged, every
#           plug of a non-whitelisted stick is a fresh install -> blocked.
#
# Whitelist line formats (one device per line, # = comment):
#   0781:556b                          Linux style VID:PID
#   USB\VID_0781&PID_556B              Windows hardware ID
#   USB\VID_0781&PID_556B\070B7C86...  full instance path = pin ONE exact stick
#
# Serial resolution: the policy needs full instance paths, but the whitelist
# holds VID:PID. Serials are resolved from every devnode Windows has ever seen
# for that VID:PID (present or not) and remembered in a local cache, so a
# whitelisted drive keeps working even while unplugged and across port moves.
#
# CENTRAL UPDATE: if the manager pushes a newer copy of this script to the
# shared folder, this run copies it over the local one; the new version runs
# from the next trigger. No GitHub, no reinstall.

$whitelistFile = "C:\Program Files (x86)\ossec-agent\shared\usb_whitelist.txt"
$logFile       = "C:\Program Files (x86)\ossec-agent\active-response\active-responses.log"
$workDir       = "C:\ProgramData\WazuhUsbSync"
$appLogFile    = "$workDir\log.txt"
$cacheFile     = "$workDir\instance_cache.txt"
$stateFile     = "$workDir\applied_state.txt"
$sharedSelf    = "C:\Program Files (x86)\ossec-agent\shared\hybrid_sync_usb.ps1"

function Write-Log($message) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - hybrid_sync_usb - $message"
    Write-Host $logMessage
    # Write to app-specific log (always accessible)
    $retryCount = 0
    while ($retryCount -lt 3) {
        try {
            Add-Content -Path $appLogFile -Value $logMessage -Encoding utf8 -ErrorAction Stop
            break
        }
        catch { $retryCount++; Start-Sleep -Seconds 1 }
    }
    # Fallback to Wazuh active-responses log (may fail under SYSTEM)
    try { Add-Content -Path $logFile -Value $logMessage -ErrorAction SilentlyContinue }
    catch { }
}

# ---- single-instance guard (5-min task + on-plug task can fire together) ----
$mutex = New-Object System.Threading.Mutex($false, 'Global\WazuhUsbSyncV3')
$gotMutex = $false
try { $gotMutex = $mutex.WaitOne(30000) } catch [System.Threading.AbandonedMutexException] { $gotMutex = $true }
if (-not $gotMutex) { Write-Log "another sync is still running after 30s - skipping this trigger"; exit 0 }

try {

if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir -Force | Out-Null }

# ---- central self-update from the manager-pushed shared copy ----
try {
    if ((Test-Path $sharedSelf) -and ($PSCommandPath) -and ($sharedSelf -ne $PSCommandPath)) {
        $newHash = (Get-FileHash -Path $sharedSelf -Algorithm SHA256).Hash
        $curHash = (Get-FileHash -Path $PSCommandPath -Algorithm SHA256).Hash
        if ($newHash -ne $curHash) {
            Copy-Item -Path $sharedSelf -Destination $PSCommandPath -Force
            Write-Log "self-updated from manager-pushed shared copy (takes effect next run)"
        }
    }
} catch { Write-Log "self-update check failed: $($_.Exception.Message)" }

# ---- read whitelist (FAIL-SECURE: missing file = allow nothing) ----
if (Test-Path $whitelistFile) {
    $rawLines = Get-Content $whitelistFile
} else {
    Write-Log "WARNING: whitelist file not found ($whitelistFile) - allowing NO storage device (fail-secure). Non-storage USB is unaffected."
    $rawLines = @()
}

$wantedPairs = @()      # "USB\VID_XXXX&PID_YYYY" (upper)
$directInstances = @()  # full instance paths given verbatim in the whitelist
foreach ($raw in $rawLines) {
    $line = ($raw -split '#')[0].Trim()
    if (-not $line) { continue }
    if ($line -match '^([0-9a-fA-F]{4}):([0-9a-fA-F]{4})$') {
        $wantedPairs += ("USB\VID_$($matches[1])&PID_$($matches[2])").ToUpper()
    } elseif ($line -match '^USB\\VID_[0-9a-fA-F]{4}&PID_[0-9a-fA-F]{4}$') {
        $wantedPairs += $line.ToUpper()
    } elseif ($line -match '^USB\\VID_([0-9a-fA-F]{4})&PID_([0-9a-fA-F]{4})(&MI_[0-9a-fA-F]{2})?\\.+') {
        $directInstances += $line.ToUpper()
        $wantedPairs += ("USB\VID_$($matches[1])&PID_$($matches[2])").ToUpper()
    } elseif ($line -match '^(USBSTOR\\GenDisk|STORAGE\\Volume)$') {
        # legacy v2 storage-layer entries - no longer needed, ignore quietly
    } else {
        Write-Log "ignored malformed whitelist line: $line"
    }
}
$wantedPairs = @($wantedPairs | Select-Object -Unique)

# ---- enumerate every USB devnode Windows knows (present AND absent) ----
$allUsbNodes = @(Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -like 'USB\VID_*' })
$presentIds = @{}
Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | ForEach-Object { $presentIds[$_.InstanceId.ToUpper()] = $true }

function Get-VidPidPair($instanceId) {
    if ($instanceId -match '^USB\\VID_([0-9a-fA-F]{4})&PID_([0-9a-fA-F]{4})') {
        return ("USB\VID_$($matches[1])&PID_$($matches[2])").ToUpper()
    }
    return $null
}
function Test-IsUsbStorageNode($dev) {
    # storage = driven by USBSTOR, or the mass-storage interface class (08) in
    # its compatible IDs. Both are stored in the registry, so this also works
    # for devices that are NOT currently plugged in.
    if ($dev.Service -eq 'USBSTOR') { return $true }
    foreach ($c in @($dev.CompatibleID)) {
        if ($c -and $c -match '^USB\\Class_08') { return $true }
    }
    return $false
}

# ---- resolve whitelist VID:PID -> full instance paths ----
$resolved = @()
foreach ($dev in $allUsbNodes) {
    $pair = Get-VidPidPair $dev.InstanceId
    if ($pair -and ($wantedPairs -contains $pair)) {
        $resolved += "$pair|$($dev.InstanceId.ToUpper())"
    }
}
# cache: keeps serials of whitelisted drives across unplugs / devnode purges;
# entries whose VID:PID is no longer whitelisted are dropped (= revocation)
$cached = @()
if (Test-Path $cacheFile) {
    $cached = @(Get-Content $cacheFile | Where-Object { $_ -match '^USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}\|USB\\' })
}
$union = @($cached + $resolved | Where-Object { $wantedPairs -contains ($_ -split '\|')[0] } | Select-Object -Unique)
Set-Content -Path $cacheFile -Value $union -Encoding ascii

$allowInstances = @(($union | ForEach-Object { ($_ -split '\|')[1] }) + $directInstances | Select-Object -Unique)

# ---- apply registry policy (elevation-guarded writes) ----
$regErrors = 0
function Set-RegSafe {
    param($Path, $Name, $Value, $Type)
    try { Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction Stop }
    catch { $script:regErrors++; Write-Log "REGISTRY WRITE FAILED: $Path\$Name = $Value ($($_.Exception.Message))" }
}
function Clear-RegValues($Path) {
    if (Test-Path $Path) {
        Get-Item -Path $Path | Select-Object -ExpandProperty Property | ForEach-Object {
            try { Remove-ItemProperty -Path $Path -Name $_ -Force -ErrorAction Stop }
            catch { $script:regErrors++; Write-Log "REGISTRY WRITE FAILED: could not clear $Path\$_" }
        }
    }
}

$regPath   = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions"
$denyPath  = "$regPath\DenyDeviceIDs"
$allowPath = "$regPath\AllowInstanceIDs"

$desiredState = (@($allowInstances | Sort-Object) + 'DENY=USB\Class_08;LAYERED') -join ';'
$lastState = if (Test-Path $stateFile) { Get-Content $stateFile -Raw -ErrorAction SilentlyContinue } else { '' }
$policyIntact = (Test-Path $allowPath) -and
    ((Get-ItemProperty -Path $regPath -Name DenyDeviceIDs -ErrorAction SilentlyContinue).DenyDeviceIDs -eq 1)

if (($lastState.Trim() -ne $desiredState) -or (-not $policyIntact)) {
    foreach ($p in @($regPath, $denyPath, $allowPath)) {
        if (-not (Test-Path $p)) { New-Item -Path $p -Force -ErrorAction SilentlyContinue | Out-Null }
        if (-not (Test-Path $p)) { $regErrors++; Write-Log "REGISTRY WRITE FAILED: could not create $p - not elevated / not SYSTEM?" }
    }

    # layered evaluation: Instance-ID allow outranks Device-ID deny
    Set-RegSafe $regPath "AllowDenyLayered" 1 "DWord"
    # deny ONLY the USB mass-storage interface class, incl. already-installed
    Set-RegSafe $regPath "DenyDeviceIDs" 1 "DWord"
    Set-RegSafe $regPath "DenyDeviceIDsRetroactive" 1 "DWord"
    Clear-RegValues $denyPath
    Set-RegSafe $denyPath "1" "USB\Class_08" "String"
    # allow the whitelisted drives by exact instance path
    Set-RegSafe $regPath "AllowInstanceIDs" 1 "DWord"
    Clear-RegValues $allowPath
    $i = 1
    foreach ($inst in $allowInstances) {
        Set-RegSafe $allowPath $i.ToString() $inst "String"
        $i++
    }

    # remove every artifact of the old block-all design (v1/v2): DenyUnspecified
    # blocked ALL new device types (hubs, phones, new keyboards...) and needed
    # storage-layer + class-exemption workarounds. None of that exists in v3.
    foreach ($legacyVal in @('DenyUnspecified','AllowDeviceIDs','AllowDeviceIDsEnabled','AllowDeviceIDsRetroactive','AllowDeviceClasses')) {
        Remove-ItemProperty -Path $regPath -Name $legacyVal -Force -ErrorAction SilentlyContinue
    }
    foreach ($legacyKey in @("$regPath\AllowDeviceIDs", "$regPath\AllowDeviceClasses")) {
        Remove-Item -Path $legacyKey -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($regErrors -eq 0) {
        gpupdate /target:computer /force | Out-Null
        Set-Content -Path $stateFile -Value $desiredState -Encoding ascii
        Write-Log "policy applied: deny USB\Class_08 (storage only, retroactive) + $($allowInstances.Count) instance allow(s), layered"
    }
}

# ---- reconcile plugged/cached devices with the new policy ----
# Windows enforces at INSTALL time only, so flip state ourselves:
#   PURGE - devnode of NON-whitelisted storage (present or absent) -> delete it.
#           Present drive unmounts NOW; any later plug is a fresh install -> blocked.
#   GRANT - a present but BLOCKED device that is now whitelisted -> delete its
#           blocked devnode + rescan = fresh install -> allowed -> mounts.
$purge = @()
foreach ($dev in $allUsbNodes) {
    $pair = Get-VidPidPair $dev.InstanceId
    if (-not $pair) { continue }
    if ($wantedPairs -contains $pair) {
        if ($presentIds[$dev.InstanceId.ToUpper()] -and $dev.Status -ne 'OK' -and ($allowInstances -contains $dev.InstanceId.ToUpper())) {
            $purge += $dev.InstanceId   # GRANT: re-trigger install, now allowed
        }
    } elseif (Test-IsUsbStorageNode $dev) {
        $purge += $dev.InstanceId       # PURGE: storage, not whitelisted
    }
}
$purge = @($purge | Select-Object -Unique)
$rescan = $false
foreach ($id in $purge) {
    & pnputil /remove-device "$id" 2>&1 | Out-Null
    if ($presentIds[$id.ToUpper()]) { $rescan = $true }
    Write-Log "re-triggered devnode: $id"
}
if ($rescan) { & pnputil /scan-devices 2>&1 | Out-Null }

if ($regErrors -gt 0) {
    Write-Log "FAILED: $regErrors registry write(s) denied - policy NOT applied. Run elevated / as SYSTEM."
} else {
    Write-Log "Success: $($wantedPairs.Count) whitelisted device(s), $($allowInstances.Count) instance allow(s), $($purge.Count) devnode(s) re-triggered. Storage-only enforcement active."
}

} finally {
    if ($gotMutex) { [void]$mutex.ReleaseMutex() }
    $mutex.Dispose()
}

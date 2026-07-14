# hybrid_sync_usb.ps1  (v3 - STORAGE-ONLY USB device control, self-installing)
#
# ONE file does everything. Run it once, elevated, from anywhere:
#
#     powershell -ExecutionPolicy Bypass -File .\hybrid_sync_usb.ps1
#
# It detects where it is running from and picks a mode automatically:
#   INSTALL MODE - when run from anywhere EXCEPT its install path. Removes any
#                  old v1/v2 install, repairs devices v2 wrongly disabled,
#                  copies itself to C:\ProgramData\WazuhUsbSync, registers the
#                  two scheduled tasks, runs the first sync, prints verification.
#   SYNC MODE    - when run FROM the install path (i.e. by the scheduled tasks,
#                  as SYSTEM). Applies the whitelist. No install side effects.
# So the same file is both the installer and the engine, and pushing it to the
# Wazuh manager's shared folder updates the engine fleet-wide (see CENTRAL
# UPDATE below). Re-running it is safe and idempotent.
#
# WHAT IT ENFORCES: the Windows Device Installation Restrictions policy, scoped
# to USB MASS STORAGE ONLY. Keyboards, mice, cameras, Bluetooth, hubs, printers
# and phones are NEVER touched by this policy in any way (no DenyUnspecified,
# no class lists) - they are structurally outside it.
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
#           Verified live: whitelisted stick mounts as a drive letter, and NO
#           storage-layer IDs are needed - once the deny is scoped to Class_08,
#           the USBSTOR disk / STORAGE volume children aren't denied by anything.
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
# shared folder, a sync-mode run copies it over the installed one; the new
# version runs from the next trigger. No GitHub, no reinstall.

$whitelistFile = "C:\Program Files (x86)\ossec-agent\shared\usb_whitelist.txt"
$logFile       = "C:\Program Files (x86)\ossec-agent\active-response\active-responses.log"
$workDir       = "C:\ProgramData\WazuhUsbSync"
$cacheFile     = "$workDir\instance_cache.txt"
$stateFile     = "$workDir\applied_state.txt"
$localLog      = "$workDir\usb-sync.log"
$installPath   = "$workDir\hybrid_sync_usb.ps1"
$sharedSelf    = "C:\Program Files (x86)\ossec-agent\shared\hybrid_sync_usb.ps1"
$taskSync      = "Wazuh USB Sync v3"
$taskPlug      = "Wazuh USB Sync v3 OnPlug"

# LOGGING GOTCHA (confirmed live: v3 ran at 14:29/14:31/15:02 and wrote ZERO
# lines - active-responses.log's LastWriteTime stayed at 13:13). The Wazuh agent
# holds that file open, and the old retry loop swallowed the failure silently,
# so every run looked successful while the entire audit trail was lost.
# Measured, NOT assumed: if the holder denies write-sharing, FileShare.ReadWrite
# on OUR side does not rescue the append either - it fails exactly like
# Add-Content. So the agent log can only ever be BEST-EFFORT here.
# The real fix is the workdir log below: nothing else holds it, so it always
# succeeds. Ship USB events to the manager by pointing a <localfile> at it
# (see agent.conf) rather than relying on active-responses.log.
function Write-Log($message) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - hybrid_sync_usb - $message"
    Write-Host $logMessage

    # own log first - must never fail
    try {
        if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir -Force | Out-Null }
        $fs = New-Object System.IO.FileStream($localLog, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $sw = New-Object System.IO.StreamWriter($fs)
        $sw.WriteLine($logMessage); $sw.Flush(); $sw.Close(); $fs.Close()
    } catch { }

    # Wazuh AR log (best-effort only - see note above)
    try {
        $fs = New-Object System.IO.FileStream($logFile, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $sw = New-Object System.IO.StreamWriter($fs)
        $sw.WriteLine($logMessage); $sw.Flush(); $sw.Close(); $fs.Close()
    } catch { }
}

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ============================================================================
# MODE DETECTION - installed copy runs the engine, any other copy installs it
# ============================================================================
$amInstalledCopy = $PSCommandPath -and ($PSCommandPath -ieq $installPath)

if (-not $amInstalledCopy) {

    # ======================= INSTALL MODE ===================================
    Write-Host "=== USB storage-only control v3 - install ===" -ForegroundColor Cyan
    if (-not (Test-IsAdmin)) {
        Write-Host "ERROR: must run as Administrator (right-click PowerShell -> Run as administrator)." -ForegroundColor Red
        exit 1
    }

    # [1] remove old v1/v2 leftovers ---------------------------------------
    foreach ($tn in @('Wazuh Hybrid USB Sync', $taskSync, $taskPlug)) {
        if (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "[1] removed scheduled task '$tn'"
        }
    }
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'Start-UsbWatcher|hybrid_sync_usb_v2' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host "[1] killed v2 watcher process $($_.ProcessId)" }
    # be surgical: only delete C:\ProgramData\Wazuh if it really is the v2 layout
    if (Test-Path "C:\ProgramData\Wazuh\hybrid_sync_usb_v2.ps1") {
        Remove-Item "C:\ProgramData\Wazuh" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "[1] removed v2 package install C:\ProgramData\Wazuh"
    }

    # [2] repair NON-storage devices v2 wrongly disabled (Code 22) ----------
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

    # [3] install self ------------------------------------------------------
    if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir -Force | Out-Null }
    Copy-Item -Path $PSCommandPath -Destination $installPath -Force
    Write-Host "[3] installed engine -> $installPath"

    # [4] scheduled tasks (SYSTEM) -----------------------------------------
    # WHY Task Scheduler and not a Wazuh <wodle name="command">:
    #   * a wodle needs wazuh_command.remote_commands=1 set LOCALLY on every
    #     agent (Wazuh refuses to let a manager enable remote execution), which
    #     defeats the point of a centrally-managed rollout;
    #   * a wodle can only POLL on a fixed interval, so it could never react to
    #     a device being plugged in. The ONEVENT task below can.
    $runArgs   = "-NoProfile -ExecutionPolicy Bypass -File `"$installPath`""
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $runArgs
    $trgBoot   = New-ScheduledTaskTrigger -AtStartup
    $trgRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
                 -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                 -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $taskSync -Action $action -Trigger $trgBoot, $trgRepeat `
        -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "[4] registered '$taskSync' (at startup + every 5 min)"

    # on-plug trigger: Kernel-PnP configuration events = device arrival/install.
    # schtasks (not Register-ScheduledTask) because only it exposes ONEVENT simply.
    $xpath = "*[System[Provider[@Name='Microsoft-Windows-Kernel-PnP'] and (EventID=400 or EventID=410 or EventID=411 or EventID=430)]]"
    & schtasks.exe /Create /F /TN "$taskPlug" /RU "SYSTEM" /RL HIGHEST /SC ONEVENT `
        /EC "Microsoft-Windows-Kernel-PnP/Configuration" /MO $xpath `
        /TR "powershell.exe $runArgs" | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[4] registered '$taskPlug' (device-plug event -> instant sync)"
    } else {
        Write-Host "[4] WARNING: on-plug task failed to register (5-min sync still active)" -ForegroundColor Yellow
    }

    # [5] first sync (runs the INSTALLED copy -> sync mode) ------------------
    Write-Host "[5] running first sync..." -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installPath

    # [6] verification ------------------------------------------------------
    Write-Host ""
    Write-Host "=== verification ===" -ForegroundColor Cyan
    $reg = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions"
    Write-Host "--- policy root (expect AllowDenyLayered/DenyDeviceIDs/DenyDeviceIDsRetroactive/AllowInstanceIDs = 1, DenyUnspecified EMPTY) ---"
    Get-ItemProperty $reg -ErrorAction SilentlyContinue |
        Select-Object AllowDenyLayered, DenyDeviceIDs, DenyDeviceIDsRetroactive, AllowInstanceIDs, DenyUnspecified | Format-List
    Write-Host "--- deny list (expect only USB\Class_08) ---"
    (Get-Item "$reg\DenyDeviceIDs" -ErrorAction SilentlyContinue).Property | ForEach-Object {
        "  $_ = $((Get-ItemProperty "$reg\DenyDeviceIDs").$_)"
    }
    Write-Host "--- allowed instance paths (your whitelisted drives' serials) ---"
    (Get-Item "$reg\AllowInstanceIDs" -ErrorAction SilentlyContinue).Property | ForEach-Object {
        "  $_ = $((Get-ItemProperty "$reg\AllowInstanceIDs").$_)"
    }
    Write-Host "--- scheduled tasks ---"
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -in @($taskSync, $taskPlug) } |
        Select-Object TaskName, State | Format-Table -AutoSize
    Write-Host "--- devices in error state (expect NONE except blocked non-whitelisted sticks) ---"
    Get-CimInstance Win32_PnPEntity -Filter "ConfigManagerErrorCode <> 0" |
        Select-Object Name, ConfigManagerErrorCode | Format-Table -AutoSize

    Write-Host "DONE. Storage-only USB control is active." -ForegroundColor Green
    Write-Host "Camera/keyboard/mouse/Bluetooth/hubs are OUTSIDE this policy."
    Write-Host "Log: $localLog"
    exit 0
}

# ============================================================================
# SYNC MODE - running as the installed copy (scheduled task, SYSTEM)
# ============================================================================

# ---- single-instance guard (5-min task + on-plug task can fire together) ----
$mutex = New-Object System.Threading.Mutex($false, 'Global\WazuhUsbSyncV3')
$gotMutex = $false
try { $gotMutex = $mutex.WaitOne(30000) } catch [System.Threading.AbandonedMutexException] { $gotMutex = $true }
if (-not $gotMutex) { Write-Log "another sync is still running after 30s - skipping this trigger"; exit 0 }

try {

if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir -Force | Out-Null }

# ---- central self-update from the manager-pushed shared copy ----
# Only ever runs in sync mode, so it can never overwrite the copy you launched
# the install from (e.g. the one on your Desktop).
try {
    if (Test-Path $sharedSelf) {
        $newHash = (Get-FileHash -Path $sharedSelf -Algorithm SHA256).Hash
        $curHash = (Get-FileHash -Path $installPath -Algorithm SHA256).Hash
        if ($newHash -ne $curHash) {
            Copy-Item -Path $sharedSelf -Destination $installPath -Force
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

# CONTAMINATION CHECK (learned the hard way): another USB-control tool (e.g. the
# old v1/v2 block-all design) can write its legacy values into the SAME policy
# key while our state file still matches. DenyUnspecified=1 then silently
# block-alls the machine again - cameras, Bluetooth, any new device - even
# though our own values are all present and "intact". So treat ANY legacy value
# as a reason to rewrite the whole policy, which also strips them.
$legacyValues = @('DenyUnspecified','AllowDeviceIDs','AllowDeviceIDsEnabled','AllowDeviceIDsRetroactive','AllowDeviceClasses')
$legacyFound = @()
foreach ($lv in $legacyValues) {
    if ($null -ne (Get-ItemProperty -Path $regPath -Name $lv -ErrorAction SilentlyContinue).$lv) { $legacyFound += $lv }
}
if ($legacyFound.Count -gt 0) {
    Write-Log "CONTAMINATION: foreign block-all value(s) found in the policy key [$($legacyFound -join ', ')] - another USB tool is fighting this one. Stripping them and reapplying storage-only policy."
}

$policyIntact = (Test-Path $allowPath) -and
    ((Get-ItemProperty -Path $regPath -Name DenyDeviceIDs -ErrorAction SilentlyContinue).DenyDeviceIDs -eq 1) -and
    ($legacyFound.Count -eq 0)

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
    foreach ($legacyVal in $legacyValues) {
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

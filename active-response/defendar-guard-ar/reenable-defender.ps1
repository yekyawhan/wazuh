# reenable-defender.ps1
# Wazuh custom Active Response + standalone launcher.
# Restore supported Microsoft Defender Antivirus protections on Windows 11
# 22H2/23H2/24H2/25H2, using only parameters available on the local OS.
#
# Restores where supported:
#   - Real-time protection
#   - Behavior monitoring, IOAV and script scanning
#   - Cloud-delivered protection (MAPS) and Block at First Sight
#   - Automatic safe-sample submission
#   - Dev Drive protection/performance mode, where exposed by the OS
#
# Tamper Protection is deliberately NOT bypassed. Windows may reject local
# changes while Tamper Protection is enabled; manage its state through
# Windows Security, Intune, or the Microsoft Defender portal. This script
# reports its status only.
#
# NOTE: Wazuh execd keeps stdin OPEN -> ReadLine(), never ReadToEnd().
# NOTE: custom AR is not auto-logged -> append our own log lines.

$ErrorActionPreference = 'SilentlyContinue'
$log = 'C:\Program Files (x86)\ossec-agent\active-response\active-responses.log'
$deadline = (Get-Date).AddSeconds(5)

function Write-Log {
    param([string]$Message)
    $line = '{0} reenable-defender: {1}' -f (Get-Date -Format 'yyyy/MM/dd HH:mm:ss'), $Message
    try {
        $fs = [System.IO.FileStream]::new($log, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $sw = [System.IO.StreamWriter]::new($fs)
        $sw.WriteLine($line)
        $sw.Flush()
        $sw.Close()
        $fs.Close()
    } catch { }
}

function Set-DefenderPreference {
    param(
        [string]$Name,
        [object]$Value,
        [hashtable]$SupportedParameters
    )
    if (-not $SupportedParameters.ContainsKey($Name)) {
        Write-Log "SKIP: Set-MpPreference parameter '$Name' is not available on this Windows/Defender version."
        return
    }
    try {
        $arg = @{}
        $arg[$Name] = $Value
        $arg['ErrorAction'] = 'Stop'
        Set-MpPreference @arg
        Write-Log "Requested $Name=$Value."
    } catch {
        Write-Log "FAILED $Name=$Value : $($_.Exception.Message)"
    }
}

function Get-DefenderStatus {
    try { return Get-MpComputerStatus -ErrorAction Stop } catch { return $null }
}

# Detect Wazuh AR (stdin JSON) vs standalone Scheduled Task/manual invocation.
$isAR = $false
$stdinLine = $null
try {
    if ([Console]::In -ne $null -and [Console]::In.Peek() -ge 0) {
        $isAR = $true
        $stdinLine = [Console]::In.ReadLine()
    }
} catch { }

$action = 'add'
if ($isAR) {
    Write-Log "Starting (AR). stdin=$stdinLine"
    try {
        $parsed = $stdinLine | ConvertFrom-Json -ErrorAction Stop
        if ($parsed.command) { $action = [string]$parsed.command }
    } catch { Write-Log 'Could not parse AR stdin as JSON; defaulting to add.' }
} else {
    Write-Log 'Starting (standalone).'
}

if ($action -ne 'add') {
    Write-Log "Action '$action' received; no-op."
    Write-Log 'Ended.'
    return
}

try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    Write-Log "OS: $($os.Caption); version=$($os.Version); build=$($os.BuildNumber)."
} catch { Write-Log 'Could not determine Windows version.' }

# Get supported Set-MpPreference parameters once; avoid binding errors across
# Defender platform/Windows builds.
$setMpCommand = Get-Command Set-MpPreference -ErrorAction SilentlyContinue
$supported = @{}
if ($setMpCommand) {
    foreach ($key in $setMpCommand.Parameters.Keys) { $supported[$key] = $true }
} else {
    Write-Log 'ERROR: Set-MpPreference cmdlet is unavailable.'
}

# Ensure the service is available. Service start may be blocked by policy or
# Tamper Protection; failures are logged and the script continues.
try {
    $svc = Get-Service -Name WinDefend -ErrorAction Stop
    if ($svc.Status -ne 'Running') {
        Write-Log "WinDefend status is $($svc.Status); attempting start."
        try { Set-Service -Name WinDefend -StartupType Automatic -ErrorAction Stop } catch {
            Write-Log "Could not set WinDefend startup type: $($_.Exception.Message)"
        }
        try { Start-Service -Name WinDefend -ErrorAction Stop } catch {
            Write-Log "Could not start WinDefend: $($_.Exception.Message)"
        }
    }
} catch { Write-Log "WinDefend service query failed: $($_.Exception.Message)" }

# Restore independent settings so one unsupported/blocked setting does not
# prevent attempts to restore the others.
Set-DefenderPreference -Name 'DisableRealtimeMonitoring' -Value $false -SupportedParameters $supported
Set-DefenderPreference -Name 'DisableBehaviorMonitoring' -Value $false -SupportedParameters $supported
Set-DefenderPreference -Name 'DisableIOAVProtection' -Value $false -SupportedParameters $supported
Set-DefenderPreference -Name 'DisableScriptScanning' -Value $false -SupportedParameters $supported

# Cloud-delivered protection: MAPS Advanced + Block at First Sight enabled.
# Values follow the Defender Set-MpPreference enum: Advanced=2.
Set-DefenderPreference -Name 'MAPSReporting' -Value 2 -SupportedParameters $supported
Set-DefenderPreference -Name 'DisableBlockAtFirstSeen' -Value $false -SupportedParameters $supported

# Submit safe samples automatically. Consent enum: SendSafeSamples=3.
Set-DefenderPreference -Name 'SubmitSamplesConsent' -Value 3 -SupportedParameters $supported

# Dev Drive protection is exposed as PerformanceModeStatus only on supported
# Defender/Windows builds. Do not assume the parameter exists on older builds.
Set-DefenderPreference -Name 'PerformanceModeStatus' -Value 'Enabled' -SupportedParameters $supported

# ---------------------------------------------------------------------------
# Tamper Protection auto-enable (best-effort, Layer-0).
# Implementation lives in enable-tamper-protection.ps1 (shared with the manual
# audit script). See that file for the registry/ACL details and the
# policy-managed failure modes.
# ---------------------------------------------------------------------------
$tpStatus = Get-DefenderStatus
$tpAlreadyOn = $false
if ($tpStatus -and $tpStatus.PSObject.Properties.Name -contains 'IsTamperProtected') {
    $tpAlreadyOn = [bool]$tpStatus.IsTamperProtected
}
if ($tpAlreadyOn) {
    Write-Log 'TAMPER: IsTamperProtected=True. No action needed.'
} else {
    # On 26H1 the only way to flip Tamper Protection is the Windows Security UI,
    # and that UI only accepts input from a process in the interactive session.
    # This script runs as SYSTEM in session 0, so it relaunches the helper
    # inside the signed-in session and waits for the result.
    $tpHelper = Join-Path $PSScriptRoot 'enable-tamper-protection.ps1'
    if (Test-Path $tpHelper) {
        . $tpHelper
        if ((Get-Process -Id $PID).SessionId -eq 0) {
            [void](Start-DefenderGuardTamperInSession)
        } else {
            [void](Enable-TamperProtectionBestEffort)
        }
    } else {
        Write-Log "TAMPER: helper not found at $tpHelper; cannot enable automatically."
    }
}

# Bounded verification/retry. Do not return early merely because RTP is on:
# cloud/sample/Dev Drive settings and Tamper Protection status must be reported.
$attempt = 0
$status = Get-DefenderStatus
while ((-not $status -or -not $status.RealTimeProtectionEnabled) -and (Get-Date) -lt $deadline) {
    $attempt++
    Start-Sleep -Milliseconds 400
    $status = Get-DefenderStatus
    if ($attempt -eq 2 -and (-not $status -or -not $status.RealTimeProtectionEnabled)) {
        Write-Log 'RTP still disabled after retries; attempting one WinDefend restart.'
        try { Restart-Service -Name WinDefend -Force -ErrorAction Stop } catch {
            Write-Log "WinDefend restart failed (policy/Tamper Protection may block it): $($_.Exception.Message)"
        }
        # Re-issue only core protection preferences after the restart.
        Set-DefenderPreference -Name 'DisableRealtimeMonitoring' -Value $false -SupportedParameters $supported
        Set-DefenderPreference -Name 'DisableBehaviorMonitoring' -Value $false -SupportedParameters $supported
        Set-DefenderPreference -Name 'DisableIOAVProtection' -Value $false -SupportedParameters $supported
        Set-DefenderPreference -Name 'DisableScriptScanning' -Value $false -SupportedParameters $supported
    }
}

$status = Get-DefenderStatus
if ($status) {
    Write-Log "VERIFY: RealTimeProtectionEnabled=$($status.RealTimeProtectionEnabled); BehaviorMonitorEnabled=$($status.BehaviorMonitorEnabled); IoavProtectionEnabled=$($status.IoavProtectionEnabled); AntivirusEnabled=$($status.AntivirusEnabled)."
    if ($status.PSObject.Properties.Name -contains 'IsTamperProtected') {
        Write-Log "STATUS: IsTamperProtected=$($status.IsTamperProtected). Tamper Protection is status-only; use supported central/local Windows Security management to change it."
    } else {
        Write-Log 'STATUS: IsTamperProtected property is unavailable in this Defender platform version.'
    }
} else {
    Write-Log 'VERIFY: Get-MpComputerStatus unavailable or failed.'
}

try {
    $pref = Get-MpPreference -ErrorAction Stop
    if ($pref.PSObject.Properties.Name -contains 'MAPSReporting') {
        Write-Log "VERIFY: MAPSReporting=$($pref.MAPSReporting) (2=Advanced/cloud-delivered protection)."
    }
    if ($pref.PSObject.Properties.Name -contains 'SubmitSamplesConsent') {
        Write-Log "VERIFY: SubmitSamplesConsent=$($pref.SubmitSamplesConsent) (3=SendSafeSamples)."
    }
    if ($pref.PSObject.Properties.Name -contains 'DisableBlockAtFirstSeen') {
        Write-Log "VERIFY: DisableBlockAtFirstSeen=$($pref.DisableBlockAtFirstSeen) (False=enabled)."
    }
    if ($pref.PSObject.Properties.Name -contains 'PerformanceModeStatus') {
        Write-Log "VERIFY: PerformanceModeStatus=$($pref.PerformanceModeStatus)."
    } else {
        Write-Log 'VERIFY: PerformanceModeStatus is not exposed by Get-MpPreference on this platform; Dev Drive protection cannot be verified by this property.'
    }
} catch { Write-Log "Get-MpPreference verification failed: $($_.Exception.Message)" }

Write-Log 'Completed. Settings blocked by Tamper Protection or organizational policy require remediation through the supported management channel.'
Write-Log 'Ended.'

# watchdog-service.ps1 - Layer-1 defender: keep WinDefend alive and force
# ALL FIVE protections back on the moment any of them flips OFF.
#
# Guarded settings and their "ON" values:
#   1. Real-time protection      RealTimeProtectionEnabled      = True
#   2. Behavior/IOAV/script      Disable*Monitoring/IOAV/Script = False
#   3. Cloud-delivered (MAPS)    MAPSReporting                  = 2  (Advanced)
#   4. Automatic sample submit   SubmitSamplesConsent           = 3  (SendSafeSamples)
#   5. Dev Drive protection      PerformanceModeStatus          = 1  (Enabled)
#   + Tamper Protection          IsTamperProtected              = True (UI-only, see helper)
#
# Why this layer exists:
#   Event 5001 lags 100ms-1s behind the actual flip, so the event watcher alone
#   misses the first disable. This poll reacts in ~1s with no manager round-trip.
#
# Resource use: ~20 MB RAM, ~0.01% CPU, zero disk IO at idle. See README.
# Run as SYSTEM via Scheduled Task (AtStartup, RunAs=SYSTEM, highest).
#
# NOTE: the scheduled task MUST use <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
# or Task Scheduler kills this loop (verified: PT2M -> LastTaskResult 267014).

$ErrorActionPreference = "SilentlyContinue"
$log = "C:\Program Files (x86)\ossec-agent\active-response\active-responses.log"
$pollSeconds = 1   # safe on Windows; 3 is fine for laptops if you want less CPU
$tpHelper = Join-Path $PSScriptRoot 'enable-tamper-protection.ps1'

function Write-Log($msg) {
    $line = "{0} watchdog-service: {1}" -f (Get-Date -Format "yyyy/MM/dd HH:mm:ss"), $msg
    try {
        $fs = [System.IO.FileStream]::new($log, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $sw = [System.IO.StreamWriter]::new($fs)
        $sw.WriteLine($line); $sw.Flush(); $sw.Close(); $fs.Close()
    } catch { }
}

Write-Log "Starting (poll=${pollSeconds}s, PID=$PID)."

# Enforce Automatic startup once (idempotent, no-op if already set)
try { Set-Service -Name WinDefend -StartupType Automatic } catch {}

# Restore every guardable preference once at startup. Blocked writes are fine;
# the poll below retries them each cycle.
function Restore-All {
    Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction SilentlyContinue
    Set-MpPreference -DisableBehaviorMonitoring  $false -ErrorAction SilentlyContinue
    Set-MpPreference -DisableIOAVProtection       $false -ErrorAction SilentlyContinue
    Set-MpPreference -DisableScriptScanning       $false -ErrorAction SilentlyContinue
    Set-MpPreference -MAPSReporting               2     -ErrorAction SilentlyContinue
    Set-MpPreference -DisableBlockAtFirstSeen     $false -ErrorAction SilentlyContinue
    Set-MpPreference -SubmitSamplesConsent        3     -ErrorAction SilentlyContinue
    Set-MpPreference -PerformanceModeStatus       Enabled -ErrorAction SilentlyContinue
}
Restore-All

$lastPrefLog = New-TimeSpan -Seconds 60
$lastTpLog   = New-TimeSpan -Seconds 600   # first TP attempt fires immediately

while ($true) {
    $now = [DateTime]::Now

    # 1. Service liveness: if WinDefend stopped, restart it.
    $svc = Get-Service -Name WinDefend -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        # service may not exist on Server Core; skip quietly
    } elseif ($svc.Status -ne 'Running') {
        Write-Log "WinDefend status=$($svc.Status), restarting."
        try { Set-Service -Name WinDefend -StartupType Automatic } catch {}
        try { Start-Service -Name WinDefend -ErrorAction Stop } catch {}
    }

    # 2. Preference drift detection across ALL five protections.
    try {
        $status = Get-MpComputerStatus -ErrorAction Stop
        $pref   = Get-MpPreference     -ErrorAction Stop
        $wrong  = @()

        if (-not $status.RealTimeProtectionEnabled)                    { $wrong += 'RTP' }
        if (-not $status.BehaviorMonitorEnabled)                       { $wrong += 'BehaviorMonitor' }
        if (-not $status.IoavProtectionEnabled)                        { $wrong += 'IOAV' }
        if ($pref.PSObject.Properties.Name -contains 'MAPSReporting' -and $pref.MAPSReporting -ne 2) {
            $wrong += "MAPS=$($pref.MAPSReporting)"
        }
        if ($pref.PSObject.Properties.Name -contains 'SubmitSamplesConsent' -and $pref.SubmitSamplesConsent -ne 3) {
            $wrong += "Samples=$($pref.SubmitSamplesConsent)"
        }
        if ($pref.PSObject.Properties.Name -contains 'PerformanceModeStatus' -and $pref.PerformanceModeStatus -ne 1) {
            $wrong += "DevDrive=$($pref.PerformanceModeStatus)"
        }
        if ($pref.PSObject.Properties.Name -contains 'DisableBlockAtFirstSeen' -and $pref.DisableBlockAtFirstSeen) {
            $wrong += 'BlockAtFirstSeen'
        }

        if ($wrong.Count -gt 0) {
            Restore-All
            if (($now - $lastPrefLog).TotalSeconds -ge 15) {
                Write-Log ("DRIFT [" + ($wrong -join ', ') + "] -> re-issued all five preferences.")
                $lastPrefLog = $now
            }
        }

        # 3. Tamper Protection: the only setting that needs the interactive
        #    session. Only act when it is actually OFF, and rate-limit it so a
        #    permanently blocked host does not spawn a task every second.
        if ($status.PSObject.Properties.Name -contains 'IsTamperProtected' -and
            -not $status.IsTamperProtected -and
            (Test-Path $tpHelper) -and
            (($now - $lastTpLog).TotalSeconds -ge 300)) {
            $lastTpLog = $now
            Write-Log 'Tamper Protection is OFF -> attempting in-session enable.'
            try {
                . $tpHelper
                if ((Get-Process -Id $PID).SessionId -eq 0) {
                    [void](Start-DefenderGuardTamperInSession)
                } else {
                    [void](Enable-TamperProtectionBestEffort)
                }
            } catch { Write-Log "Tamper enable failed: $($_.Exception.Message)" }
        }
    } catch {
        # Get-MpComputerStatus can fail briefly during service startup; ignore
    }

    Start-Sleep -Seconds $pollSeconds
}
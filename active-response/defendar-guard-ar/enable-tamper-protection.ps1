# enable-tamper-protection.ps1
# Layer-0 helper: turn Microsoft Defender Tamper Protection ON.
#
# Shared by:
#   reenable-defender.ps1         (Wazuh AR + event/service watchers)
#   enforce-tamper-protection.ps1 (manual audit script)
#   install.ps1                   (deploy + audit during install)
#
# ---------------------------------------------------------------------------
# WHY THE REGISTRY / WMI / GPO PATHS DO NOT WORK (measured on 26H1, build 26200)
# ---------------------------------------------------------------------------
# Tamper Protection is a WdFilter.sys minifilter that gates on the CALLER TOKEN,
# not on the value written. The only caller it whitelists for Defender-control
# RPC is the Windows Security app package:
#
#     S-1-15-3-1024-3153509613-960666767-3724611135-2725662640-12138253-543910227-1950414635-4190290187
#     (Microsoft.SecHealthUI_8wekyb3d8bbwe)
#
# Measured results for every non-UI channel (all as elevated admin AND as SYSTEM):
#   HKLM\...\Windows Defender\Features\TamperProtection = 5
#       -> "Requested registry access is not allowed." / "unauthorized operation".
#          Taking ownership fails too: NtSetSecurityObject is vetoed by WdFilter.
#   reg.exe add ... /f            -> ERROR: Access is denied.
#   Set-MpPreference -DisableTamperProtection $false
#       -> 0x80004001 (E_NOTIMPL), by design: the parameter is reserved.
#   Invoke-CimMethod on MSFT_MpPreference -> same 0x80004001.
#   HKLM\SOFTWARE\Policies\...\Windows Defender\TamperProtection = 4 or 5
#       -> write succeeds, value persists, Defender IGNORES it at evaluation.
#          gpupdate /force does not help. Measured: still Source=UI, reg=4.
#   GPO "Turn on Tamper Protection" ADMX is not even present on this SKU
#       (C:\Windows\PolicyDefinitions\WindowsDefender.admx is absent).
#   Running inside the SecHealthUI package via Invoke-CommandInDesktopPackage
#       -> the child token carries NO package SID (app-package SIDs on token: 0),
#          so the RPC allow-list still rejects it.
#
# THE PATH THAT WORKS (verified end-to-end on build 26200):
#   Windows Security -> Virus & threat protection -> Manage settings ->
#   Tamper Protection toggle, driven by UIAutomation from a process running in
#   the interactive user session. The toggle click is executed BY the
#   SecHealthUI app, whose token IS on the allow-list.
#
# Measured outcome of that path:
#   toggle state Off -> On, IsTamperProtected False -> True,
#   Features\TamperProtection 4 -> 5, TamperProtectionSource=UI,
#   and Set-MpPreference -DisableRealtimeMonitoring $true is then silently
#   overridden (RTP stays True) == tamper is genuinely enforcing.
#
# This is why the helper must be launched INTO the interactive session: a
# process started from the Wazuh agent / SYSTEM context lives in session 0 and
# cannot see or drive the Windows Security window at all.
# ---------------------------------------------------------------------------

function Enable-TamperProtectionBestEffort {
    <#
    Best-effort Tamper Protection enable via the supported Windows Security UI.

    Returns $true when IsTamperProtected reads True afterwards, $false otherwise.
    Every failure is logged through Write-Log and never throws.
    #>
    [CmdletBinding()]
    param(
        # Seconds to wait for the Windows Security window and for the state to
        # settle after the toggle click. The XAML page can take 20-40s to
        # build its visual tree on a loaded machine.
        [int]$TimeoutSeconds = 60,

        # Set to skip the session check (only for tests / interactive use).
        [switch]$SkipSessionCheck
    )

    # ---- 0. is it already on? -------------------------------------------
    try {
        $st = Get-MpComputerStatus -ErrorAction Stop
        if ($st.PSObject.Properties.Name -contains 'IsTamperProtected' -and $st.IsTamperProtected) {
            Write-Log 'TAMPER: IsTamperProtected=True. No action needed.'
            return $true
        }
    } catch {
        Write-Log "TAMPER: could not read Defender status: $($_.Exception.Message)"
    }

    # ---- 1. UI automation needs the interactive session ------------------
    if (-not $SkipSessionCheck) {
        $sessionId = (Get-Process -Id $PID).SessionId
        if ($sessionId -eq 0 -or -not [Environment]::UserInteractive) {
            Write-Log ("TAMPER: running in session {0} (UserInteractive={1}); the Windows Security UI cannot be driven from here." -f $sessionId, [Environment]::UserInteractive)
            Write-Log 'TAMPER: relaunch this helper in the signed-in user session (see Start-DefenderGuardTamperInSession).'
            return $false
        }
    }

    # ---- 2. UIAutomation available? --------------------------------------
    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
        Add-Type -AssemblyName UIAutomationTypes  -ErrorAction Stop
    } catch {
        Write-Log "TAMPER: UIAutomation assemblies unavailable: $($_.Exception.Message)"
        return $false
    }

    $AE = [System.Windows.Automation.AutomationElement]
    $TS = [System.Windows.Automation.TreeScope]

    # ---- 3. open the settings page ---------------------------------------
    try {
        Start-Process 'windowsdefender://threatsettings' -ErrorAction Stop
        Write-Log 'TAMPER: opened windowsdefender://threatsettings.'
    } catch {
        Write-Log "TAMPER: could not open the Defender settings page: $($_.Exception.Message)"
        return $false
    }

    # ---- 4. find the window and the Tamper Protection toggle -------------
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $toggle   = $null
    while ((Get-Date) -lt $deadline -and -not $toggle) {
        Start-Sleep -Milliseconds 700
        try {
            $wCond = New-Object System.Windows.Automation.PropertyCondition(
                        $AE::ControlTypeProperty,
                        [System.Windows.Automation.ControlType]::Window)
            $win = $null
            foreach ($w in $AE::RootElement.FindAll($TS::Children, $wCond)) {
                if ($w.Current.Name -eq 'Windows Security') { $win = $w; break }
            }
            if (-not $win) { continue }

            # Tamper Protection group -> its ToggleSwitch button
            $grpCond = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, 'Tamper Protection')
            $btnCond = New-Object System.Windows.Automation.PropertyCondition(
                        $AE::ControlTypeProperty,
                        [System.Windows.Automation.ControlType]::Button)
            foreach ($g in $win.FindAll($TS::Descendants, $grpCond)) {
                if ($g.Current.ControlType.ProgrammaticName -notmatch 'Group') { continue }
                foreach ($b in $g.FindAll($TS::Descendants, $btnCond)) {
                    if ($b.Current.ClassName -eq 'ToggleSwitch' -and $b.Current.Name -eq 'Tamper Protection') {
                        $toggle = $b; break
                    }
                }
                if ($toggle) { break }
            }
        } catch { }
    }
    if (-not $toggle) {
        Write-Log "TAMPER: Tamper Protection toggle not found within ${TimeoutSeconds}s (page layout changed, or UI not reachable)."
        return $false
    }

    # ---- 5. already On in the UI? then nothing to do ---------------------
    $toggleState = 'UNKNOWN'
    try {
        $tp = $toggle.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        $toggleState = $tp.Current.ToggleState.ToString()
    } catch { }
    if ($toggleState -eq 'On') {
        Write-Log 'TAMPER: toggle already reports On.'
    } else {
        # ---- 6. flip it. ToggleSwitch exposes TogglePattern, not InvokePattern.
        try {
            $tp = $toggle.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
            $tp.Toggle()
            Write-Log "TAMPER: toggle clicked (was $toggleState)."
        } catch {
            Write-Log "TAMPER: could not toggle (win32 click fallback): $($_.Exception.Message)"
            return $false
        }
    }

    # ---- 7. verify against the runtime, not the UI -----------------------
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
        try {
            $st = Get-MpComputerStatus -ErrorAction Stop
            if ($st.PSObject.Properties.Name -contains 'IsTamperProtected' -and $st.IsTamperProtected) {
                Write-Log ("TAMPER: verified ON. IsTamperProtected=True, TamperProtectionSource=$($st.TamperProtectionSource).")
                return $true
            }
        } catch { }
    }

    Write-Log "TAMPER: toggle was clicked but IsTamperProtected is still False after ${TimeoutSeconds}s (pending Defender refresh, or centrally managed)."
    return $false
}

# ---------------------------------------------------------------------------
# Start-DefenderGuardTamperInSession
#
# The AR script runs as SYSTEM in session 0 and therefore cannot reach the
# Windows Security UI. This launches a short-lived copy of THIS file inside the
# interactive session (via a Scheduled Task with LogonType=Interactive), waits
# for it, and returns what the helper reported.
#
# Returns $true when the relaunched helper reported success.
# ---------------------------------------------------------------------------
function Start-DefenderGuardTamperInSession {
    [CmdletBinding()]
    param([int]$TimeoutSeconds = 90)

    $helperPath = $PSCommandPath
    if (-not $helperPath) { $helperPath = Join-Path $PSScriptRoot 'enable-tamper-protection.ps1' }
    if (-not (Test-Path $helperPath)) {
        Write-Log "TAMPER: helper not found at $helperPath."
        return $false
    }

    # who is signed in interactively?
    $user = $null
    $sid  = $null
    try {
        $sessions = (& qwinsta) 2>&1
        foreach ($line in $sessions) {
            if ($line -match '^\s*(rdp-tcp#\d+|console)\s+(\S+)\s+(\d+)\s+Active') {
                $user = $Matches[2]
                break
            }
        }
    } catch { }
    if (-not $user) {
        Write-Log 'TAMPER: no active interactive session; cannot reach the Windows Security UI.'
        return $false
    }

    $logPath  = Join-Path $env:ProgramData 'Defender-Guard\tamper-session.log'
    $taskName = 'Defender-Guard-Tamper-Enable'
    $nl       = [Environment]::NewLine

    # The child writes its own log line so we can read the result back.
    $xmlArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "' +
               ". '$helperPath'; " +
               "`$r = Enable-TamperProtectionBestEffort; " +
               "Add-Content -Path '$logPath' -Value ('RESULT=' + `$r)" +
               '"'

    $xml = [string]::Join($nl, @(
        '<?xml version="1.0" encoding="UTF-16"?>'
        '<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">'
        ('  <RegistrationInfo><Description>Defender-Guard: enable Tamper Protection in the interactive session.</Description></RegistrationInfo>')
        '  <Triggers>'
        ('    <TimeTrigger><StartBoundary>' + (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') + '</StartBoundary><Enabled>true</Enabled></TimeTrigger>')
        '  </Triggers>'
        '  <Principals>'
        ('    <Principal id="Author"><UserId>' + $user + '</UserId><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal>')
        '  </Principals>'
        '  <Settings>'
        '    <MultipleInstancesPolicy>StopExisting</MultipleInstancesPolicy>'
        '    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>'
        '    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>'
        '    <AllowHardTerminate>true</AllowHardTerminate>'
        '    <StartWhenAvailable>true</StartWhenAvailable>'
        '    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>'
        '    <AllowStartOnDemand>true</AllowStartOnDemand>'
        '    <Enabled>true</Enabled>'
        '    <Hidden>false</Hidden>'
        '    <RunOnlyIfIdle>false</RunOnlyIfIdle>'
        '    <WakeToRun>false</WakeToRun>'
        '    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>'
        '    <Priority>5</Priority>'
        '  </Settings>'
        '  <Actions Context="Author">'
        '    <Exec>'
        '      <Command>powershell.exe</Command>'
        ('      <Arguments>' + [System.Security.SecurityElement]::Escape($xmlArgs) + '</Arguments>')
        '    </Exec>'
        '  </Actions>'
        '</Task>'
    ))

    try {
        Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue |
            Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName $taskName -Xml $xml -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        Write-Log "TAMPER: launched helper in session of '$user'."
    } catch {
        Write-Log "TAMPER: could not launch the in-session helper: $($_.Exception.Message)"
        Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue |
            Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
        return $false
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        try {
            $st = Get-MpComputerStatus -ErrorAction Stop
            if ($st.PSObject.Properties.Name -contains 'IsTamperProtected' -and $st.IsTamperProtected) {
                Write-Log 'TAMPER: verified ON after the in-session run.'
                Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue |
                    Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
                return $true
            }
        } catch { }
    }

    Write-Log "TAMPER: in-session run did not turn Tamper Protection on within ${TimeoutSeconds}s."
    Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
    return $false
}
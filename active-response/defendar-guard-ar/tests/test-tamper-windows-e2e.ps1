# Windows end-to-end test for the Tamper Protection helper.
# Run INSIDE the interactive session of the target machine.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File test-tamper-windows-e2e.ps1
#
# Steps:
#   1. turn Tamper Protection OFF through the Windows Security UI (the only
#      supported way on 26H1) so the test has something to fix
#   2. confirm it is OFF
#   3. run Enable-TamperProtectionBestEffort from the helper
#   4. assert IsTamperProtected == True and that RTP cannot be disabled
$ErrorActionPreference = 'Continue'
$out = 'C:\Windows\Temp\tamper_e2e.txt'
Remove-Item $out -Force -ErrorAction SilentlyContinue
function W($s) { Add-Content $out $s }

$helper = $args[0]
if (-not $helper) { $helper = 'C:\Program Files\Sysinternals\enable-tamper-protection.ps1' }
W ('helper: ' + $helper + ' exists=' + (Test-Path $helper))
if (-not (Test-Path $helper)) { W 'CANNOT CONTINUE'; exit 1 }

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]

function Find-SecWin {
    $wCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window)
    foreach ($w in $AE::RootElement.FindAll($TS::Children, $wCond)) {
        try { if ($w.Current.Name -eq 'Windows Security') { return $w } } catch {}
    }
    return $null
}
function Find-TamperToggle {
    param($win)
    $grpCond = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, 'Tamper Protection')
    $btnCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    foreach ($g in $win.FindAll($TS::Descendants, $grpCond)) {
        if ($g.Current.ControlType.ProgrammaticName -notmatch 'Group') { continue }
        foreach ($b in $g.FindAll($TS::Descendants, $btnCond)) {
            if ($b.Current.ClassName -eq 'ToggleSwitch' -and $b.Current.Name -eq 'Tamper Protection') { return $b }
        }
    }
    return $null
}
function Get-ToggleState {
    param($el)
    try { return $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState.ToString() } catch { return 'UNKNOWN' }
}
function Set-TamperUi {
    param([string]$Want)
    Start-Process 'windowsdefender://threatsettings'
    # The page takes a while to build its XAML tree. Poll until the toggle
    # shows up instead of assuming a fixed delay.
    $deadline = (Get-Date).AddSeconds(90)
    $t = $null
    while ((Get-Date) -lt $deadline -and -not $t) {
        Start-Sleep -Seconds 2
        $w = Find-SecWin
        if (-not $w) { continue }
        $t = Find-TamperToggle -win $w
    }
    if (-not $t) { return 'NO_TOGGLE' }
    $cur = Get-ToggleState $t
    if ($cur -eq $Want) { return 'ALREADY_' + $Want.ToUpper() }
    $t.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    Start-Sleep -Seconds 8
    # re-read to confirm
    $w2 = Find-SecWin
    $t2 = if ($w2) { Find-TamperToggle -win $w2 } else { $null }
    $now = if ($t2) { Get-ToggleState $t2 } else { 'UNKNOWN' }
    return ('TOGGLED_FROM_' + $cur + '_NOW_' + $now)
}
function Stat($tag) {
    $s = Get-MpComputerStatus
    W ("  [$tag] IsTP=" + $s.IsTamperProtected + " Source=" + $s.TamperProtectionSource +
       " reg=" + (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name TamperProtection -ErrorAction SilentlyContinue).TamperProtection)
    return $s
}

$fail = 0
function Check { param($n, $c) if ($c) { W "PASS: $n" } else { W "FAIL: $n"; $script:fail++ } }

W ('=== session ' + (Get-Process -Id $PID).SessionId + ' user ' + (& whoami) + ' ===')

W ''
W '=== 1. force Tamper Protection OFF via the UI ==='
W ('  ' + (Set-TamperUi -Want 'Off'))
Start-Sleep -Seconds 5
$s = Stat 'after-off'
Check 'precondition: tamper is OFF' (-not $s.IsTamperProtected)

W ''
W '=== 2. run the helper (UI-driven enable) ==='
function Write-Log { param($Message) W ("  LOG: " + $Message) }
. $helper
$r = Enable-TamperProtectionBestEffort -TimeoutSeconds 40
W ('  helper returned: ' + $r)
Check 'helper returns $true' ($r -eq $true)

W ''
W '=== 3. verify ==='
$s2 = Stat 'after-helper'
Check 'IsTamperProtected == True' ($s2.IsTamperProtected)
Check 'registry TamperProtection == 5' ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name TamperProtection -ErrorAction SilentlyContinue).TamperProtection -eq 5)

W ''
W '=== 4. enforcement: RTP must stay ON ==='
try { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop; W '  Set-MpPreference accepted' } catch { W ('  blocked: ' + $_.Exception.Message) }
Start-Sleep -Seconds 4
$s3 = Get-MpComputerStatus
W ('  RTP after disable attempt: ' + $s3.RealTimeProtectionEnabled)
Check 'RTP stayed enabled (tamper enforcing)' ($s3.RealTimeProtectionEnabled)
if (-not $s3.RealTimeProtectionEnabled) { try { Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction SilentlyContinue } catch {} }

W ''
if ($fail) { W "FAILED: $fail checks"; exit 1 }
W 'ALL_PASS'
exit 0
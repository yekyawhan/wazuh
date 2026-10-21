#!/usr/bin/env pwsh
# Logic test for enable-tamper-protection.ps1.
#
# Runs on Linux (portable pwsh) by stubbing the Windows-only surface:
#   Get-MpComputerStatus, Get-Process, [Environment]::UserInteractive.
# The UIAutomation path itself cannot run off-Windows; it is covered by the
# Windows end-to-end test, tests/test-tamper-windows-e2e.ps1.
#
# Checks:
#   1. already ON            -> returns $true, no UI work
#   2. session 0             -> returns $false, no UI work
#   3. UIAutomation missing  -> returns $false, no throw
#   4. toggle not found      -> returns $false, no throw
#   5. toggle already On     -> returns $true, no click
#   6. toggle clicked + runtime confirms -> returns $true, exactly one click
#   7. toggle clicked, runtime never confirms -> returns $false (no false OK)

$ErrorActionPreference = 'Stop'

$script:mpStatus        = $null
$script:processSession  = 1
$script:userInteractive = $true
$script:uiaAvailable    = $true
$script:toggleFound     = $true
$script:toggleState     = 'Off'
$script:uiActions       = New-Object System.Collections.Generic.List[string]
$script:confirmAfterClick = $false
$script:clickCount      = 0

# ---- stubs ---------------------------------------------------------------
function Get-MpComputerStatus {
    if ($script:confirmAfterClick -and $script:clickCount -gt 0) {
        return [pscustomobject]@{ IsTamperProtected = $true; TamperProtectionSource = 'UI' }
    }
    if ($null -eq $script:mpStatus) { throw 'no status' }
    return $script:mpStatus
}
function Get-Process {
    param([Parameter(ValueFromRemainingArguments=$true)]$Rest)
    return [pscustomobject]@{ SessionId = $script:processSession }
}
function Start-Process { param([Parameter(ValueFromRemainingArguments=$true)]$Rest) }

# ---- load the real helper --------------------------------------------------
$helperPath = if ($args.Count -gt 0) { $args[0] } else { './enable-tamper-protection.ps1' }
$src = Get-Content -Raw $helperPath

# Replace the Windows-only surface with the stubs while keeping the real
# control flow of Enable-TamperProtectionBestEffort.
$src = $src.Replace('Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop', 'if (-not $script:uiaAvailable) { throw "no UIAutomation" }')
$src = $src.Replace('Add-Type -AssemblyName UIAutomationTypes  -ErrorAction Stop', 'if (-not $script:uiaAvailable) { throw "no UIAutomation" }')
$src = $src.Replace('[Environment]::UserInteractive', '$script:userInteractive')
$src = $src.Replace('(Get-Process -Id $PID).SessionId', '$script:processSession')
$src = $src.Replace('$AE = [System.Windows.Automation.AutomationElement]', '$AE = $script:FakeAE')
$src = $src.Replace('$TS = [System.Windows.Automation.TreeScope]',           '$TS = $script:FakeTS')

function Write-Log { param($Message) $script:uiActions.Add("LOG: $Message") }

# Fake stand-ins for the Windows-only UIAutomation types.
$script:FakeAE = [pscustomobject]@{}
$script:FakeTS = [pscustomobject]@{}

# Swap the whole UI-driving block (steps 3..6) for a scripted stub. The runtime
# verification loop (step 7) stays intact -- that is what we actually assert on.
$uiStart = $src.IndexOf('    # ---- 3. open the settings page')
$uiEnd   = $src.IndexOf('    # ---- 7. verify against the runtime')
if ($uiStart -lt 0 -or $uiEnd -lt 0) { throw 'could not locate the UI block markers in the helper' }

$stubUi = @'
    # --- stubbed UI block ---------------------------------------------
    if (-not $script:toggleFound) {
        Write-Log "TAMPER: Tamper Protection toggle not found within ${TimeoutSeconds}s (stub)."
        return $false
    }
    if ($script:toggleState -eq 'On') {
        Write-Log 'TAMPER: toggle already reports On.'
    } else {
        $script:clickCount++
        Write-Log "TAMPER: toggle clicked (was $script:toggleState)."
        $script:toggleState = 'On'
    }

'@
$src = $src.Substring(0, $uiStart) + $stubUi + $src.Substring($uiEnd)

. ([System.Management.Automation.ScriptBlock]::Create($src))

# ---- assertions ---------------------------------------------------------
$failures = @()
function Check { param($name, $cond) if ($cond) { "PASS: $name" } else { "FAIL: $name"; $script:failures += $name } }

function Reset-State {
    $script:mpStatus          = [pscustomobject]@{ IsTamperProtected = $false; TamperProtectionSource = 'UI' }
    $script:processSession    = 1
    $script:userInteractive   = $true
    $script:uiaAvailable      = $true
    $script:toggleFound       = $true
    $script:toggleState       = 'Off'
    $script:confirmAfterClick = $false
    $script:clickCount        = 0
    $script:uiActions.Clear()
}

# 1. already ON -> true, no click
Reset-State
$script:mpStatus = [pscustomobject]@{ IsTamperProtected = $true; TamperProtectionSource = 'UI' }
$r = Enable-TamperProtectionBestEffort -TimeoutSeconds 2
Check 'already-on: returns $true'   ( $r -eq $true )
Check 'already-on: no click'        ( $script:clickCount -eq 0 )

# 2. session 0 -> false, no click
Reset-State
$script:processSession = 0
$r = Enable-TamperProtectionBestEffort -TimeoutSeconds 2
Check 'session0: returns $false'    ( $r -eq $false )
Check 'session0: no click'          ( $script:clickCount -eq 0 )
Check 'session0: explains why'      ( (($script:uiActions -join '|') -match 'session 0') )

# 3. UIAutomation unavailable -> false, no throw
Reset-State
$script:uiaAvailable = $false
$r = Enable-TamperProtectionBestEffort -TimeoutSeconds 2
Check 'no-uia: returns $false'      ( $r -eq $false )
Check 'no-uia: no click'            ( $script:clickCount -eq 0 )

# 4. toggle not found -> false
Reset-State
$script:toggleFound = $false
$r = Enable-TamperProtectionBestEffort -TimeoutSeconds 2
Check 'no-toggle: returns $false'   ( $r -eq $false )
Check 'no-toggle: no click'         ( $script:clickCount -eq 0 )

# 5. toggle already On in the UI -> true, no click
Reset-State
$script:toggleState = 'On'
$script:mpStatus    = [pscustomobject]@{ IsTamperProtected = $true; TamperProtectionSource = 'UI' }
$r = Enable-TamperProtectionBestEffort -TimeoutSeconds 2
Check 'ui-on: returns $true'        ( $r -eq $true )
Check 'ui-on: no click'             ( $script:clickCount -eq 0 )

# 6. toggle Off -> clicked, runtime then confirms -> true, exactly one click
Reset-State
$script:confirmAfterClick = $true
$r = Enable-TamperProtectionBestEffort -TimeoutSeconds 5
Check 'click+verify: returns $true' ( $r -eq $true )
Check 'click+verify: one click'     ( $script:clickCount -eq 1 )

# 7. clicked but runtime never confirms -> false (must not report a false OK)
Reset-State
$script:confirmAfterClick = $false
$script:mpStatus = [pscustomobject]@{ IsTamperProtected = $false; TamperProtectionSource = 'UI' }
$r = Enable-TamperProtectionBestEffort -TimeoutSeconds 3
Check 'no-verify: returns $false'   ( $r -eq $false )
Check 'no-verify: did click'        ( $script:clickCount -eq 1 )

if ($failures.Count) { "FAILED: $($failures.Count) checks"; exit 1 }
'ALL_PASS'

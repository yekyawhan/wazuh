$Log = 'C:\Users\AGB\AppData\Local\Temp\claude\C--Users-AGB\4e780320-68a4-4785-abdd-17aeb7c1205b\scratchpad\task-install.log'
function W([string]$m) { $m | Add-Content -Path $Log }
Set-Content -Path $Log -Value "install run $(Get-Date -Format s)"

$ErrorActionPreference = 'Continue'
$TaskName = 'AGB-Suricata-IPS-Rules-Sync'
$Script   = 'C:\Program Files (x86)\ossec-agent\shared\suricata-win-offline\sync-ips-rules.ps1'

W "elevated: $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
W "script exists: $(Test-Path $Script)"

if (-not (Test-Path $Script)) { W "ABORT: script missing"; exit 1 }

try {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        W "removed existing task"
    }

    $Action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`""

    # every 5 minutes: an idle run is 3 small hashes - no suricata -T, no
    # restart. It only validates + restarts when the rules actually changed.
    $Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes 5) `
        -RepetitionDuration (New-TimeSpan -Days 3650)

    $Principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    $Settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger `
        -Principal $Principal -Settings $Settings `
        -Description 'Syncs agb-* Suricata rules from the Wazuh shared folder into C:\SuricataIPS\rules (validated, auto-rollback, restart only on change).' -ErrorAction Stop | Out-Null

    W "Register-ScheduledTask OK"
    Start-ScheduledTask -TaskName $TaskName
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    W "post-register state: $(if($t){$t.State}else{'NOT FOUND'})"
} catch {
    W "EXCEPTION: $($_.Exception.GetType().Name): $($_.Exception.Message)"
    exit 1
}
exit 0

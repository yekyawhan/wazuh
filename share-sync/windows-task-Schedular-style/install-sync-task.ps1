$TaskName = "Wazuh Share Sync"

$Script = `
"C:\Program Files (x86)\ossec-agent\shared\share-sync.ps1"



if(Get-ScheduledTask `
-TaskName $TaskName `
-ErrorAction SilentlyContinue)
{

Unregister-ScheduledTask `
-TaskName $TaskName `
-Confirm:$false

}



$Action = New-ScheduledTaskAction `
-Execute "powershell.exe" `
-Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`""



$Trigger = New-ScheduledTaskTrigger `
-RepetitionInterval (New-TimeSpan -Minutes 1) `
-Once



$Principal = New-ScheduledTaskPrincipal `
-UserId SYSTEM `
-RunLevel Highest



Register-ScheduledTask `
-TaskName $TaskName `
-Action $Action `
-Trigger $Trigger `
-Principal $Principal



Write-Host "Wazuh Share Sync Task Installed"

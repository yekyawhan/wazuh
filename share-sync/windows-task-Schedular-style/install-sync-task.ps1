# ==========================================================
# Wazuh Share Sync Installer
#
# Install:
#   1. Enable Wazuh remote command options
#   2. Create Scheduled Task
#
# Run once per agent
# ==========================================================


$AgentDir = "C:\Program Files (x86)\ossec-agent"

$SyncScript = "$AgentDir\shared\share-sync.ps1"

$InternalConfig = "$AgentDir\local_internal_options.conf"

$TaskName = "Wazuh Share Sync"



# ==========================
# Admin Check
# ==========================

$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()

$admin = New-Object Security.Principal.WindowsPrincipal($currentUser)


if(!$admin.IsInRole(
[Security.Principal.WindowsBuiltInRole]::Administrator))
{
    Write-Host "Run as Administrator" -ForegroundColor Red
    exit 1
}



# ==========================
# Enable Wazuh Options
# ==========================


if(!(Test-Path $InternalConfig))
{
    New-Item `
    -ItemType File `
    -Path $InternalConfig `
    -Force | Out-Null
}



$Options = @(

    "wazuh_command.remote_commands=1"

    "logcollector.remote_commands=1"

)



$RestartRequired = $false



foreach($opt in $Options)
{

    if(!(Select-String `
    -Path $InternalConfig `
    -Pattern "^$opt$" `
    -Quiet))
    {

        Add-Content `
        -Path $InternalConfig `
        -Value $opt `
        -Encoding ASCII


        Write-Host "Enabled: $opt"

        $RestartRequired=$true

    }

    else
    {
        Write-Host "Already enabled: $opt"
    }

}



if($RestartRequired)
{

    Write-Host "Restarting Wazuh Service..."

    Restart-Service `
    WazuhSvc `
    -Force

}



# ==========================
# Check Sync Script
# ==========================

if(!(Test-Path $SyncScript))
{

    Write-Host "Missing:"
    Write-Host $SyncScript

    exit 1

}



# ==========================
# Remove Existing Task
# ==========================


if(Get-ScheduledTask `
-TaskName $TaskName `
-ErrorAction SilentlyContinue)
{

    Unregister-ScheduledTask `
    -TaskName $TaskName `
    -Confirm:$false

}



# ==========================
# Create Task Action
# ==========================


$Action = New-ScheduledTaskAction `
-Execute "powershell.exe" `
-Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SyncScript`""



# ==========================
# Every 1 minute
# ==========================


$Trigger = New-ScheduledTaskTrigger `
-Once `
-At (Get-Date).AddMinutes(1) `
-RepetitionInterval (New-TimeSpan -Minutes 1) `
-RepetitionDuration (New-TimeSpan -Days 3650)



# ==========================
# SYSTEM
# ==========================


$Principal = New-ScheduledTaskPrincipal `
-UserId "SYSTEM" `
-RunLevel Highest



$Settings = New-ScheduledTaskSettingsSet `
-AllowStartIfOnBatteries `
-DontStopIfGoingOnBatteries `
-ExecutionTimeLimit ([TimeSpan]::Zero)



# ==========================
# Register
# ==========================


Register-ScheduledTask `
-TaskName $TaskName `
-Action $Action `
-Trigger $Trigger `
-Principal $Principal `
-Settings $Settings `
-Description "Wazuh Active Response file synchronization"



Start-ScheduledTask `
-TaskName $TaskName



Write-Host ""
Write-Host "======================================"
Write-Host " Wazuh Share Sync Installed"
Write-Host " Remote Commands Enabled"
Write-Host " Sync Interval: 1 Minute"
Write-Host "======================================"


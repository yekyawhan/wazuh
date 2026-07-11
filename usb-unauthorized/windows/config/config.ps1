# Wazuh USB Sync — Windows V2 Configuration
# Dot-sourced by every script. Single source of truth for paths/keys/tasks.

Set-StrictMode -Version Latest

$UsbSync = @{
    Version            = '2.0.0'
    ComponentName      = 'WazuhHybridUsbSync'

    # Wazuh agent layout
    AgentRootX86       = Join-Path ${env:ProgramFiles(x86)} 'ossec-agent'
    AgentRoot          = Join-Path $env:ProgramData     'ossec-agent'
    SharedDir          = 'shared'
    WhitelistFile      = 'usb_whitelist.txt'

    # Application data
    AppRoot            = Join-Path $env:ProgramData 'Wazuh\UsbSync'
    LogDir             = Join-Path $env:ProgramData 'Wazuh\Logs\UsbSync'
    LogFile            = 'usb-sync.log'
    InstallLogFile     = 'install.log'
    WatcherLogFile     = 'watcher.log'
    StateFile          = 'last-state.json'

    # Registry policy (allow-list mode)
    PolicyRoot            = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
    AllowDeviceIdsRoot    = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
    AllowDeviceIdsEnabled = 'AllowDeviceIDsEnabled'
    AllowDeviceIds        = 'AllowDeviceIDs'
    BackupSubKey          = 'V2Backup'

    # Scheduled task
    TaskName           = 'Wazuh Hybrid USB Sync'
    TaskDescription    = 'Synchronizes Wazuh USB whitelist and enforces device install policy'
    TaskRunInterval    = 'PT5M'

    # Event Log
    EventLogSource     = 'WazuhUsbSync'
    EventLogName       = 'Application'

    # Behavior
    MaxRetries         = 3
    RetryDelaySeconds  = 2
    RequireAdmin       = $true
}

# Resolve whitelist path at access time (so any agent install layout works)
function Get-UsbWhitelistPath {
    [CmdletBinding()]
    param()
    $candidates = @(
        (Join-Path $UsbSync.AgentRootX86 ($UsbSync.SharedDir + '\' + $UsbSync.WhitelistFile))
        (Join-Path $UsbSync.AgentRoot    ($UsbSync.SharedDir + '\' + $UsbSync.WhitelistFile))
    )
    foreach ($p in $candidates) {
        $parent = Split-Path -Path $p -Parent
        if ($parent -and (Test-Path -LiteralPath $parent)) { return $p }
    }
    return $candidates[0]
}

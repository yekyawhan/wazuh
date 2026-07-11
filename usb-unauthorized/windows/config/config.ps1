# Wazuh USB Sync — Windows V2 Configuration
# Dot-sourced by every script. Single source of truth for paths/keys/tasks.

Set-StrictMode -Version Latest

# NOTE: must be $global so module-scope functions (Registry.psm1, Policy.psm1)
# can read it. A plain script-scope $UsbSync is invisible inside imported modules.
$global:UsbSync = @{
    Version            = '2.0.0'
    ComponentName      = 'WazuhHybridUsbSync'

    # Wazuh agent layout
    AgentRootX86       = Join-Path ${env:ProgramFiles(x86)} 'ossec-agent'
    AgentRoot          = Join-Path ${env:ProgramFiles}   'ossec-agent'
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
    # Required so devices NOT in the allow list are actually blocked.
    # Without this, AllowDeviceIDs only *permits* listed devices; others still install.
    DenyUnspecified       = 'DenyUnspecified'
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
<#
.SYNOPSIS
    Resolves the path to the Wazuh-distributed usb_whitelist.txt.

.DESCRIPTION
    Prefers the x86 agent path (C:\Program Files (x86)\ossec-agent\shared),
    falling back to the Program Files path. Returns the first existing parent
    dir's path, else the x86 path.

.OUTPUTS
    [string] full path to usb_whitelist.txt.
#>
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

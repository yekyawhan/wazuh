# hybrid_sync_usb_v2.ps1 — Entry point
# Reads Wazuh shared whitelist, applies via Registry (Sprint 2 will wire engines).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot 'config\config.ps1')

Import-Module (Join-Path $ScriptRoot 'modules\Logger.psm1')   -Force
Import-Module (Join-Path $ScriptRoot 'modules\Utils.psm1')    -Force
Import-Module (Join-Path $ScriptRoot 'modules\Parser.psm1')   -Force
Import-Module (Join-Path $ScriptRoot 'modules\Registry.psm1') -Force
Import-Module (Join-Path $ScriptRoot 'modules\Policy.psm1')   -Force

function Invoke-HybridUsbSync {
    [CmdletBinding()]
    param()

    Initialize-Logger -LogDir $UsbSync.LogDir -LogFileName $UsbSync.LogFile `
        -EventSource $UsbSync.EventLogSource -EventLogName $UsbSync.EventLogName

    if ($UsbSync.RequireAdmin -and -not (Test-IsAdministrator)) {
        Write-LogError 'Administrator privileges required. Aborting.'
        return 1
    }

    $whitelistPath = Get-UsbWhitelistPath
    Write-LogInfo "Sync started. Whitelist: $whitelistPath"

    try {
        $entries = Merge-Whitelist -Path $whitelistPath
        Write-LogInfo "Parsed $($entries.Count) unique device(s)."

        if ($entries.Count -eq 0) {
            Write-LogWarning "Whitelist is empty. Removing allow-list policy (default-deny)."
            Remove-UsbAllowList
        } else {
            Set-UsbAllowList -DeviceIds $entries.DeviceId
        }

        Write-LogAudit "Sync completed. Devices: $($entries.Count)"
        return 0
    } catch {
        Write-LogError "Sync failed: $($_.Exception.Message)"
        return 2
    }
}

# Run when invoked directly (not when dot-sourced)
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-HybridUsbSync)
}

Export-ModuleMember -Function 'Invoke-HybridUsbSync'

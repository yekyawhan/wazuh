# Policy.psm1 — Allow-list policy apply
# Writes whitelist into HKLM\...\DeviceInstall\Restrictions as AllowDeviceIDs.
# Atomic: backup → write → verify → restore on failure.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Set-UsbAllowList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$DeviceIds
    )
    $root = $UsbSync.PolicyRoot

    # 1. Backup
    $backup = Backup-PolicyState

    # 2. Ensure root
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -Path $root -Force | Out-Null
    }

    # 3. Write
    try {
        Set-ItemProperty -LiteralPath $root -Name $UsbSync.AllowDeviceIdsEnabled -Value 1 -Type DWord
        if ($DeviceIds.Count -gt 0) {
            Set-ItemProperty -LiteralPath $root -Name $UsbSync.AllowDeviceIds -Value $DeviceIds -Type MultiString
        } else {
            Remove-ItemProperty -LiteralPath $root -Name $UsbSync.AllowDeviceIds -ErrorAction SilentlyContinue
        }
    } catch {
        Write-LogError "Registry write failed: $($_.Exception.Message). Restoring backup."
        Restore-PolicyState -State $backup
        throw
    }

    # 4. Verify
    if (-not (Test-PolicyState -ExpectedDeviceIds $DeviceIds)) {
        Write-LogError "Registry verification failed. Restoring backup."
        Restore-PolicyState -State $backup
        throw "Policy verify mismatch"
    }

    Write-LogAudit "Allow-list applied. Devices: $($DeviceIds.Count)"
    return $true
}

function Remove-UsbAllowList {
    [CmdletBinding()]
    param()
    $root = $UsbSync.PolicyRoot
    $backup = Backup-PolicyState
    try {
        if (Test-Path -LiteralPath $root) {
            Remove-ItemProperty -LiteralPath $root -Name $UsbSync.AllowDeviceIdsEnabled -ErrorAction SilentlyContinue
            Remove-ItemProperty -LiteralPath $root -Name $UsbSync.AllowDeviceIds        -ErrorAction SilentlyContinue
        }
        Write-LogAudit "Allow-list removed (uninstall)."
    } catch {
        Write-LogError "Remove failed: $($_.Exception.Message). Restoring."
        Restore-PolicyState -State $backup
        throw
    }
}

Export-ModuleMember -Function @(
    'Set-UsbAllowList',
    'Remove-UsbAllowList'
)

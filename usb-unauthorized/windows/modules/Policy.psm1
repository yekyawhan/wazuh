# Policy.psm1 — Allow-list policy apply
# Writes whitelist into HKLM\...\DeviceInstall\Restrictions as AllowDeviceIDs.
# Atomic: backup → write → verify → restore on failure.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Applies the USB allow-list to the device-install policy.

.DESCRIPTION
    Atomic: backs up the current policy, writes AllowDeviceIDsEnabled + the
    device list, verifies the result, and restores the backup if anything
    mismatches. An empty list with Enabled=1 means "block all".

.PARAMETER DeviceIds
    Windows-form device IDs to allow. Pass @() to block everything.

.OUTPUTS
    [bool] true on success.
#>
function Set-UsbAllowList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$DeviceIds
    )
    $root = $UsbSync.PolicyRoot
    $subkey = $UsbSync.AllowDeviceIdsRoot

    # 1. Backup
    $backup = Backup-PolicyState

    # 2. Ensure root
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -Path $root -Force | Out-Null
    }

    # 3. Write — Windows reads AllowDeviceIDs as DWORD enabler + numbered subkey entries
    try {
        # Enable allow-list mode at root
        Set-ItemProperty -LiteralPath $root -Name $UsbSync.AllowDeviceIdsEnabler -Value 1 -Type DWord
        # Block everything not explicitly allowed
        Set-ItemProperty -LiteralPath $root -Name $UsbSync.DenyUnspecified -Value 1 -Type DWord

        # Remove old subkey if present, recreate fresh
        if (Test-Path -LiteralPath $subkey) {
            Remove-Item -LiteralPath $subkey -Recurse -Force
        }
        if ($DeviceIds.Count -gt 0 -or $UsbSync.StorageLayerIds.Count -gt 0) {
            New-Item -Path $subkey -Force | Out-Null
            # Write user device IDs as numbered REG_SZ entries
            $index = 1
            foreach ($id in $DeviceIds) {
                Set-ItemProperty -LiteralPath $subkey -Name $index.ToString() -Value $id -Type String
                $index++
            }
            # Append storage layer wildcards so approved drives actually mount
            foreach ($id in $UsbSync.StorageLayerIds) {
                Set-ItemProperty -LiteralPath $subkey -Name $index.ToString() -Value $id -Type String
                $index++
            }
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

<#
.SYNOPSIS
    Removes the allow-list policy entirely.

.DESCRIPTION
    Use only during uninstall. Restores Windows' default (all-allowed) device
    install behavior. Does NOT leave a block-all state.
#>
function Remove-UsbAllowList {
    [CmdletBinding()]
    param()
    $root = $UsbSync.PolicyRoot
    $subkey = $UsbSync.AllowDeviceIdsRoot
    $backup = Backup-PolicyState
    try {
        if (Test-Path -LiteralPath $root) {
            # Remove enabler + deny flag
            Remove-ItemProperty -LiteralPath $root -Name $UsbSync.AllowDeviceIdsEnabler -ErrorAction SilentlyContinue
            Remove-ItemProperty -LiteralPath $root -Name $UsbSync.DenyUnspecified -ErrorAction SilentlyContinue
            # Remove the AllowDeviceIDs subkey with all numbered entries
            if (Test-Path -LiteralPath $subkey) {
                Remove-Item -LiteralPath $subkey -Recurse -Force -ErrorAction SilentlyContinue
            }
            # After all values removed, delete the now-empty parent key so Windows
            # returns fully to "all devices allowed" default state.
            if (-not (Get-Item -LiteralPath $root -ErrorAction SilentlyContinue) -or
                @((Get-Item -LiteralPath $root).GetValueNames()).Count -eq 0) {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
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

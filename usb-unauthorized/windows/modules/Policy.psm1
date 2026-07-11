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

    # 1. Backup
    $backup = Backup-PolicyState

    # 2. Ensure root
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -Path $root -Force | Out-Null
    }

    # 3. Write
    try {
        Set-ItemProperty -LiteralPath $root -Name $UsbSync.AllowDeviceIdsEnabled -Value 1 -Type DWord
        # Block everything not explicitly allowed (else the allow-list is toothless).
        Set-ItemProperty -LiteralPath $root -Name $UsbSync.DenyUnspecified -Value 1 -Type DWord
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
    $backup = Backup-PolicyState
    try {
        if (Test-Path -LiteralPath $root) {
            Remove-ItemProperty -LiteralPath $root -Name $UsbSync.AllowDeviceIdsEnabled -ErrorAction SilentlyContinue
            Remove-ItemProperty -LiteralPath $root -Name $UsbSync.AllowDeviceIds        -ErrorAction SilentlyContinue
            Remove-ItemProperty -LiteralPath $root -Name $UsbSync.DenyUnspecified       -ErrorAction SilentlyContinue
            # After all values removed, delete the now-empty parent key so Windows
            # returns fully to "all devices allowed" default state.
            if (-not (Get-Item -LiteralPath $root -ErrorAction SilentlyContinue) -or
                @((Get-Item -LiteralPath $root).GetValueNames()).Count -eq 0) {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
                # Walk up: also drop DeviceInstall key if it's now empty (it usually has children from other policies)
                # but only if no sibling values remain
                $parent = Split-Path -LiteralPath $root -Parent
                if (Test-Path -LiteralPath $parent) {
                    $siblings = (Get-Item -LiteralPath $parent).GetSubKeyNames()
                    if ($siblings -notcontains 'Restrictions') {
                        # parent DeviceInstall still has other subkeys (common) - leave it
                    }
                }
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

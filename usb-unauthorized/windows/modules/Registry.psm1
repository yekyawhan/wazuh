# Registry.psm1 — Registry engine
# Allow-list policy under HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions.
# Atomic writes: backup → write → verify → on failure, restore.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Snapshots the current device-install policy.

.DESCRIPTION
    Captures whether the policy key existed, AllowDeviceIDsEnabled, and the
    AllowDeviceIDs list. Pass the result to Restore-PolicyState to roll back.

.OUTPUTS
    [hashtable] { Existed, AllowEnabled, AllowList, PolicyRoot, AllowDeviceIdsPath, Timestamp }
#>
function Backup-PolicyState {
    [CmdletBinding()]
    param()
    $state = @{
        Timestamp          = (Get-Date).ToString('o')
        PolicyRoot         = $UsbSync.PolicyRoot
        AllowDeviceIdsPath = $UsbSync.AllowDeviceIdsRoot
        AllowEnabled       = $null
        AllowList          = @()
        Existed            = $false
    }
    $root = $UsbSync.PolicyRoot
    $subkey = $UsbSync.AllowDeviceIdsRoot
    if (Test-Path -LiteralPath $root) {
        $state.Existed = $true
        # Read enabler DWORD at root
        try {
            $p = Get-ItemProperty -LiteralPath $root -Name $UsbSync.AllowDeviceIdsEnabler -ErrorAction SilentlyContinue
            if ($p) { $state.AllowEnabled = [int]$p.$($UsbSync.AllowDeviceIdsEnabler) }
        } catch {}
        # Read numbered entries from AllowDeviceIDs subkey
        if (Test-Path -LiteralPath $subkey) {
            try {
                $entries = Get-Item -LiteralPath $subkey | Select-Object -ExpandProperty Property
                $list = @()
                foreach ($name in $entries) {
                    $val = Get-ItemProperty -LiteralPath $subkey -Name $name -ErrorAction SilentlyContinue
                    if ($val) { $list += $val.$name }
                }
                $state.AllowList = $list
            } catch {}
        }
    }
    return $state
}

<#
.SYNOPSIS
    Restores a policy snapshot captured by Backup-PolicyState.

.PARAMETER State
    The hashtable returned by Backup-PolicyState.
#>
function Restore-PolicyState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State
    )
    $root = $UsbSync.PolicyRoot
    $subkey = $UsbSync.AllowDeviceIdsRoot
    if (-not $State.Existed) {
        # Original state had no policy — remove if we created one
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        return
    }
    # Restore enabler DWORD at root
    if ($null -eq $State.AllowEnabled) {
        Remove-ItemProperty -LiteralPath $root -Name $UsbSync.AllowDeviceIdsEnabler -ErrorAction SilentlyContinue
    } else {
        Set-ItemProperty -LiteralPath $root -Name $UsbSync.AllowDeviceIdsEnabler -Value $State.AllowEnabled -Type DWord
    }
    # Restore numbered entries in AllowDeviceIDs subkey
    if (Test-Path -LiteralPath $subkey) {
        Remove-Item -LiteralPath $subkey -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($State.AllowList.Count -gt 0) {
        New-Item -Path $subkey -Force | Out-Null
        $index = 1
        foreach ($id in $State.AllowList) {
            Set-ItemProperty -LiteralPath $subkey -Name $index.ToString() -Value $id -Type String
            $index++
        }
    }
}

<#
.SYNOPSIS
    Verifies the live registry matches the expected allow-list.

.PARAMETER ExpectedDeviceIds
    The device IDs that should be present (unsorted; compared as a set).

.OUTPUTS
    [bool] true if enabled + list matches exactly.
#>
function Test-PolicyState {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string[]]$ExpectedDeviceIds
    )
    $root = $UsbSync.PolicyRoot
    $subkey = $UsbSync.AllowDeviceIdsRoot
    if (-not (Test-Path -LiteralPath $root)) { return ($ExpectedDeviceIds.Count -eq 0) }
    # Check enabler DWORD at root
    $enabled = (Get-ItemProperty -LiteralPath $root -Name $UsbSync.AllowDeviceIdsEnabler -ErrorAction SilentlyContinue).$($UsbSync.AllowDeviceIdsEnabler)
    if ([int]$enabled -ne 1) { return $false }
    # Read numbered entries from AllowDeviceIDs subkey (includes user IDs + storage layer IDs)
    $actualList = @()
    if (Test-Path -LiteralPath $subkey) {
        $entries = Get-Item -LiteralPath $subkey | Select-Object -ExpandProperty Property
        foreach ($name in $entries) {
            $val = Get-ItemProperty -LiteralPath $subkey -Name $name -ErrorAction SilentlyContinue
            if ($val) { $actualList += $val.$name }
        }
    }
    # Expected = user device IDs + storage layer IDs
    $expected = @($ExpectedDeviceIds) + @($UsbSync.StorageLayerIds)
    $expectedSorted = @($expected | Sort-Object)
    $actualSorted = @($actualList | Sort-Object)
    if ($expectedSorted.Count -ne $actualSorted.Count) { return $false }
    for ($i = 0; $i -lt $expectedSorted.Count; $i++) {
        if ($expectedSorted[$i] -ne $actualSorted[$i]) { return $false }
    }
    return $true
}

Export-ModuleMember -Function @(
    'Backup-PolicyState',
    'Restore-PolicyState',
    'Test-PolicyState'
)

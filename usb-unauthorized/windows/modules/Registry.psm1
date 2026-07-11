# Registry.psm1 — Registry engine
# Allow-list policy under HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions.
# Atomic writes: backup → write → verify → on failure, restore.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PolicyRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $UsbSync.PolicyRoot
}

function Get-AllowDeviceIdsPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $UsbSync.AllowDeviceIdsRoot
}

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
    if (Test-Path -LiteralPath $root) {
        $state.Existed = $true
        try {
            $p = Get-ItemProperty -LiteralPath $root -Name $UsbSync.AllowDeviceIdsEnabled -ErrorAction SilentlyContinue
            if ($p) { $state.AllowEnabled = [int]$p.$($UsbSync.AllowDeviceIdsEnabled) }
        } catch {}
        try {
            $p = Get-ItemProperty -LiteralPath $root -Name $UsbSync.AllowDeviceIds -ErrorAction SilentlyContinue
            if ($p -and $p.$($UsbSync.AllowDeviceIds)) {
                $state.AllowList = @($p.$($UsbSync.AllowDeviceIds))
            }
        } catch {}
    }
    return $state
}

function Restore-PolicyState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State
    )
    $root = $UsbSync.PolicyRoot
    if (-not $State.Existed) {
        # Original state had no policy — remove if we created one
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        return
    }
    if ($null -eq $State.AllowEnabled) {
        Remove-ItemProperty -LiteralPath $root -Name $UsbSync.AllowDeviceIdsEnabled -ErrorAction SilentlyContinue
    } else {
        Set-ItemProperty -LiteralPath $root -Name $UsbSync.AllowDeviceIdsEnabled -Value $State.AllowEnabled -Type DWord
    }
    if ($State.AllowList.Count -eq 0) {
        Remove-ItemProperty -LiteralPath $root -Name $UsbSync.AllowDeviceIds -ErrorAction SilentlyContinue
    } else {
        Set-ItemProperty -LiteralPath $root -Name $UsbSync.AllowDeviceIds -Value $State.AllowList -Type MultiString
    }
}

function Test-PolicyState {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string[]]$ExpectedDeviceIds
    )
    $root = $UsbSync.PolicyRoot
    if (-not (Test-Path -LiteralPath $root)) { return ($ExpectedDeviceIds.Count -eq 0) }
    $enabled = (Get-ItemProperty -LiteralPath $root -Name $UsbSync.AllowDeviceIdsEnabled -ErrorAction SilentlyContinue).$($UsbSync.AllowDeviceIdsEnabled)
    if ([int]$enabled -ne 1) { return $false }
    $list = (Get-ItemProperty -LiteralPath $root -Name $UsbSync.AllowDeviceIds -ErrorAction SilentlyContinue).$($UsbSync.AllowDeviceIds)
    if (-not $list) { return ($ExpectedDeviceIds.Count -eq 0) }
    $expected = @($ExpectedDeviceIds | Sort-Object)
    $actual   = @($list | Sort-Object)
    if ($expected.Count -ne $actual.Count) { return $false }
    for ($i = 0; $i -lt $expected.Count; $i++) {
        if ($expected[$i] -ne $actual[$i]) { return $false }
    }
    return $true
}

Export-ModuleMember -Function @(
    'Get-PolicyRoot',
    'Get-AllowDeviceIdsPath',
    'Backup-PolicyState',
    'Restore-PolicyState',
    'Test-PolicyState'
)

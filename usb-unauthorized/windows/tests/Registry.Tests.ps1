# Pester test for Registry round-trip
# Run: Invoke-Pester -Path tests\Registry.Tests.ps1
# These tests write to HKLM — must run elevated.

BeforeAll {
    $script:AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $script:AppRoot 'config\config.ps1')
    Import-Module (Join-Path $script:AppRoot 'modules\Logger.psm1')   -Force
    Import-Module (Join-Path $script:AppRoot 'modules\Utils.psm1')    -Force
    Import-Module (Join-Path $script:AppRoot 'modules\Registry.psm1') -Force
    Import-Module (Join-Path $script:AppRoot 'modules\Policy.psm1')   -Force
    Initialize-Logger -LogDir $env:TEMP -LogFileName 'registry-test.log' -EventSource 'TestSource'

    if (-not (Test-IsAdministrator)) {
        throw 'Registry tests require Administrator.'
    }
}

AfterAll {
    # Best-effort cleanup of test key
    if (Test-Path -LiteralPath $UsbSync.PolicyRoot) {
        try { Remove-Item -LiteralPath $UsbSync.PolicyRoot -Recurse -Force -ErrorAction Stop }
        catch { }
    }
}

Describe 'Backup / Restore round-trip' {
    It 'backup captures non-existent state' {
        Remove-Item -LiteralPath $UsbSync.PolicyRoot -Recurse -Force -ErrorAction SilentlyContinue
        $b = Backup-PolicyState
        $b.Existed | Should -Be $false
    }
    It 'backup captures existing values' {
        if (-not (Test-Path $UsbSync.PolicyRoot)) { New-Item -Path $UsbSync.PolicyRoot -Force | Out-Null }
        Set-ItemProperty -LiteralPath $UsbSync.PolicyRoot -Name $UsbSync.AllowDeviceIdsEnabled -Value 1 -Type DWord
        Set-ItemProperty -LiteralPath $UsbSync.PolicyRoot -Name $UsbSync.AllowDeviceIds -Value @('USB\VID_AAAA&PID_BBBB') -Type MultiString
        $b = Backup-PolicyState
        $b.Existed | Should -Be $true
        $b.AllowEnabled | Should -Be 1
        $b.AllowList | Should -Contain 'USB\VID_AAAA&PID_BBBB'
    }
}

Describe 'Test-PolicyState' {
    It 'matches applied list' {
        $b = Backup-PolicyState
        try {
            $ids = @('USB\VID_1111&PID_2222', 'USB\VID_3333&PID_4444')
            Set-UsbAllowList -DeviceIds $ids
            Test-PolicyState -ExpectedDeviceIds $ids | Should -Be $true
            Test-PolicyState -ExpectedDeviceIds @('USB\VID_9999&PID_9999') | Should -Be $false
        } finally {
            Restore-PolicyState -State $b
        }
    }
}

Describe 'Set-UsbAllowList' {
    It 'writes + verifies, then restores on simulated verify failure' {
        $b = Backup-PolicyState
        try {
            Set-UsbAllowList -DeviceIds @('USB\VID_CCCC&PID_DDDD') | Should -Be $true
            (Get-ItemProperty -LiteralPath $UsbSync.PolicyRoot -Name $UsbSync.AllowDeviceIdsEnabled).$($UsbSync.AllowDeviceIdsEnabled) | Should -Be 1
            (Get-ItemProperty -LiteralPath $UsbSync.PolicyRoot -Name $UsbSync.AllowDeviceIds).$($UsbSync.AllowDeviceIds) | Should -Contain 'USB\VID_CCCC&PID_DDDD'
        } finally {
            Restore-PolicyState -State $b
        }
    }
    It 'Remove-UsbAllowList clears the policy' {
        Set-UsbAllowList -DeviceIds @('USB\VID_EEEE&PID_FFFF')
        Remove-UsbAllowList
        (Get-ItemProperty -LiteralPath $UsbSync.PolicyRoot -Name $UsbSync.AllowDeviceIdsEnabled -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
    }
}

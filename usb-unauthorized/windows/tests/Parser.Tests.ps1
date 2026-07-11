# Pester test for Parser.psm1
# Run: Invoke-Pester -Path tests\Parser.Tests.ps1

BeforeAll {
    $script:AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $script:AppRoot 'config\config.ps1')
    Import-Module (Join-Path $script:AppRoot 'modules\Logger.psm1') -Force
    Import-Module (Join-Path $script:AppRoot 'modules\Parser.psm1') -Force
    Initialize-Logger -LogDir $env:TEMP -LogFileName 'parser-test.log' -EventSource 'TestSource'
}

Describe 'Resolve-DeviceFormat' {
    It 'accepts Windows form' {
        InModuleScope Parser { Resolve-DeviceFormat -Line 'USB\VID_0951&PID_1666' } | Should -Be 'Windows'
    }
    It 'accepts Linux form' {
        InModuleScope Parser { Resolve-DeviceFormat -Line '0951:1666' } | Should -Be 'Linux'
    }
    It 'rejects garbage' {
        InModuleScope Parser { Resolve-DeviceFormat -Line 'random text' } | Should -BeNullOrEmpty
    }
    It 'trims whitespace' {
        InModuleScope Parser { Resolve-DeviceFormat -Line '   0951:1666  ' } | Should -Be 'Linux'
    }
}

Describe 'ConvertTo-WindowsDeviceId' {
    It 'pads short VID/PID' {
        InModuleScope Parser { ConvertTo-WindowsDeviceId -LinuxId '951:166' } | Should -Be 'USB\VID_0951&PID_0166'
    }
    It 'uppercases' {
        InModuleScope Parser { ConvertTo-WindowsDeviceId -LinuxId '0951:1666' } | Should -Be 'USB\VID_0951&PID_1666'
    }
    It 'rejects malformed' {
        InModuleScope Parser { ConvertTo-WindowsDeviceId -LinuxId '0951' } | Should -BeNullOrEmpty
    }
}

Describe 'Read-UsbWhitelist' {
    BeforeEach {
        $script:tmp = Join-Path $env:TEMP ([guid]::NewGuid()) + '.txt'
    }
    AfterEach {
        if (Test-Path $script:tmp) { Remove-Item -LiteralPath $script:tmp -Force }
    }
    It 'skips blanks + comments' {
        Set-Content -LiteralPath $script:tmp -Value @(
            '# header'
            ''
            '   '
            'USB\VID_0951&PID_1666'
        ) -Encoding UTF8
        $r = Read-UsbWhitelist -Path $script:tmp
        $r.Count | Should -Be 1
        $r[0].Valid | Should -Be $true
        $r[0].DeviceId | Should -Be 'USB\VID_0951&PID_1666'
    }
    It 'flags invalid lines but keeps valid ones' {
        Set-Content -LiteralPath $script:tmp -Value @(
            'USB\VID_0951&PID_1666'
            'not-a-device'
            '0951:1666'
        ) -Encoding UTF8
        $r = Read-UsbWhitelist -Path $script:tmp
        ($r | Where-Object Valid).Count | Should -Be 2
        ($r | Where-Object { -not $_.Valid }).Count | Should -Be 1
    }
    It 'returns empty for missing file' {
        $r = Read-UsbWhitelist -Path 'C:\nonexistent\nope.txt'
        $r.Count | Should -Be 0
    }
}

Describe 'Merge-Whitelist' {
    It 'dedupes across formats (Linux + Windows form = 1 device)' {
        $tmp = Join-Path $env:TEMP ([guid]::NewGuid()) + '.txt'
        try {
            Set-Content -LiteralPath $tmp -Value @(
                'USB\VID_0951&PID_1666'
                '0951:1666'
            ) -Encoding UTF8
            $m = Merge-Whitelist -Path $tmp
            $m.Count | Should -Be 1
            $m[0].DeviceId | Should -Be 'USB\VID_0951&PID_1666'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    It 'treats lowercase windows form as invalid (format mismatch)' {
        $tmp = Join-Path $env:TEMP ([guid]::NewGuid()) + '.txt'
        try {
            Set-Content -LiteralPath $tmp -Value @('vid_0951&pid_1666') -Encoding UTF8
            $m = Merge-Whitelist -Path $tmp
            $m.Count | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

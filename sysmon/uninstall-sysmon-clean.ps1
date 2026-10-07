#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = "Stop"

$SysmonInstallDir = "C:\Program Files (x86)\Sysmon"
$LegacySysmonExe  = "C:\Program Files (x86)\Sysmon64.exe"

$Candidates = @(
    (Join-Path $SysmonInstallDir "Sysmon64.exe"),
    (Join-Path $SysmonInstallDir "Sysmon.exe"),
    $LegacySysmonExe,
    "C:\Windows\Sysmon64.exe",
    "C:\Windows\Sysmon.exe"
)

$SysmonExe = $Candidates |
    Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1

Write-Host "=== Wazuh Sysmon Clean Uninstall ===" -ForegroundColor Cyan

$Service = Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue

if ($Service) {
    Write-Host "Sysmon64 service found: $($Service.Status)"

    if ($SysmonExe) {
        Write-Host "Uninstalling Sysmon using: $SysmonExe"
        & $SysmonExe -u
        $ExitCode = $LASTEXITCODE

        if ($ExitCode -ne 0) {
            throw "Sysmon uninstall failed. ExitCode=$ExitCode"
        }
    }
    else {
        Write-Warning "Sysmon64 service exists but Sysmon executable was not found."
        Write-Warning "Attempting service stop/removal is skipped to avoid unsafe manual driver/service cleanup."
        throw "Sysmon executable not found while Sysmon64 service exists."
    }
}
else {
    Write-Host "Sysmon64 service not found. Sysmon may already be uninstalled."
}

Start-Sleep -Seconds 2

$RemainingService = Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue

if ($RemainingService) {
    throw "Sysmon64 service still exists after uninstall."
}

# Remove only files/directories belonging to this Sysmon deployment.
$PathsToRemove = @(
    $SysmonInstallDir,
    $LegacySysmonExe
)

foreach ($Path in $PathsToRemove) {
    if (Test-Path -LiteralPath $Path) {
        if ($PSCmdlet.ShouldProcess($Path, "Remove")) {
            Remove-Item -LiteralPath $Path -Recurse -Force
            Write-Host "Removed: $Path"
        }
    }
}

# Remove old local Sysmon configuration files if they exist in the known deployment directory.
$OldConfigPaths = @(
    "C:\Program Files (x86)\Sysmon\sysmon-tuned.xml",
    "C:\Program Files (x86)\Sysmon\custom-sysmon-tuned.xml"
)

foreach ($Config in $OldConfigPaths) {
    if (Test-Path -LiteralPath $Config) {
        if ($PSCmdlet.ShouldProcess($Config, "Remove old Sysmon configuration")) {
            Remove-Item -LiteralPath $Config -Force
            Write-Host "Removed old config: $Config"
        }
    }
}

Write-Host ""
Write-Host "Sysmon clean uninstall completed successfully." -ForegroundColor Green
Write-Host "The Wazuh agent shared configuration was NOT modified."
Write-Host "The following source file was intentionally preserved:"
Write-Host "C:\Program Files (x86)\ossec-agent\shared\custom-sysmon-tuned.xml"

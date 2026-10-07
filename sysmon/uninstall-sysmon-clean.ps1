#requires -RunAsAdministrator
param()

$ErrorActionPreference = "Stop"

$SysmonInstallDir = "C:\Program Files (x86)\Sysmon"
$LegacySysmonExe  = "C:\Program Files (x86)\Sysmon64.exe"

Write-Host "=== Wazuh Sysmon Clean Uninstall ===" -ForegroundColor Cyan

function Remove-PathWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $true
    }

    for ($i = 1; $i -le 5; $i++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            Write-Host "Removed: $Path" -ForegroundColor Green
            return $true
        }
        catch {
            Write-Warning "Removal attempt $i failed for $Path : $($_.Exception.Message)"
            Start-Sleep -Seconds 2
        }
    }

    # Schedule deletion after this PowerShell process exits.
    # This handles a Sysmon executable that is still briefly locked.
    $escapedPath = $Path.Replace("'", "''")
    $DeleteCommand = "Start-Sleep -Seconds 3; Remove-Item -LiteralPath '$escapedPath' -Recurse -Force -ErrorAction SilentlyContinue"
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile",
        "-NonInteractive",
        "-WindowStyle", "Hidden",
        "-Command", $DeleteCommand
    ) -WindowStyle Hidden | Out-Null

    Write-Host "Scheduled delayed removal: $Path" -ForegroundColor Yellow
    return $false
}

# Find Sysmon executable before uninstall.
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

$Service = Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue

if ($Service) {
    Write-Host "Sysmon64 service found: $($Service.Status)"

    if (-not $SysmonExe) {
        throw "Sysmon64 service exists but Sysmon executable was not found."
    }

    Write-Host "Uninstalling Sysmon using: $SysmonExe"

    & $SysmonExe -u
    $ExitCode = $LASTEXITCODE

    if ($ExitCode -ne 0) {
        throw "Sysmon uninstall failed. ExitCode=$ExitCode"
    }

    Start-Sleep -Seconds 3
}
else {
    Write-Host "Sysmon64 service not found. Continuing filesystem cleanup."
}

# Verify service is gone.
$RemainingService = Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue
if ($RemainingService) {
    throw "Sysmon64 service still exists after uninstall."
}

# Remove every known Sysmon deployment location.
$PathsToRemove = @(
    $SysmonInstallDir,
    $LegacySysmonExe,
    "C:\Windows\Sysmon64.exe",
    "C:\Windows\Sysmon.exe"
)

foreach ($Path in $PathsToRemove) {
    [void](Remove-PathWithRetry -Path $Path)
}

Write-Host ""
Write-Host "Sysmon clean uninstall completed." -ForegroundColor Green
Write-Host "Wazuh shared configuration was NOT modified."
Write-Host "Preserved:"
Write-Host "C:\Program Files (x86)\ossec-agent\shared\custom-sysmon-tuned.xml"

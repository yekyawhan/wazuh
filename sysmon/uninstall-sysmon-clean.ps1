#requires -RunAsAdministrator
[CmdletBinding()]
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

        # Sysmon can return success while leaving the executable in C:\Windows
        # because the uninstall process may still hold the file briefly.
        if ($ExitCode -ne 0) {
            throw "Sysmon uninstall failed. ExitCode=$ExitCode"
        }
    }
    else {
        throw "Sysmon64 service exists but Sysmon executable was not found."
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

function Remove-PathSafely {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Write-Host "Removed: $Path"
        return
    }
    catch {
        Write-Warning "Normal removal failed: $Path"
        Write-Warning $_.Exception.Message
    }

    # If Sysmon left a locked executable, schedule deletion after this
    # PowerShell process exits. This avoids failing the cleanup just because
    # the uninstall process briefly retains a file handle.
    if ((Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue) -is [System.IO.FileInfo]) {
        $DeleteCommand = "Start-Sleep -Seconds 2; Remove-Item -LiteralPath '$Path' -Force -ErrorAction SilentlyContinue"
        Start-Process -FilePath "powershell.exe" -ArgumentList @(
            "-NoProfile",
            "-NonInteractive",
            "-WindowStyle", "Hidden",
            "-Command", $DeleteCommand
        ) -WindowStyle Hidden | Out-Null

        Write-Host "Scheduled removal after the current process exits: $Path"
    }
}

# Remove Sysmon files/directories from all known deployment locations.
$PathsToRemove = @(
    $SysmonInstallDir,
    $LegacySysmonExe,
    "C:\Windows\Sysmon64.exe",
    "C:\Windows\Sysmon.exe"
)

foreach ($Path in $PathsToRemove) {
    Remove-PathSafely -Path $Path
}

Write-Host ""
Write-Host "Sysmon clean uninstall completed successfully." -ForegroundColor Green
Write-Host "The Wazuh agent shared configuration was NOT modified."
Write-Host "Preserved source:"
Write-Host "C:\Program Files (x86)\ossec-agent\shared\custom-sysmon-tuned.xml"

param(
    [switch]$Uninstall,
    [switch]$ForceReinstall,
    [string]$configUrl = "https://raw.githubusercontent.com/yekyawhan/wazuh/refs/heads/git-home/sysmon/config/custom-sysmon-tuned.xml"
)

function Test-Admin {
    $currentUser = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host "[!] Not running as Administrator. Relaunching..." -ForegroundColor Yellow
    Start-Process powershell "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$SysmonDir = "${env:ProgramFiles(x86)}\Sysmon"
$TempDir = "$env:TEMP\SysmonInstall"
$ZipUrl = "https://download.sysinternals.com/files/Sysmon.zip"
$ZipFile = "$TempDir\Sysmon.zip"
$LogFile = "$SysmonDir\install.log"

$InstallAttempts = 3
$InstallCooldownSeconds = 5

function Log($msg) {
    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$time] $msg"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Cleanup {
    if (Test-Path $TempDir) {
        Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Download($url, $out) {
    Log "Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
}

function Test-SysmonService {
    $svc = Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue
    return ($svc -and $svc.Status -eq "Running")
}

function Verify {
    Log "Verifying service..."
    $svc = Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue

    if ($svc -and $svc.Status -eq "Running") {
        Log "Sysmon64 service is RUNNING"
    } else {
        Log "ERROR: Sysmon64 service is NOT running"
        return $false
    }

    Log "Checking event log..."
    $log = Get-WinEvent -ListLog "Microsoft-Windows-Sysmon/Operational" -ErrorAction SilentlyContinue

    if ($log -and $log.IsEnabled) {
        Log "Sysmon event log active"
    } else {
        Log "ERROR: Sysmon event log is not active"
        return $false
    }

    Log "DONE"
    return $true
}

function Install-Sysmon {

    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    New-Item -ItemType Directory -Path $SysmonDir -Force | Out-Null

    Download $ZipUrl $ZipFile
    Log "Extracting Sysmon..."
    Expand-Archive -Path $ZipFile -DestinationPath $TempDir -Force

    $sysmonExe = Get-ChildItem -Path $TempDir -Recurse -Filter "Sysmon64.exe" | Select-Object -First 1
    if (-not $sysmonExe) {
        throw "Sysmon64.exe not found!"
    }

    Copy-Item $sysmonExe.FullName $SysmonDir -Force

    $configPath = "$SysmonDir\sysmonconfig-export.xml"
    Download $configUrl $configPath

    if ((Get-Item $configPath).Length -eq 0) {
        throw "Config file is EMPTY."
    }

    Set-Location $SysmonDir

    $service = Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue

    if ($service -and -not $ForceReinstall) {
        if ($service.Status -eq "Running") {
            Log "Sysmon already installed and running. Updating config..."
            & .\Sysmon64.exe -c $configPath
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) {
                throw "Sysmon configuration update failed with exit code $exitCode."
            }

            Log "Cooling down $InstallCooldownSeconds seconds after config update..."
            Start-Sleep -Seconds $InstallCooldownSeconds
        }
        else {
            Log "Sysmon service exists but is not running. Repairing installation..."
            & .\Sysmon64.exe -u force
            Start-Sleep -Seconds 3
            $service = $null
        }
    }

    if (-not $service -or $ForceReinstall) {

        if ($ForceReinstall -and (Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue)) {
            Log "ForceReinstall requested. Removing existing Sysmon..."
            & .\Sysmon64.exe -u force
            Start-Sleep -Seconds 3
        }

        for ($attempt = 1; $attempt -le $InstallAttempts; $attempt++) {

            Log "Installing Sysmon (attempt $attempt/$InstallAttempts)..."

            & .\Sysmon64.exe -i $configPath -accepteula
            $exitCode = $LASTEXITCODE

            Log "Sysmon installer exit code: $exitCode"
            Log "Cooling down $InstallCooldownSeconds seconds for driver/service/event manifest initialization..."
            Start-Sleep -Seconds $InstallCooldownSeconds

            if (Test-SysmonService) {
                Log "Sysmon64 service is running after attempt $attempt."
                break
            }

            if ($attempt -lt $InstallAttempts) {
                Log "Sysmon64 is not running yet. Preparing retry..."

                $existingService = Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue
                if ($existingService) {
                    Log "Removing incomplete Sysmon installation before retry..."
                    & .\Sysmon64.exe -u force
                    Start-Sleep -Seconds 3
                }
            }
            else {
                throw "Sysmon installation failed after $InstallAttempts attempts."
            }
        }
    }

    if (-not (Verify)) {
        throw "Sysmon installation verification failed."
    }
}

function Uninstall-Sysmon {
    Log "Uninstalling Sysmon..."
    $exe = Get-ChildItem $SysmonDir -Filter "Sysmon64.exe" -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($exe) {
        & $exe.FullName -u force
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            throw "Sysmon uninstall failed with exit code $exitCode."
        }

        Log "Sysmon removed."
    } else {
        Log "Sysmon64.exe not found."
    }
}

try {
    Log "===== Sysmon Installer Started ====="

    if ($Uninstall) {
        Uninstall-Sysmon
        Cleanup
        Log "===== Uninstall Completed Successfully ====="
        exit 0
    }

    Install-Sysmon
    Cleanup

    Log "===== Completed Successfully ====="
    exit 0
}
catch {
    Log "ERROR: $_"
    Cleanup
    Log "===== Installation FAILED ====="
    exit 1
}

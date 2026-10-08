#requires -Version 5.1
$ErrorActionPreference = "Stop"

$AgentRoot = "C:\Program Files (x86)\ossec-agent"
$SourceConfig = Join-Path $AgentRoot "shared\custom-sysmon-tuned.xml"
$LogDir = Join-Path $AgentRoot "logs"
$LogFile = Join-Path $LogDir "sysmon-update.log"
$SysmonDir = "C:\Program Files (x86)\Sysmon"
$TargetConfig = Join-Path $SysmonDir "custom-sysmon-tuned.xml"
$InstallerUrl = "https://github.com/yekyawhan/wazuh/raw/refs/heads/git-home/sysmon/install-sysmon-custom.ps1"
$InstallerPath = Join-Path $env:TEMP "install-sysmon-custom.ps1"

$SysmonCandidates = @(
    "C:\Program Files (x86)\Sysmon\Sysmon64.exe",
    "C:\Program Files\Sysmon\Sysmon64.exe",
    "C:\Program Files (x86)\Sysmon64.exe",
    "C:\Windows\Sysmon64.exe",
    "C:\Windows\Sysmon.exe"
)

$MutexName = "Global\Wazuh-Sysmon-Config-Update"
$Mutex = $null
$MutexOwned = $false

function Write-UpdateLog {
    param([ValidateSet("INFO","SUCCESS","WARNING","ERROR","SYSMON")][string]$Level,[string]$Message)

    try {
        if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }
    } catch {}

    $Line = "{0} [{1}] [{2}] {3}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $env:COMPUTERNAME, $Message
    Write-Output $Line
    try { Add-Content -LiteralPath $LogFile -Value $Line -Encoding UTF8 } catch {}
}

function Find-SysmonExecutable {
    foreach ($Candidate in $SysmonCandidates) {
        if (Test-Path -LiteralPath $Candidate -PathType Leaf) { return $Candidate }
    }
    return $null
}

function Test-SysmonRunning {
    $Service = Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue
    return ($null -ne $Service -and $Service.Status -eq "Running")
}

function Test-XmlFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "XML file not found: $Path" }
    $Xml = New-Object System.Xml.XmlDocument
    $Xml.XmlResolver = $null
    $Xml.Load($Path)
    return $true
}

function Test-FileContentEqual {
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Target)
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) { return $false }
    return ((Get-Content -LiteralPath $Source -Raw) -ceq (Get-Content -LiteralPath $Target -Raw))
}

function Install-SysmonIfMissing {
    param([ref]$SysmonExe)

    if ($SysmonExe.Value) { return $false }

    Write-UpdateLog -Level "WARNING" -Message "Sysmon executable not found. Starting automatic Sysmon installation."

    try {
        Write-UpdateLog -Level "INFO" -Message "Downloading Sysmon installer: $InstallerUrl"
        Invoke-WebRequest -Uri $InstallerUrl -OutFile $InstallerPath -UseBasicParsing

        if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
            throw "Installer download did not produce a file."
        }

        Write-UpdateLog -Level "INFO" -Message "Running Sysmon installer."

        $ArgumentList = @("-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File",$InstallerPath)
        $Process = Start-Process -FilePath "powershell.exe" -ArgumentList $ArgumentList -Wait -PassThru -WindowStyle Hidden
        $ExitCode = $Process.ExitCode

        Write-UpdateLog -Level "INFO" -Message "Sysmon installer exited with code: $ExitCode"

        if ($ExitCode -ne 0) { throw "Sysmon installer failed with exit code $ExitCode." }

        Start-Sleep -Seconds 5
        $SysmonExe.Value = Find-SysmonExecutable

        if (-not $SysmonExe.Value) { throw "Sysmon installation completed but Sysmon64.exe was not found." }
        if (-not (Test-SysmonRunning)) { throw "Sysmon64.exe was installed but Sysmon64 service is not running." }

        Write-UpdateLog -Level "SUCCESS" -Message "Sysmon installed successfully: $($SysmonExe.Value)"
        return $true
    }
    finally {
        Remove-Item -LiteralPath $InstallerPath -Force -ErrorAction SilentlyContinue
    }
}

function Deploy-Configuration {
    if (-not (Test-Path -LiteralPath $SysmonDir -PathType Container)) {
        New-Item -ItemType Directory -Path $SysmonDir -Force | Out-Null
    }

    if (Test-FileContentEqual -Source $SourceConfig -Target $TargetConfig) {
        Write-UpdateLog -Level "INFO" -Message "Target Sysmon configuration is already identical to source. No file deployment required."
        return $false
    }

    $TempConfig = "$TargetConfig.tmp"
    Remove-Item -LiteralPath $TempConfig -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $SourceConfig -Destination $TempConfig -Force
    Test-XmlFile -Path $TempConfig | Out-Null
    Move-Item -LiteralPath $TempConfig -Destination $TargetConfig -Force
    Test-XmlFile -Path $TargetConfig | Out-Null

    Write-UpdateLog -Level "SUCCESS" -Message "Sysmon configuration deployed successfully: $TargetConfig"
    return $true
}

function Apply-SysmonConfiguration {
    param([Parameter(Mandatory)][string]$SysmonExe)

    Write-UpdateLog -Level "INFO" -Message "Applying Sysmon configuration using: $SysmonExe -c $TargetConfig"

    $OutputDir = Join-Path $LogDir "sysmon-command"
    if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    $Stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $StdOutFile = Join-Path $OutputDir "sysmon-$Stamp.out.log"
    $StdErrFile = Join-Path $OutputDir "sysmon-$Stamp.err.log"

    $ArgumentList = @("-c",$TargetConfig)
    $Process = Start-Process -FilePath $SysmonExe -ArgumentList $ArgumentList -WorkingDirectory (Split-Path -Parent $SysmonExe) -RedirectStandardOutput $StdOutFile -RedirectStandardError $StdErrFile -Wait -PassThru -WindowStyle Hidden
    $ExitCode = $Process.ExitCode

    if (Test-Path -LiteralPath $StdOutFile) {
        Get-Content -LiteralPath $StdOutFile -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_ -and $_.Trim()) { Write-UpdateLog -Level "SYSMON" -Message $_ }
        }
    }

    if (Test-Path -LiteralPath $StdErrFile) {
        Get-Content -LiteralPath $StdErrFile -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_ -and $_.Trim()) { Write-UpdateLog -Level "SYSMON" -Message $_ }
        }
    }

    Write-UpdateLog -Level "INFO" -Message "Sysmon process exited with code: $ExitCode"
    if ($ExitCode -ne 0) { throw "Sysmon configuration command failed with exit code $ExitCode." }

    Write-UpdateLog -Level "SUCCESS" -Message "Sysmon configuration APPLY completed successfully."
}

function Main {
    Write-UpdateLog -Level "INFO" -Message "===== Sysmon configuration update started ====="

    if (-not (Test-Path -LiteralPath $SourceConfig -PathType Leaf)) {
        throw "Source configuration not found: $SourceConfig"
    }

    Test-XmlFile -Path $SourceConfig | Out-Null
    Write-UpdateLog -Level "INFO" -Message "Source configuration found and XML syntax validation successful."

    $SysmonExe = Find-SysmonExecutable
    $InstalledNow = Install-SysmonIfMissing -SysmonExe ([ref]$SysmonExe)

    if (-not $SysmonExe) { throw "Sysmon executable could not be located." }
    Write-UpdateLog -Level "INFO" -Message "Sysmon executable detected: $SysmonExe"

    if (-not (Test-SysmonRunning)) { throw "Sysmon64 service is not running." }

    $ConfigurationChanged = Deploy-Configuration

    if ($InstalledNow -or $ConfigurationChanged) {
        Apply-SysmonConfiguration -SysmonExe $SysmonExe
    } else {
        Write-UpdateLog -Level "INFO" -Message "Configuration unchanged and Sysmon service is already running. Skipping unnecessary Sysmon apply."
    }

    $Service = Get-Service -Name "Sysmon64" -ErrorAction Stop
    Write-UpdateLog -Level "SUCCESS" -Message "Sysmon64 service verification successful. Status=$($Service.Status) StartType=$($Service.StartType)"
    Write-UpdateLog -Level "SUCCESS" -Message "===== Sysmon configuration update completed successfully ====="
    return 0
}

try {
    $Mutex = New-Object System.Threading.Mutex($false,$MutexName)
    try { $MutexOwned = $Mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] {
        $MutexOwned = $true
        Write-UpdateLog -Level "WARNING" -Message "Previous Sysmon update process ended unexpectedly. Reusing abandoned mutex."
    }

    if (-not $MutexOwned) {
        Write-UpdateLog -Level "WARNING" -Message "Another Sysmon update is already running. Exiting without starting a second instance."
        exit 0
    }

    $ExitCode = Main
    exit $ExitCode
}
catch {
    Write-UpdateLog -Level "ERROR" -Message "Sysmon update failed: $($_.Exception.Message)"
    Write-UpdateLog -Level "ERROR" -Message "===== Sysmon configuration update FAILED ====="
    exit 1
}
finally {
    if ($Mutex -and $MutexOwned) {
        try { $Mutex.ReleaseMutex() } catch {}
        $Mutex.Dispose()
    }
}

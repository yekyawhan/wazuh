# Logger.psm1 — Production logging
# Levels: INFO, WARNING, ERROR, DEBUG, AUDIT
# Targets: file (rolling) + Windows Event Log (errors only)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Internal state
$script:LogLevelOrder = @{ DEBUG = 0; INFO = 1; AUDIT = 1; WARNING = 2; ERROR = 3 }
$script:CurrentLevel  = 'INFO'
$script:Initialized   = $false
$script:LogFilePath   = $null
$script:EventSource   = $null
$script:EventLogName  = 'Application'
$script:MaxLogBytes    = 5MB
$script:MaxLogBackups  = 3

<#
.SYNOPSIS
    Set up the logging target.

.DESCRIPTION
    Creates the log directory, resolves the log file path, sets the minimum
    level, and (optionally) registers a Windows Event Log source. Must be
    called once before any Write-Log* function.

.PARAMETER LogDir
    Directory that will hold the log file.

.PARAMETER LogFileName
    File name of the log (e.g. usb-sync.log).

.PARAMETER Level
    Minimum level to emit: DEBUG, INFO, AUDIT, WARNING, ERROR.

.PARAMETER EventSource
    If set, ERROR entries are also written to the Application event log.

.PARAMETER EventLogName
    Event log name for the source (default: Application).

.EXAMPLE
    Initialize-Logger -LogDir $UsbSync.LogDir -LogFileName $UsbSync.LogFile -EventSource $UsbSync.EventLogSource
#>
function Initialize-Logger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogDir,
        [Parameter(Mandatory)][string]$LogFileName,
        [string]$Level = 'INFO',
        [string]$EventSource,
        [string]$EventLogName = 'Application'
    )

    if (-not (Test-Path -LiteralPath $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    $script:LogFilePath  = Join-Path $LogDir $LogFileName
    $script:CurrentLevel = $Level.ToUpper()
    $script:EventLogName = $EventLogName
    if ($EventSource) {
        $script:EventSource = $EventSource
        if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
            try { New-EventLog -LogName $EventLogName -Source $EventSource -ErrorAction Stop }
            catch { $script:EventSource = $null }  # non-fatal
        }
    }
    $script:Initialized = $true
    return $script:LogFilePath
}

function Write-LogLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('DEBUG','INFO','AUDIT','WARNING','ERROR')][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [string]$Component = 'Sync'
    )
    if (-not $script:Initialized) { return }
    if ($script:LogLevelOrder[$Level] -lt $script:LogLevelOrder[$script:CurrentLevel]) { return }

    $ts  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $tag = "[$Component]"
    $line = "$ts $Level $tag $Message"

    try {
        if ($script:MaxLogBytes -gt 0 -and (Test-Path -LiteralPath $script:LogFilePath)) {
            $sz = (Get-Item -LiteralPath $script:LogFilePath).Length
            if ($sz -ge $script:MaxLogBytes) { Invoke-LogRotation }
        }
        Add-Content -LiteralPath $script:LogFilePath -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch { return }  # never let logging crash the caller

    if ($Level -eq 'ERROR' -and $script:EventSource) {
        try { Write-EventLog -LogName $script:EventLogName -Source $script:EventSource -EventId 1000 -EntryType Error -Message $line -ErrorAction Stop }
        catch { }
    }
}

# Public API
<#
.SYNOPSIS
    Configure log file rotation.

.DESCRIPTION
    When the active log exceeds MaxLogBytes, it is renamed to
    <name>.1.log, previous .1 shifts to .2, etc., keeping MaxLogBackups.

.PARAMETER MaxBytes
    Size threshold in bytes. Set 0 to disable rotation.

.PARAMETER MaxBackups
    Number of rotated files to retain.
#>
function Set-LogRotation {
    [CmdletBinding()]
    param([int]$MaxBytes = 5MB, [int]$MaxBackups = 3)
    $script:MaxLogBytes   = $MaxBytes
    $script:MaxLogBackups = $MaxBackups
}

function Invoke-LogRotation {
    [CmdletBinding()]
    param()
    try {
        for ($i = $script:MaxLogBackups - 1; $i -ge 1; $i--) {
            $src = "$script:LogFilePath.$i"
            $dst = "$script:LogFilePath.$($i + 1)"
            if (Test-Path -LiteralPath $src) { Move-Item -LiteralPath $src -Destination $dst -Force }
        }
        Move-Item -LiteralPath $script:LogFilePath -Destination "$script:LogFilePath.1" -Force
    } catch { }
}

function Write-LogInfo    { [CmdletBinding()] param([string]$Message,[string]$Component='Sync') Write-LogLine -Level INFO    -Message $Message -Component $Component }
function Write-LogWarning { [CmdletBinding()] param([string]$Message,[string]$Component='Sync') Write-LogLine -Level WARNING -Message $Message -Component $Component }
function Write-LogError   { [CmdletBinding()] param([string]$Message,[string]$Component='Sync') Write-LogLine -Level ERROR   -Message $Message -Component $Component }
function Write-LogDebug   { [CmdletBinding()] param([string]$Message,[string]$Component='Sync') Write-LogLine -Level DEBUG   -Message $Message -Component $Component }
function Write-LogAudit   { [CmdletBinding()] param([string]$Message,[string]$Component='Sync') Write-LogLine -Level AUDIT   -Message $Message -Component $Component }

Export-ModuleMember -Function @(
    'Initialize-Logger',
    'Set-LogRotation',
    'Write-LogInfo','Write-LogWarning','Write-LogError','Write-LogDebug','Write-LogAudit'
)

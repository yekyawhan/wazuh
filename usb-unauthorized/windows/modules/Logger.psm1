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

    try { Add-Content -LiteralPath $script:LogFilePath -Value $line -Encoding UTF8 -ErrorAction Stop }
    catch { return }  # never let logging crash the caller

    if ($Level -eq 'ERROR' -and $script:EventSource) {
        try { Write-EventLog -LogName $script:EventLogName -Source $script:EventSource -EventId 1000 -EntryType Error -Message $line -ErrorAction Stop }
        catch { }
    }
}

# Public API
function Write-LogInfo    { [CmdletBinding()] param([string]$Message,[string]$Component='Sync') Write-LogLine -Level INFO    -Message $Message -Component $Component }
function Write-LogWarning { [CmdletBinding()] param([string]$Message,[string]$Component='Sync') Write-LogLine -Level WARNING -Message $Message -Component $Component }
function Write-LogError   { [CmdletBinding()] param([string]$Message,[string]$Component='Sync') Write-LogLine -Level ERROR   -Message $Message -Component $Component }
function Write-LogDebug   { [CmdletBinding()] param([string]$Message,[string]$Component='Sync') Write-LogLine -Level DEBUG   -Message $Message -Component $Component }
function Write-LogAudit   { [CmdletBinding()] param([string]$Message,[string]$Component='Sync') Write-LogLine -Level AUDIT   -Message $Message -Component $Component }

Export-ModuleMember -Function @(
    'Initialize-Logger',
    'Write-LogInfo','Write-LogWarning','Write-LogError','Write-LogDebug','Write-LogAudit'
)

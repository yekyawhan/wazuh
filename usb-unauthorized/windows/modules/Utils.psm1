# Utils.psm1 — Shared helpers
# Admin check, retry, path/registry guards

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Returns true if the current process is elevated.

.DESCRIPTION
    Checks the current Windows identity against the Builtin Administrator role.
    Sync/install/uninstall require elevation to write HKLM.

.EXAMPLE
    if (-not (Test-IsAdministrator)) { throw 'Admin required' }
#>
function Test-IsAdministrator {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr  = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

<#
.SYNOPSIS
    Run a scriptblock with bounded retries.

.DESCRIPTION
    Executes ScriptBlock; on exception retries up to MaxRetries times with
    DelaySeconds between attempts, logging each failure. Re-throws on the
    final attempt.

.PARAMETER ScriptBlock
    The work to perform.

.PARAMETER MaxRetries
    Total attempts before giving up (default 3).

.PARAMETER DelaySeconds
    Seconds to wait between attempts (default 2).

.PARAMETER OperationName
    Label used in the retry log line.

.EXAMPLE
    $cfg = Invoke-WithRetry -ScriptBlock { Get-Content $path } -OperationName 'Read config'
#>
function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$MaxRetries = 3,
        [int]$DelaySeconds = 2,
        [string]$OperationName = 'Operation'
    )
    $attempt = 0
    while ($true) {
        $attempt++
        try { return & $ScriptBlock }
        catch {
            if ($attempt -ge $MaxRetries) { throw }
            Write-LogWarning "$OperationName failed (attempt $attempt/$MaxRetries): $($_.Exception.Message). Retrying in ${DelaySeconds}s"
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

<#
.SYNOPSIS
    Returns true if the path can be created and written to.

.DESCRIPTION
    Creates the directory if missing, writes a temp file, then deletes it.
    Used by the installer to fail fast when the log/state dir is not writable.

.PARAMETER Path
    Directory to test.

.EXAMPLE
    if (-not (Test-PathWritable $UsbSync.LogDir)) { throw 'Log dir not writable' }
#>
function Test-PathWritable {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
        $tmp = Join-Path $Path (".writetest_{0}" -f [guid]::NewGuid())
        [IO.File]::WriteAllText($tmp, 'ok')
        Remove-Item -LiteralPath $tmp -Force
        return $true
    } catch { return $false }
}

Export-ModuleMember -Function @(
    'Test-IsAdministrator',
    'Invoke-WithRetry',
    'Test-PathWritable'
)

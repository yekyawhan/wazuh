# Utils.psm1 — Shared helpers
# Admin check, retry, path/registry guards

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr  = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

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

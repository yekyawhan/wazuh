# Parser.psm1 — Whitelist parser
# Reads usb_whitelist.txt from Wazuh shared dir.
# Supports both formats per-line:
#   USB\VID_0951&PID_1666          (Windows-style, native registry form)
#   0951:1666                       (Linux-style, manager-friendly)
# Returns objects: { OriginalLine, DeviceId, SourceFormat, Valid, Reason }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Internal: detect which format a line is in
<#
.SYNOPSIS
    Detects whether a whitelist line is Windows- or Linux-formatted.

.PARAMETER Line
    A single whitelist line (leading/trailing spaces allowed).

.OUTPUTS
    [string] 'Windows', 'Linux', or $null if unrecognized.
#>
function Resolve-DeviceFormat {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Line)
    $t = $Line.Trim()
    if ($t -match '^USB\\VID_[0-9A-Fa-f]{4}&PID_[0-9A-Fa-f]{4}$') { return 'Windows' }
    if ($t -match '^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}$')               { return 'Linux' }
    return $null
}

# Internal: convert Linux "0951:1666" to Windows "USB\VID_0951&PID_1666"
<#
.SYNOPSIS
    Converts a Linux "VID:PID" string to the Windows registry device ID form.

.PARAMETER LinuxId
    e.g. "0951:1666" or "951:166" (short values are zero-padded).

.OUTPUTS
    [string] e.g. "USB\VID_0951&PID_1666", or $null if malformed.
#>
function ConvertTo-WindowsDeviceId {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$LinuxId)
    $parts = $LinuxId.Split(':')
    if ($parts.Count -ne 2) { return $null }
    $vid = $parts[0].ToUpper().PadLeft(4,'0')
    $pid = $parts[1].ToUpper().PadLeft(4,'0')
    return "USB\VID_$vid&PID_$pid"
}

<#
.SYNOPSIS
    Reads and validates a usb_whitelist.txt file.

.DESCRIPTION
    Supports both "USB\VID_xxxx&PID_xxxx" (Windows) and "xxxx:xxxx" (Linux)
    formats per line. Comments (#) and blank lines are skipped. Each line is
    returned as an object with a Valid flag and reason.

.PARAMETER Path
    Full path to the whitelist file.

.OUTPUTS
    [object[]] each: { OriginalLine, DeviceId, SourceFormat, Valid, Reason, LineNumber }
#>
function Read-UsbWhitelist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    $results = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-LogWarning "Whitelist file not found: $Path"
        return $results
    }
    $lineNo = 0
    foreach ($raw in (Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop)) {
        $lineNo++
        $line = $raw.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith('#'))                 { continue }

        $fmt = Resolve-DeviceFormat -Line $line
        if (-not $fmt) {
            $results.Add([pscustomobject]@{
                OriginalLine = $raw; DeviceId = $null; SourceFormat = 'Invalid'
                Valid = $false; Reason = "line $lineNo — unrecognized format"; LineNumber = $lineNo
            })
            continue
        }
        $devId = if ($fmt -eq 'Windows') { $line } else { ConvertTo-WindowsDeviceId -LinuxId $line }
        if (-not $devId) {
            $results.Add([pscustomobject]@{
                OriginalLine = $raw; DeviceId = $null; SourceFormat = $fmt
                Valid = $false; Reason = "line $lineNo — convert failed"; LineNumber = $lineNo
            })
            continue
        }
        $results.Add([pscustomobject]@{
            OriginalLine = $raw; DeviceId = $devId; SourceFormat = $fmt
            Valid = $true; Reason = $null; LineNumber = $lineNo
        })
    }
    return $results
}

<#
.SYNOPSIS
    Returns only the valid entries from a whitelist file.

.PARAMETER Path
    Full path to the whitelist file.
#>
function Get-ValidWhitelist {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return @(Read-UsbWhitelist -Path $Path | Where-Object { $_.Valid })
}

<#
.SYNOPSIS
    Reads a whitelist and returns deduplicated valid device IDs.

.DESCRIPTION
    Linux and Windows forms of the same device collapse to one entry because
    both normalize to the Windows registry device ID.

.PARAMETER Path
    Full path to the whitelist file.

.OUTPUTS
    [object[]] unique valid entries.
#>
function Merge-Whitelist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    $valid = Get-ValidWhitelist -Path $Path
    $unique = $valid | Group-Object -Property DeviceId | ForEach-Object { $_.Group[0] }
    return @($unique)
}

Export-ModuleMember -Function @(
    'Read-UsbWhitelist',
    'Get-ValidWhitelist',
    'Merge-Whitelist'
)

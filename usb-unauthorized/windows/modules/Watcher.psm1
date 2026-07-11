# Watcher.psm1 — FileSystemWatcher with debounce
# Monitors Wazuh shared\usb_whitelist.txt. On change → debounce → trigger sync.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Watcher = $null
$script:DebounceTimer = $null
$script:DebounceSeconds = 3

function Start-UsbWhitelistWatcher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][scriptblock]$OnChange
    )
    Stop-UsbWhitelistWatcher

    $dir  = Split-Path -Path $Path -Parent
    $name = Split-Path -Path $Path -Leaf
    if (-not (Test-Path -LiteralPath $dir)) {
        Write-LogWarning "Watcher directory missing: $dir"
        return $false
    }

    $script:Watcher = New-Object System.IO.FileSystemWatcher -Property @{
        Path              = $dir
        Filter            = $name
        NotifyFilter      = [System.IO.NotifyFilters]::FileName,
                            [System.IO.NotifyFilters]::LastWrite,
                            [System.IO.NotifyFilters]::Size
        EnableRaisingEvents = $true
    }
    $handler = {
        $sender = $Event.MessageData.Sender
        $cb     = $Event.MessageData.Callback
        if ($script:DebounceTimer) { $script:DebounceTimer.Dispose() }
        $script:DebounceTimer = New-Object System.Threading.Timer(
            [System.Threading.TimerCallback]{
                try { & $cb } catch { Write-LogError "Watcher callback failed: $($_.Exception.Message)" }
            },
            $null,
            [int]($script:DebounceSeconds * 1000),
            [System.Threading.Timeout]::Infinite
        )
    }
    Register-ObjectEvent -InputObject $script:Watcher -EventName Changed -Action $handler -MessageData @{ Sender = $script:Watcher; Callback = $OnChange } | Out-Null
    Register-ObjectEvent -InputObject $script:Watcher -EventName Created -Action $handler -MessageData @{ Sender = $script:Watcher; Callback = $OnChange } | Out-Null
    Register-ObjectEvent -InputObject $script:Watcher -EventName Renamed -Action $handler -MessageData @{ Sender = $script:Watcher; Callback = $OnChange } | Out-Null

    Write-LogInfo "Watcher started on $Path (debounce ${script:DebounceSeconds}s)"
    return $true
}

function Stop-UsbWhitelistWatcher {
    [CmdletBinding()]
    param()
    if ($script:Watcher) {
        $script:Watcher.EnableRaisingEvents = $false
        $script:Watcher.Dispose()
        $script:Watcher = $null
        Get-EventSubscriber | Where-Object { $_.SourceObject -is [System.IO.FileSystemWatcher] } | Unregister-Event -Force
        Write-LogInfo "Watcher stopped."
    }
    if ($script:DebounceTimer) {
        $script:DebounceTimer.Dispose()
        $script:DebounceTimer = $null
    }
}

function Invoke-GpUpdate {
    [CmdletBinding()]
    param()
    try {
        $out = & gpupdate.exe /target:computer /force 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-LogInfo "gpupdate /force OK"
        } else {
            Write-LogWarning "gpupdate exit=$LASTEXITCODE"
        }
    } catch {
        Write-LogWarning "gpupdate not available: $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function @(
    'Start-UsbWhitelistWatcher',
    'Stop-UsbWhitelistWatcher',
    'Invoke-GpUpdate'
)

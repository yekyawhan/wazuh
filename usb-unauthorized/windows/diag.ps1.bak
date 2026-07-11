$ErrorActionPreference = 'Stop'
$bootLog = 'C:\ProgramData\Wazuh\Logs\UsbSync\diag.log'
$dir = Split-Path $bootLog -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
'' | Set-Content $bootLog

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot 'config\config.ps1')
"diag: dot-sourced config at $ScriptRoot" | Add-Content $bootLog

try { Import-Module (Join-Path $ScriptRoot 'modules\Logger.psm1')   -Force } catch { "diag: Logger import failed: $($_.Exception.Message)" | Add-Content $bootLog; exit 1 }
try { Import-Module (Join-Path $ScriptRoot 'modules\Utils.psm1')    -Force } catch { "diag: Utils import failed: $($_.Exception.Message)"  | Add-Content $bootLog; exit 1 }
try { Import-Module (Join-Path $ScriptRoot 'modules\Parser.psm1')   -Force } catch { "diag: Parser import failed: $($_.Exception.Message)" | Add-Content $bootLog; exit 1 }
try { Import-Module (Join-Path $ScriptRoot 'modules\Registry.psm1') -Force } catch { "diag: Registry import failed: $($_.Exception.Message)" | Add-Content $bootLog; exit 1 }
try { Import-Module (Join-Path $ScriptRoot 'modules\Policy.psm1')   -Force } catch { "diag: Policy import failed: $($_.Exception.Message)"   | Add-Content $bootLog; exit 1 }
try { Import-Module (Join-Path $ScriptRoot 'modules\Watcher.psm1')  -Force } catch { "diag: Watcher import failed: $($_.Exception.Message)"  | Add-Content $bootLog; exit 1 }
"diag: all modules imported" | Add-Content $bootLog

Initialize-Logger -LogDir $UsbSync.LogDir -LogFileName $UsbSync.LogFile -EventSource $UsbSync.EventLogSource
"diag: logger initialized" | Add-Content $bootLog

$wi = New-Object Security.Principal.WindowsIdentity Get-Current
"diag: identity = $($wi.Name)" | Add-Content $bootLog

$dir = Split-Path -Path (Get-UsbWhitelistPath) -Parent
"diag: whitelist dir = $dir exists=$((Test-Path $dir))" | Add-Content $bootLog

$f = Get-UsbWhitelistPath
"diag: whitelist file = $f exists=$((Test-Path $f))" | Add-Content $bootLog

$ok = Invoke-HybridUsbSync
"diag: Invoke-HybridUsbSync returned $ok" | Add-Content $bootLog
exit $(if ($ok) { 0 } else { 1 })

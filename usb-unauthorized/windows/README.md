# Wazuh Hybrid USB Sync — Windows V2

Production USB whitelist enforcement for Windows agents. Whitelist is distributed by the Wazuh Manager through `agent.conf` (shared configuration) and applied locally via Device Installation Restrictions.

Mirrors the Linux V2 implementation in `../v2/`.

---

## Features

- **Manager-pushed whitelist** — single source of truth, every agent in sync
- **Allow-list policy** — only whitelisted USB device IDs may install
- **File watcher** — whitelist change → auto re-sync within 3 seconds
- **Atomic apply** — backup → write → verify → restore on failure
- **Scheduled Task** — runs as `SYSTEM`, restarts on failure
- **Enterprise logging** — file + Windows Event Log (Application / WazuhUsbSync)
- **Idempotent** — installer + uninstaller safe to re-run
- **Pester tests** — parser + registry round-trip coverage

---

## Quick Start

### One-line install (recommended)

**Use the GitHub raw URL (always current, no CDN cache issues).** From any PowerShell (will auto-elevate):

```powershell
$iwr='https://raw.githubusercontent.com/yekyawhan/wazuh/git-home/usb-unauthorized/releases/usb-unauthorized-windows-v2.zip';$tmp=(Join-Path $env:TEMP ([guid]::NewGuid()))+'.zip';[Net.ServicePointManager]::SecurityProtocol='Tls12';iwr $iwr -OutFile $tmp -UseBasicParsing;New-Item -ItemType Directory -Path 'C:\ProgramData\Wazuh' -Force | Out-Null;Expand-Archive $tmp -DestinationPath 'C:\ProgramData\Wazuh' -Force;$ps1=Get-ChildItem -Path 'C:\ProgramData\Wazuh' -Recurse -Filter 'install_usb_sync_windows.ps1' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName;if(-not $ps1){Write-Error 'install_usb_sync_windows.ps1 not found in expanded zip';exit 1};Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$ps1
```

The one-liner **finds `install_usb_sync_windows.ps1` anywhere in the expanded tree** — works whether the zip uses a wrapper folder or not, works whether the CDN has a stale cached version or a fresh one.

If you already have an **admin** PowerShell open, drop the `Start-Process -Verb RunAs` part:

```powershell
$iwr='https://raw.githubusercontent.com/yekyawhan/wazuh/git-home/usb-unauthorized/releases/usb-unauthorized-windows-v2.zip';$tmp=(Join-Path $env:TEMP ([guid]::NewGuid()))+'.zip';[Net.ServicePointManager]::SecurityProtocol='Tls12';iwr $iwr -OutFile $tmp -UseBasicParsing;New-Item -ItemType Directory -Path 'C:\ProgramData\Wazuh' -Force | Out-Null;Expand-Archive $tmp -DestinationPath 'C:\ProgramData\Wazuh' -Force;$ps1=Get-ChildItem -Path 'C:\ProgramData\Wazuh' -Recurse -Filter 'install_usb_sync_windows.ps1' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName;if(-not $ps1){Write-Error 'install_usb_sync_windows.ps1 not found in expanded zip';exit 1};powershell -NoProfile -ExecutionPolicy Bypass -File $ps1
```

CDN alternative (jsdelivr — has ~12h cache, may serve stale):

```powershell
$iwr='https://cdn.jsdelivr.net/gh/yekyawhan/wazuh@git-home/usb-unauthorized/releases/usb-unauthorized-windows-v2.zip'
```

(substitute the `$iwr` value, then use the rest of the one-liner above)

### Install from local source

```cmd
cd windows
install.cmd
```

Auto-elevates to Administrator. First sync runs immediately.

### Uninstall

```powershell
& 'C:\ProgramData\Wazuh\usb-unauthorized-windows-v2\uninstall\uninstall_usb_sync_windows.ps1' --purge-logs
```

Or `cd windows && uninstall.cmd` from a local source tree.

---

## Whitelist Format

Wazuh Manager pushes `usb_whitelist.txt` to:

```
C:\Program Files (x86)\ossec-agent\shared\usb_whitelist.txt
```

Both formats supported per line. Comments (`#`) and blank lines ignored.

```text
# Windows-style
USB\VID_0951&PID_1666
USB\VID_0781&PID_5571

# Linux-style (same file, both OSes read it)
0951:1666
0781:5571
```

---

## Architecture

See [Architecture.md](docs/Architecture.md).

| Layer | Module |
|-------|--------|
| Entry point | `hybrid_sync_usb_v2.ps1` |
| One-shot sync | `Invoke-HybridUsbSync` |
| Watcher mode | `Start-HybridUsbWatcher` |
| Whitelist parsing | `modules/Parser.psm1` |
| Registry engine | `modules/Registry.psm1` |
| Policy apply | `modules/Policy.psm1` |
| File watcher | `modules/Watcher.psm1` |
| Logging | `modules/Logger.psm1` |
| Utilities | `modules/Utils.psm1` |
| Config | `config/config.ps1` |

---

## Files & Paths

| Purpose | Path |
|---------|------|
| Whitelist (input) | `C:\Program Files (x86)\ossec-agent\shared\usb_whitelist.txt` |
| App data | `C:\ProgramData\Wazuh\UsbSync` |
| Logs | `C:\ProgramData\Wazuh\Logs\UsbSync\usb-sync.log` |
| Install log | `C:\ProgramData\Wazuh\Logs\UsbSync\install.log` |
| Registry policy | `HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions` |
| Scheduled task | `\Wazuh Hybrid USB Sync` |

---

## Operational Use

### Run one-shot sync manually

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\hybrid_sync_usb_v2.ps1
```

### Run in watcher mode (foreground)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\hybrid_sync_usb_v2.ps1 --watch
```

### Inspect policy

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
```

### Check scheduled task

```powershell
Get-ScheduledTask -TaskName 'Wazuh Hybrid USB Sync' | Get-ScheduledTaskInfo
```

### Tail logs

```powershell
Get-Content 'C:\ProgramData\Wazuh\Logs\UsbSync\usb-sync.log' -Wait
```

### Event log

```powershell
Get-WinEvent -LogName Application -Source WazuhUsbSync -MaxEvents 50
```

---

## Testing

Requires Pester (`Install-Module Pester -Force`). Full step-by-step: 👉 **[TESTING.md](docs/TESTING.md)** (includes manual end-to-end smoke test).

```powershell
Invoke-Pester -Path tests\Parser.Tests.ps1
Invoke-Pester -Path tests\Registry.Tests.ps1     # requires Administrator (writes HKLM)
```

---

## Compatibility

- Windows 10 (1809+)
- Windows 11
- Windows Server 2019
- Windows Server 2022
- PowerShell 5.1 (ships with Windows) and 7.x
- Wazuh Agent 4.x (uses `<shared>` agent.conf block)

---

## See Also

- [Guide](docs/guide.md)
- [Architecture](docs/Architecture.md)
- [Troubleshooting](docs/Troubleshooting.md)
- [Changelog](docs/CHANGELOG.md)
- [Linux V2](../v2/)

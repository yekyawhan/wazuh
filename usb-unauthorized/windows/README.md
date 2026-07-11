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

### Install

```cmd
cd windows
install.cmd
```

Auto-elevates to Administrator. First sync runs immediately.

### Uninstall

```cmd
uninstall.cmd
```

Add `--purge-logs` to wipe `C:\ProgramData\Wazuh\Logs\UsbSync`.

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

Requires Pester (`Install-Module Pester -Force`).

```powershell
Invoke-Pester -Path tests\Parser.Tests.ps1
Invoke-Pester -Path tests\Registry.Tests.ps1     # requires Administrator
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

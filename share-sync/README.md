# Wazuh Share Sync Service

A lightweight file synchronization utility for Wazuh agents.

This project synchronizes security automation scripts from the Wazuh shared directory into the Active Response directory on endpoints.

Supported files:

- PowerShell scripts (`*.ps1`)
- Windows batch scripts (`*.cmd`)
- Executable tools (`*.exe`)
- Linux scripts (`*.sh`)

The purpose is to maintain a centralized **Golden Source** for Wazuh Active Response tools and automatically distribute updates to all agents.

## Deployment Overview

This folder provides deployment variants for endpoints — pick one:

| Variant | Folder | Mechanism | Sync timing |
|---|---|---|---|
| **NSSM Windows Service** (recommended) | `windows-service-style/` | NSSM-wrapped `powershell.exe` service | Real-time via `FileSystemWatcher` + 5 min safety-net resync |
| **Task Scheduler (Win)** | `windows-task-Schedular-style/` | Scheduled task under `SYSTEM` | Every 1 minute |
| **Linux (Systemd Timer)** | `linux/` | Systemd `oneshot` service + timer | Every 1 minute |

Each folder is self-contained: drop it into the Wazuh agent shared directory (`C:\Program Files (x86)\ossec-agent\shared\` or `/var/ossec/etc/shared/`) and run its installer.

---

# Architecture

             Wazuh Manager

      /var/ossec/etc/shared/

                |
                |
          Wazuh Agent Sync

                |
                v

Agent shared/

                |
                |
         Wazuh Share Sync

                |
                v

active-response\bin\

    ├── response.ps1
    ├── block-ip.cmd
    └── tool.exe

---

# Features

## File Synchronization

Automatically sync files from agent `shared/` to `active-response\bin`.

Supported extensions: `*.ps1`, `*.cmd`, `*.exe`, `*.sh`, `*.py`, `*.bin`.

## Integrity Validation

SHA256 hash comparison. If source and destination hashes differ, destination is overwritten. This prevents unauthorized modification of Active Response scripts.

## Golden Source Model

The Wazuh Manager shared directory is treated as the master source. Any local modification on the endpoint is replaced with the approved version from the manager.

## Remote Command Enable

The Windows service variant automatically enables Wazuh remote command execution by writing `wazuh_command.remote_commands=1` and `logcollector.remote_commands=1` into `local_internal_options.conf`. The Wazuh service is restarted only when configuration changes are detected.

## Logging

Log file: 
- Windows: `C:\Program Files (x86)\ossec-agent\active-response\share-sync.log`
- Linux: `/var/ossec/logs/share-sync.log`

---

# Installation

## Requirements

- Windows/Linux endpoint
- Wazuh Agent installed
- Root/Administrator privileges

## Quick Install

Pick a variant and run the installer from a privileged prompt.

### Variant A — NSSM Windows Service (recommended, real-time)

```powershell
Copy-Item -Recurse windows-service-style\* "C:\Program Files (x86)\ossec-agent\shared\"
PowerShell -ExecutionPolicy Bypass -File "C:\Program Files (x86)\ossec-agent\shared\install.ps1"
```

Installs NSSM, creates & starts the `WazuhShareSync` service.

Uninstall:
```powershell
PowerShell -ExecutionPolicy Bypass -File "C:\Program Files (x86)\ossec-agent\shared\install.ps1" -Uninstall
```

### Variant B — Task Scheduler (Win, no extra dependencies)

```powershell
Copy-Item -Recurse windows-task-Schedular-style\* "C:\Program Files (x86)\ossec-agent\shared\"
PowerShell -ExecutionPolicy Bypass -File "C:\Program Files (x86)\ossec-agent\shared\install-sync-task.ps1"
```

Registers a `SYSTEM` task that runs every 1 minute.

Uninstall:
```powershell
Unregister-ScheduledTask -TaskName "Wazuh Share Sync" -Confirm:$false
```

### Variant C — Linux (Systemd Timer)

**Online (Direct download):**
```bash
sudo curl -o /var/ossec/etc/shared/share-sync/share-sync.sh https://raw.githubusercontent.com/yekyawhan/wazuh/git-home/share-sync/linux/share-sync.sh
sudo curl -o /var/ossec/etc/shared/share-sync/install-share-sync.sh https://raw.githubusercontent.com/yekyawhan/wazuh/git-home/share-sync/linux/install-share-sync.sh
sudo curl -o /var/ossec/etc/shared/share-sync/uninstall-share-sync.sh https://raw.githubusercontent.com/yekyawhan/wazuh/git-home/share-sync/linux/uninstall-share-sync.sh
sudo chmod +x /var/ossec/etc/shared/share-sync/install-share-sync.sh && sudo /var/ossec/etc/shared/share-sync/install-share-sync.sh
```

**Offline (Local files):**
```bash
sudo chmod +x /var/ossec/etc/shared/share-sync/share-sync.sh /var/ossec/etc/shared/share-sync/install-share-sync.sh && sudo /var/ossec/etc/shared/share-sync/install-share-sync.sh
```

Creates systemd service + timer (`wazuh-share-sync.timer`) running every 1 minute.

The installer moves `share-sync.sh` to `/var/ossec/bin/` (protected from Wazuh manager sync) and runs the service as the `wazuh`/`ossec` user with `ProtectSystem=strict`.

Uninstall:
```bash
sudo /var/ossec/etc/shared/share-sync/uninstall-share-sync.sh
```

---

# Security Design

The service provides:

- Centralized Active Response management
- Script integrity protection
- Automatic endpoint recovery
- Configuration enforcement
- Reduced manual deployment effort

---

# Project Structure

```
share-sync/
├── README.md
├── windows-service-style/          # NSSM service variant (real-time)
│   ├── install.ps1                  # single-file deployer (embeds service installer)
│   └── share-sync.ps1               # runtime (FileSystemWatcher)
├── windows-task-Schedular-style/   # Task Scheduler variant (1-min interval)
│   ├── install-sync-task.ps1       # registers SYSTEM scheduled task
│   └── share-sync.ps1               # one-shot sync runtime
└── linux/                          # Linux variant (1-min interval)
    ├── install-share-sync.sh       # registers systemd service + timer
    └── share-sync.sh               # one-shot sync runtime
```

---

# Author

Security Automation Project — Wazuh + EDR + SOAR Integration

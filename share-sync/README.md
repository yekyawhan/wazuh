# Wazuh Share Sync Service

A lightweight file synchronization utility for Wazuh agents.

This project synchronizes security automation scripts from the Wazuh shared directory into the Active Response directory on endpoints.

Supported files:

- PowerShell scripts (`*.ps1`)
- Windows batch scripts (`*.cmd`)
- Executable tools (`*.exe`)

The purpose is to maintain a centralized **Golden Source** for Wazuh Active Response tools and automatically distribute updates to all agents.

## Deployment Overview

This folder provides **two deployment variants** for Windows endpoints — pick one:

| Variant | Folder | Mechanism | Sync timing |
|---|---|---|---|
| **NSSM Windows Service** (recommended) | `windows-service-style/` | NSSM-wrapped `powershell.exe` service | Real-time via `FileSystemWatcher` + 5 min safety-net resync |
| **Task Scheduler (Win)** | `windows-task-Schedular-style/` | Scheduled task under `SYSTEM` | Every 1 minute |
| **Linux (Systemd Timer)** | `linux/` | Systemd `oneshot` service + timer | Every 1 minute |

Each folder is self-contained: drop it into `C:\Program Files (x86)\ossec-agent\shared\` and run its installer.

---

# Architecture

             Wazuh Manager

      /var/ossec/etc/shared/

                |
                |
          Wazuh Agent Sync

                |
                v

C:\Program Files (x86)\ossec-agent\shared

                |
                |
         Wazuh Share Sync Service

                |
                v

active-response\bin\

    ├── response.ps1
    ├── block-ip.cmd
    └── tool.exe

---

# Features

## File Synchronization

Automatically sync files from `ossec-agent\shared` to `ossec-agent\active-response\bin`.

Supported extensions: `*.ps1`, `*.cmd`, `*.exe`.

## Integrity Validation

SHA256 hash comparison. If source and destination hashes differ, destination is overwritten. This prevents unauthorized modification of Active Response scripts.

## Golden Source Model

The Wazuh Manager shared directory is treated as the master source. Any local modification on the endpoint is replaced with the approved version from the manager.

## Remote Command Enable

The service variant automatically enables Wazuh remote command execution by writing `wazuh_command.remote_commands=1` and `logcollector.remote_commands=1` into `local_internal_options.conf`. The Wazuh service is restarted only when configuration changes are detected.

## Logging

Log file: `C:\Program Files (x86)\ossec-agent\active-response\share-sync.log`

Example:

```
2026-07-15 12:00:01 ===== Sync Start =====
2026-07-15 12:00:02 SYNCED : block-ip.cmd
2026-07-15 12:00:02 SYNCED : kill-process.ps1
2026-07-15 12:00:03 WazuhSvc restarted
2026-07-15 12:00:03 ===== Sync Complete =====
```

---

# Installation

## Requirements

- Windows endpoint
- Wazuh Agent installed (default path `C:\Program Files (x86)\ossec-agent`)
- Administrator privileges

## Quick Install

Pick a variant, then from an **elevated PowerShell** prompt.

### Variant A — NSSM Windows Service (recommended, real-time)

```powershell
Copy-Item -Recurse windows-service-style\* "C:\Program Files (x86)\ossec-agent\shared\"
PowerShell -ExecutionPolicy Bypass -File "C:\Program Files (x86)\ossec-agent\shared\install.ps1"
```

Installs NSSM, creates & starts the `WazuhShareSync` service (auto-start, auto-restart, `FileSystemWatcher`-driven sync).

Uninstall:
```powershell
PowerShell -ExecutionPolicy Bypass -File "C:\Program Files (x86)\ossec-agent\shared\install.ps1" -Uninstall
```

### Variant B — Task Scheduler (no extra dependencies)

```powershell
Copy-Item -Recurse windows-task-Schedular-style\* "C:\Program Files (x86)\ossec-agent\shared\"
PowerShell -ExecutionPolicy Bypass -File "C:\Program Files (x86)\ossec-agent\shared\install-sync-task.ps1"
```

Registers a `SYSTEM` task that runs every 1 minute. No NSSM required; no real-time watcher — relies on the 1-minute interval.

Uninstall:
```powershell
Unregister-ScheduledTask -TaskName "Wazuh Share Sync" -Confirm:$false
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

# Future Roadmap

## Linux Support

Linux version will provide the same functionality with `systemd` service support and SHA256 validation.

---

# Project Structure

```
share-sync/
├── README.md
├── windows-service-style/          # NSSM service variant (real-time)
│   ├── install.ps1                  # single-file deployer (embeds service installer)
│   └── share-sync.ps1               # runtime (FileSystemWatcher)
└── windows-task-Schedular-style/   # Task Scheduler variant (1-min interval)
    ├── install-sync-task.ps1       # registers SYSTEM scheduled task
    └── share-sync.ps1              # one-shot sync runtime
```

---

# Author

Security Automation Project — Wazuh + EDR + SOAR Integration

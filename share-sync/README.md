# Wazuh Share Sync Service

A lightweight file synchronization utility for Wazuh agents.

This project synchronizes security automation scripts from the Wazuh shared directory into the Active Response directory on endpoints.

Supported files:

- PowerShell scripts (`*.ps1`)
- Windows batch scripts (`*.cmd`)
- Executable tools (`*.exe`)

The purpose is to maintain a centralized **Golden Source** for Wazuh Active Response tools and automatically distribute updates to all agents.

## Deployment Overview

This folder contains two files:

- **`install.ps1`** — single-file deployer. Run **once** (elevated). It materializes both scripts into `C:\Program Files (x86)\ossec-agent\shared\` (the service installer is embedded as base64) and then installs/starts the `WazuhShareSync` Windows service.
- **`share-sync.ps1`** — the runtime. Once installed, the service runs this continuously via a `FileSystemWatcher` real-time sync loop.

You only run `install.ps1`. `share-sync.ps1` runs automatically as the service.

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

Automatically sync files from:


ossec-agent\shared


to:


ossec-agent\active-response\bin


Supported extensions:


*.ps1
*.cmd
*.exe


---

## Integrity Validation

The service uses SHA256 hash comparison.

Process:


Source File Hash
|
|
Compare
|
v
Destination File Hash


If hashes are different:


Overwrite destination file


This prevents unauthorized modification of Active Response scripts.

---

## Golden Source Model

The Wazuh Manager shared directory is treated as the master source.

Example:


Manager

shared/
|
├── kill-process.ps1
├── block-ip.cmd
└── tool.exe

    |
    v

Agent

active-response/bin/

├── kill-process.ps1
├── block-ip.cmd
└── tool.exe


Any local modification on the endpoint will be replaced with the approved version from the manager.

---

# Remote Command Enable

The service automatically enables Wazuh remote command execution.

Configuration:


local_internal_options.conf


Added settings:


wazuh_command.remote_commands=1

logcollector.remote_commands=1


The Wazuh service is restarted only when configuration changes are detected.

---

# Logging

Log file:


C:\Program Files (x86)\ossec-agent\active-response\share-sync.log


Example:


2026-07-15 12:00:01 ===== Sync Start =====

2026-07-15 12:00:02 SYNCED : block-ip.cmd

2026-07-15 12:00:02 SYNCED : kill-process.ps1

2026-07-15 12:00:03 WazuhSvc restarted

2026-07-15 12:00:03 ===== Sync Complete =====


---

# Installation

## Requirements

- Windows endpoint
- Wazuh Agent installed (default path `C:\Program Files (x86)\ossec-agent`)
- Administrator privileges

---

## Quick Install (Recommended)

From an **elevated PowerShell** prompt:

```powershell
PowerShell -ExecutionPolicy Bypass -File install.ps1
```

That's it. The deployer:
1. Drops `share-sync.ps1` + embedded installer into `C:\Program Files (x86)\ossec-agent\shared\`
2. Installs NSSM (if missing)
3. Creates & starts the `WazuhShareSync` Windows service (auto-start, auto-restart on crash)
4. Logs to `C:\Program Files (x86)\ossec-agent\active-response\share-sync.log`

---

## Uninstall

```powershell
PowerShell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
```

Removes the service (keeps NSSM + scripts on disk).

---

## Legacy (Deprecated)

The old two-file method (`share-sync.ps1` + `install-service.ps1` copied manually to `shared\`) is no longer needed. `install.ps1` embeds the installer.

---

# Security Design

The service provides:

- Centralized Active Response management
- Script integrity protection
- Automatic endpoint recovery
- Configuration enforcement
- Reduced manual deployment effort


Security workflow:


Threat Detection

    |

Wazuh Alert

    |

Active Response

    |

Approved Script

    |

Endpoint Action


---

# Future Roadmap

## Linux Support

Linux version will provide the same functionality.

Planned:


Linux Agent

/var/ossec/etc/shared/

    |

    v

share-sync.sh

    |

    v

/var/ossec/active-response/bin/


Supported:


*.sh
*.py
*.bin


Features:

- SHA256 validation
- File synchronization
- Permission management
- systemd service support
- Logging


---

# Project Structure

Future structure:


wazuh-share-sync/

│
├── windows/
│
│ ├── share-sync.ps1
│ └── README.md
│
│
├── linux/
│
│ ├── share-sync.sh
│ └── README.md
│
│
└── docs/

└── architecture.md

---

# Author

Security Automation Project

Wazuh + EDR + SOAR Integration

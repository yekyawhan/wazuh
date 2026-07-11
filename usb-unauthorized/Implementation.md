# Wazuh USB Control — Windows V2 Implementation Plan

> **Project:** usb-unauthorized
> **Goal:** Fresh-build production Windows USB whitelist system. Mirrors Linux V2 architecture. Whitelist distributed by Wazuh Manager via `agent.conf` shared config.

---

## 1. Whitelist Source

Wazuh Manager pushes one file to every agent via centralized configuration:

```
C:\Program Files (x86)\ossec-agent\shared\usb_whitelist.txt
```

One source, every agent. Both Windows (`USB\VID_0951&PID_1666`) and Linux (`0951:1666`) formats supported in the same file — parser detects per-line.

---

## 2. Target Folder Structure

```
usb-unauthorized/windows/
├── config/
│   └── config.ps1
├── modules/
│   ├── Logger.psm1
│   ├── Parser.psm1
│   ├── Utils.psm1
│   ├── Registry.psm1
│   ├── Policy.psm1
│   └── Watcher.psm1
├── install/
│   └── install_usb_sync_windows.ps1
├── uninstall/
│   └── uninstall_usb_sync_windows.ps1
├── logs/
├── tests/
├── docs/
│   ├── README.md
│   ├── guide.md
│   ├── Architecture.md
│   └── Troubleshooting.md
├── hybrid_sync_usb_v2.ps1
├── install.cmd
└── audit-report.md
```

---

## 3. Sprints

### Sprint 1 — Foundation
- `config/config.ps1` — paths, registry keys, task name, log dir
- `modules/Logger.psm1` — file + Windows Event Log, levels INFO/WARN/ERROR/DEBUG/AUDIT
- `modules/Utils.psm1` — admin check, retry, path helpers
- `modules/Parser.psm1` — read `shared\usb_whitelist.txt`, detect format, dedupe, validate
- `hybrid_sync_usb_v2.ps1` — entrypoint skeleton
- `audit-report.md` — design review

### Sprint 2 — Registry Engine
- `modules/Registry.psm1` — read/create/update/cleanup `HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions`
- Idempotent writes, rollback on partial failure

### Sprint 3 — Policy Engine
- `modules/Policy.psm1` — apply `DenyDeviceIDs` policy
- Safe atomic update (temp key → swap)

### Sprint 4 — Watcher & Refresh
- `modules/Watcher.psm1` — FileSystemWatcher on `usb_whitelist.txt`
- `gpupdate /target:computer /force` refresh
- PnP device refresh

### Sprint 5 — Installer
- `install/install_usb_sync_windows.ps1` — copy files, register scheduled task, configure log dir, first sync, health check
- `install.cmd` — one-line bootstrap
- Idempotent (re-run safe)

### Sprint 6 — Uninstaller
- Remove scheduled task, registry entries, log dir
- Restore default device install policy

### Sprint 7 — Tests
- Fresh install, upgrade install, whitelist update, invalid input, recovery
- OS coverage: Win10, Win11, Server 2019, Server 2022

### Sprint 8 — Docs & Release
- README, guide, architecture, troubleshooting, CHANGELOG
- ZIP release: `usb-unauthorized-windows-v2.zip`

---

## 4. Coding Standards

- PowerShell 5.1 + 7 compatible
- `Set-StrictMode -Version Latest`
- Approved verbs only (`Get-`, `Set-`, `Test-`, `Register-`, `Unregister-`, `Write-`, `Start-`, `Stop-`, `Update-`)
- Comment-based help on every exported function
- Functions only — no inline script blocks
- `try/catch/finally` on every public function
- No duplicated logic
- Idempotent — running twice = same end state

---

## 5. Recovery Rules

Every failure path: **Retry → Recover → Rollback → Log AUDIT**.

---

## 6. Success Criteria

- One-line install (`install.cmd` → silent)
- Manager pushes whitelist → every Windows agent enforces within seconds
- Invalid lines skipped, valid lines applied, AUDIT log records
- Uninstaller restores defaults cleanly
- Win10/11 + Server 2019/2022 supported
- GitHub release ZIP ready

---

## 7. Current Status

| Sprint | Status |
|--------|--------|
| Sprint 1 — Foundation | ✅ Done |
| Sprint 2 — Registry | ✅ Done |
| Sprint 3 — Policy | ✅ Done |
| Sprint 4 — Watcher | ✅ Done |
| Sprint 5 — Installer | ✅ Done |
| Sprint 6 — Uninstaller | ✅ Done |
| Sprint 7 — Tests | ✅ Done |
| Sprint 8 — Docs & Release | ✅ Done, tagged v2.0.0 |

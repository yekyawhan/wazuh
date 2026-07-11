# Changelog

## 2.0.0 — 2026-07-11

Initial Windows V2 release. Fresh build, no V1 carry-over.

Fixes post-first-cut (commit 7e7b9df):
- `$global:UsbSync` so module-scope functions can read configuration (was invisible → sync threw under StrictMode).
- Empty whitelist now **blocks all USB** (AllowDeviceIDsEnabled=1 + empty list), not allow-all.

Additions (commit df63571):
- Log rotation (5MB / 3 backups) in Logger.
- Comment-based help on every exported function.

### Added
- Manager-pushed whitelist via `<shared>` agent.conf block.
- Allow-list Device Installation Restrictions policy.
- `Parser` module — supports both `USB\VID_xxxx&PID_xxxx` and `xxxx:xxxx` formats, dedupes, validates.
- `Registry` module — backup / restore / verify primitives, idempotent.
- `Policy` module — atomic apply (backup → write → verify → restore on failure).
- `Watcher` module — `FileSystemWatcher` with 3-second debounce.
- `Logger` module — file + Windows Event Log, levels DEBUG/INFO/AUDIT/WARNING/ERROR.
- `Utils` module — admin check, retry, path helpers.
- `hybrid_sync_usb_v2.ps1` entry point — one-shot and `--watch` modes.
- `install.cmd` / `install\install_usb_sync_windows.ps1` — idempotent, registers Scheduled Task, runs first sync.
- `uninstall.cmd` / `uninstall\uninstall_usb_sync_windows.ps1` — restores default policy.
- Pester tests for Parser + Registry round-trip.
- README, guide, Architecture, Troubleshooting.

### Notes
- Allow-list mode (not deny-list). Default-deny when whitelist is empty.
- No PnP enumeration — works with simple `AllowDeviceIDs` semantics.
- No log rotation yet (planned).
- Targets PowerShell 5.1 (Windows PowerShell) and 7.x.

### Compatibility
- Windows 10 (1809+), Windows 11, Server 2019, Server 2022.
- Wazuh Agent 4.x.

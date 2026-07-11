# Architecture

## Components

```
┌──────────────────────┐
│   Wazuh Manager      │
│   (centralized)      │
└──────────┬───────────┘
           │  agent.conf <shared> pushes
           │  usb_whitelist.txt
           ▼
┌──────────────────────────────────────────┐
│  C:\Program Files (x86)\ossec-agent\     │
│  shared\usb_whitelist.txt                │
└──────────┬───────────────────────────────┘
           │ FileSystemWatcher (3s debounce)
           ▼
┌──────────────────────────────────────────┐
│  hybrid_sync_usb_v2.ps1  (SYSTEM, startup)│
│  ┌────────────────────────────────────┐  │
│  │ Parser  →  Registry  →  Policy     │  │
│  │ (read)   (backup)    (apply)       │  │
│  │         ↓                           │  │
│  │      restore on fail                │  │
│  └────────────────────────────────────┘  │
│           │                              │
│           ▼                              │
│      gpupdate /force                     │
└──────────┬───────────────────────────────┘
           │
           ▼
   HKLM\…\DeviceInstall\Restrictions
   AllowDeviceIDsEnabled = 1
   AllowDeviceIDs        = [...]
```

## Data Flow

1. Operator edits `usb_whitelist.txt` on Manager.
2. Manager pushes via `<shared>` block of `agent.conf`.
3. Agent's scheduled task launches `hybrid_sync_usb_v2.ps1 --watch` at startup.
4. Initial sync reads the file and applies policy.
5. `FileSystemWatcher` on the whitelist detects future changes (3s debounce).
6. `gpupdate /force` refreshes Device Install policy so new list takes effect immediately.

## Module Boundaries

- **Parser** — pure function, no side effects. Given a path, returns validated device IDs.
- **Registry** — wraps HKLM read/write. Backup/Restore/Test primitives.
- **Policy** — orchestrates Registry for the allow-list semantics.
- **Watcher** — `FileSystemWatcher` → debounce → callback. No knowledge of policy.
- **Logger** — file + EventLog. Used by every other module.
- **Utils** — admin check, retry, path helpers.
- **Config** — single hashtable of paths/keys/task names.

## Failure Modes

| Failure | Recovery |
|---------|----------|
| Whitelist missing | WARN logged; previous policy retained |
| Whitelist line invalid | Line skipped; AUDIT line numbers logged |
| Registry write fails | Backup restored; ERROR logged |
| Verify mismatch | Backup restored; ERROR logged |
| `gpupdate` exit non-zero | WARN logged; new policy still in registry (effective on next refresh) |
| Watcher event lost | Periodic resync not implemented; rely on 5-min scheduled task fallback (Sprint 8) |

## Idempotency

Every write goes through `Set-ItemProperty` / `Remove-ItemProperty` with the same
target. Re-running with identical input produces identical registry state.
`Test-PolicyState` short-circuits no-op writes in the policy layer (caller-side).

## Performance

- Parse 100 devices: <50ms.
- Registry write: <20ms.
- `gpupdate /force`: 1–3s.
- Watcher debounce: 3s.

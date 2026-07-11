# Guide — Windows V2

## Install in 60 Seconds

```cmd
cd C:\path\to\usb-unauthorized\windows
install.cmd
```

The installer:
1. Elevates to Administrator (UAC prompt).
2. Creates `C:\ProgramData\Wazuh\UsbSync` and log directory.
3. Registers Scheduled Task `Wazuh Hybrid USB Sync` (AtStartup, SYSTEM).
4. Runs first sync.
5. Reports success or failure with exit code.

Exit codes:
- `0` — success
- `1` — not Administrator
- `2` — install error (see `install.log`)

## Whitelist Editing

Wazuh Manager side (single source):

```xml
<!-- /var/ossec/etc/shared/default/agent.conf -->
<agent_config>
  <shared>
    <whitelist_file path="shared/usb_whitelist.txt" />
  </shared>
</agent_config>
```

Or place the file directly in the agent's shared dir at
`/var/ossec/etc/shared/usb_whitelist.txt` — Manager will distribute to every agent.

Allowed entries (one per line):
- `USB\VID_0951&PID_1666` (Windows form)
- `0951:1666` (Linux form)
- `# comment` (ignored)
- blank lines (ignored)

`VID` and `PID` must be 4 hex digits. Short values (`951:166`) are padded.

## Allow-list Semantics

Policy writes:

| Registry Value | Type | Value |
|----------------|------|-------|
| `AllowDeviceIDsEnabled` | `REG_DWORD` | `1` |
| `AllowDeviceIDs`        | `REG_MULTI_SZ` | one string per device |

Effect: only listed device IDs may install. Everything else is blocked by Windows Device Installation policy.

## Manual Operations

### Force re-sync

```powershell
& 'C:\ProgramData\Wazuh\UsbSync\..\..\..\..\Program Files (x86)\ossec-agent\..\..\..\..\..\Program Files\Wazuh\UsbSync\hybrid_sync_usb_v2.ps1'
```

(Or just run `hybrid_sync_usb_v2.ps1` from the install location.)

### Inspect effective policy

```powershell
gpupdate /force
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
```

### Restart the watcher

```powershell
Restart-ScheduledTask -TaskName 'Wazuh Hybrid USB Sync'
```

### Remove the policy temporarily

```powershell
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions' -Name AllowDeviceIDsEnabled
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions' -Name AllowDeviceIDs
gpupdate /force
```

Then re-run `hybrid_sync_usb_v2.ps1` to re-apply from the whitelist.

## Upgrading

Re-run `install.cmd`. The installer is idempotent — it overwrites scripts and re-registers the scheduled task with `-Force`. Your whitelist on the Manager is preserved (lives outside this project).

## Reverting to Linux-only

Uninstall on every Windows host:

```cmd
uninstall.cmd
```

The Linux agents are unaffected — they have their own sync in `../v2/`.

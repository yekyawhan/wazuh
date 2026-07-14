# Wazuh USB Storage-Only Control — Windows V3

Centralized, manager-pushed USB **mass-storage** control. A single `usb_whitelist.txt` on the Wazuh Manager distributes to every agent; the agent enforces it with Windows **Device Installation Restrictions**, scoped to USB storage ONLY. Keyboards, mice, cameras, Bluetooth, hubs, phones are never touched.

## Files (under `windows/`)

- **`hybrid_sync_usb.ps1`** — one file, dual-mode: **INSTALL** when run from anywhere except the install path; **SYNC** when run from `C:\ProgramData\WazuhUsbSync` (by the scheduled task as SYSTEM). Run it once, elevated, and it does everything: removes old v1/v2 leftovers, repairs wrongly-disabled devices, copies itself to the install path, registers two SYSTEM scheduled tasks (startup + every 5 min, plus a Kernel-PnP on-plug trigger), runs the first sync, prints verification.
- **`uninstall-usb-control.ps1`** — full cleanup (policy + script + tasks + re-enable wrongly-disabled devices).
- **`get_usb_info.ps1`** — list USB devices for whitelisting (use `-Storage` for drives only).

## How it works (v3 design)

- **DENY** `USB\Class_08` (mass-storage interface) with `DenyDeviceIDsRetroactive=1` → already-installed drives are also blocked.
- **ALLOW** whitelisted drives by exact instance path (`VID&PID\SERIAL`) with `AllowDenyLayered=1` → whitelist wins over the deny.
- **PURGE** cached devnodes of non-whitelisted storage so every replug is a fresh install → blocked.
- No `DenyUnspecified` — only storage is restricted.

## Quick Start — One-line install (admin PowerShell)

Downloads the 3 files directly from GitHub (no zip / no releases folder), then runs the installer elevated:

```powershell
$base='https://raw.githubusercontent.com/yekyawhan/wazuh/git-home/usb-unauthorized/windows';$d="$env:TEMP\usbsync-v3";New-Item -ItemType Directory -Path $d -Force | Out-Null;iwr "$base\hybrid_sync_usb.ps1" -OutFile "$d\hybrid_sync_usb.ps1" -UseBasicParsing;iwr "$base\uninstall-usb-control.ps1" -OutFile "$d\uninstall-usb-control.ps1" -UseBasicParsing;iwr "$base\get_usb_info.ps1" -OutFile "$d\get_usb_info.ps1" -UseBasicParsing;Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$d\hybrid_sync_usb.ps1"
```

The installer (running elevated via the elevated process):
1. removes old v2/v1 leftovers (scheduled tasks + `C:\ProgramData\Wazuh`)
2. repairs devices the old v2 script wrongly disabled
3. copies `hybrid_sync_usb.ps1` to `C:\ProgramData\WazuhUsbSync`
4. registers two scheduled tasks (startup + every 5 min, plus a Kernel-PnP on-plug trigger for near-realtime enforcement)
5. runs first sync and prints verification

After install, all subsequent runs are SYNC mode (triggered by the tasks, not the user). Re-running the install is safe and idempotent.

## Uninstall

```powershell
Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\ProgramData\WazuhUsbSync\uninstall-usb-control.ps1'
```

Or download then run:
```powershell
$base='https://raw.githubusercontent.com/yekyawhan/wazuh/git-home/usb-unauthorized/windows';iwr "$base\uninstall-usb-control.ps1" -OutFile "$env:TEMP\uninstall-usb-control.ps1" -UseBasicParsing;Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$env:TEMP\uninstall-usb-control.ps1"
```

## Whitelist format

On the Manager's `usb_whitelist.txt` (`/var/ossec/etc/shared/default/usb_whitelist.txt`):

```
# VID:PID (any stick of that model)
0781:556b
# or Windows hardware ID
USB\VID_0781&PID_556B
# or full instance path (pin ONE exact physical stick)
USB\VID_0781&PID_556B\070B7C86...
```

## Centralization

The whitelist is pushed by the Wazuh Manager via shared configuration. If the manager also drops a newer `hybrid_sync_usb.ps1` into the shared folder, the local copy self-updates on every sync — no reinstall needed.

## Find a device ID to whitelist

```powershell
iwr 'https://raw.githubusercontent.com/yekyawhan/wazuh/git-home/usb-unauthorized/windows/get_usb_info.ps1' -OutFile "$env:TEMP\get_usb_info.ps1" -UseBasicParsing;powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\get_usb_info.ps1" -Storage
```

## Logs

- App-specific: `C:\ProgramData\WazuhUsbSync\log.txt`
- Wazuh active-response: `C:\Program Files (x86)\ossec-agent\active-response\active-responses.log` (best-effort, may not be writable under SYSTEM)

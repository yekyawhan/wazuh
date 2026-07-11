# Troubleshooting

## Install fails with "Administrator required"

`install.cmd` must run elevated. Right-click → "Run as administrator", or trust the UAC prompt that auto-elevation shows.

## "Whitelist file not found" at every sync

`C:\Program Files (x86)\ossec-agent\shared\usb_whitelist.txt` doesn't exist.

Check Wazuh Manager:
```bash
ls /var/ossec/etc/shared/usb_whitelist.txt
cat /var/ossec/etc/shared/default/agent.conf | grep whitelist_file
```

On the agent:
```cmd
dir "C:\Program Files (x86)\ossec-agent\shared\"
```

If the Manager has the file but the agent doesn't, the Wazuh agent service isn't syncing shared config. Check agent logs:
```cmd
type "C:\Program Files (x86)\ossec-agent\ossec.log" | findstr /i shared
```

Restart the agent service:
```cmd
net stop wazuh && net start wazuh
```

## USB still installs despite whitelist

1. Confirm the device ID is in the file:
   ```cmd
   findstr /i "VID_xxxx" "C:\Program Files (x86)\ossec-agent\shared\usb_whitelist.txt"
   ```
2. Force a refresh:
   ```cmd
   gpupdate /force
   ```
3. Unplug and re-plug the device.
4. Check the policy is actually applied:
   ```powershell
   Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
   ```
   `AllowDeviceIDsEnabled` must be `1`, `AllowDeviceIDs` must list your device.

Some USB device classes (keyboards, mice, hubs) are **exempt** from Device Install Restrictions by default. Storage class (USBSTOR) is enforced. See [Microsoft docs](https://learn.microsoft.com/en-us/windows/security/identity-protection/access-control/device-guard).

## Sync log is silent

Log location: `C:\ProgramData\Wazuh\Logs\UsbSync\usb-sync.log`. If empty:

- Check `Install-Log` (`install.log`) for errors during install.
- Re-run install.cmd — it will re-register the task.

## Watcher not picking up changes

Verify the task is running:
```powershell
Get-ScheduledTask -TaskName 'Wazuh Hybrid USB Sync' | Get-ScheduledTaskInfo
```

`LastRunTime` should be recent. If `State` is `Stopped`, restart:
```powershell
Start-ScheduledTask -TaskName 'Wazuh Hybrid USB Sync'
```

The watcher debounces 3 seconds. Wait briefly after editing the file.

## Event Log errors

```powershell
Get-WinEvent -LogName Application -Source WazuhUsbSync -MaxEvents 50
```

Common:
- `EventId 1000` — sync error. Message contains exception.
- `EventId 1000 (gpupdate)` — Device Install policy refresh failed. Run `gpupdate /force` manually and inspect.

## Restore after corruption

The Registry engine always backs up before writing. If a write corrupts state, re-running `hybrid_sync_usb_v2.ps1` will detect the mismatch and restore the backup automatically.

To force a clean restore to defaults:
```cmd
uninstall.cmd
install.cmd
```

## Logs growing unbounded

The current logger appends. Rotation is planned for a future release. Workaround:

```powershell
Get-Item 'C:\ProgramData\Wazuh\Logs\UsbSync\usb-sync.log' |
  ForEach-Object { $_.Delete() }
```

The next sync creates a new file.

## Uninstaller fails to remove task

`Stop-ScheduledTask` may fail if the task is mid-run. Retry:
```powershell
Unregister-ScheduledTask -TaskName 'Wazuh Hybrid USB Sync' -Confirm:$false
```

Then re-run `uninstall.cmd`.

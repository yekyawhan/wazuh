# Option 2: OS Native Blocking + Wazuh Alerting (Enterprise Standard)

## Architecture Overview
- **Blocking Layer:** Handled entirely by the Operating System (GPO on Windows, udev on Linux). Works 100% offline.
- **Alerting Layer:** Wazuh Agent monitors OS event logs. If offline, it queues the logs and sends alerts to the Manager once online.

## 1. Windows Implementation (GPO)
Uses Local Group Policy or Active Directory GPO.

### Steps:
1. Open `gpedit.msc`.
2. Navigate to: `Computer Configuration -> Administrative Templates -> System -> Device Installation -> Device Installation Restrictions`.
3. Enable **"Prevent installation of devices not described by other policy settings"**. (This blocks ALL new USBs).
4. Enable **"Allow installation of devices that match any of these device IDs"**.
5. Click **Show** and enter the Whitelisted USB Hardware IDs.
   - Format: `USB\VID_XXXX&PID_YYYY`
   - Example: `USB\VID_0951&PID_1666`

### Wazuh Role (Windows):
- Monitor Event Viewer: `Microsoft-Windows-Kernel-PnP` (Event ID 219 - Driver load failed / Device blocked).
- Wazuh Manager Rule triggers alert on this Event ID.

## 2. Linux Implementation (udev)
Uses kernel-level USB authorization.

### Steps:
1. Create a udev rule file: `/etc/udev/rules.d/99-usb-block.rules`
2. **Default Block All:**
   ```udev
   ACTION=="add", SUBSYSTEMS=="usb", ATTR{authorized}="0"
   ```
3. **Whitelist Specific Devices (Allow):**
   ```udev
   ACTION=="add", SUBSYSTEMS=="usb", ATTR{idVendor}=="0951", ATTR{idProduct}=="1666", ATTR{authorized}="1"
   ```
4. Reload rules: `udevadm control --reload-rules && udevadm trigger`

### Wazuh Role (Linux):
- Monitor `/var/log/syslog` or `dmesg` for USB reject/unauthorized messages.
- Wazuh Manager Rule triggers alert on these log patterns.

## Summary
- **Offline?** Yes. OS blocks it.
- **Whitelist?** Yes. OS only allows registered VID/PID.
- **Wazuh Action?** Read logs, send alerts. No active response scripts needed.
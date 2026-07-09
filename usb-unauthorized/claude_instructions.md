# USB Monitoring & Native Blocking (GPO/udev) Implementation Guide

## Objective
Implement a robust, offline-capable USB blocking solution using native OS policies (GPO for Windows, `udev` for Linux) with Wazuh configured strictly for alerting and auditing.

## Architecture Change Justification
Initially planned to use Wazuh Active Response. Abandoned because Active Response requires a constant connection to the Wazuh Manager. If the endpoint is offline, unauthorized USBs would mount successfully. Shifting to OS-level blocking guarantees protection regardless of network state.

## Task 1: Windows Native Blocking & Whitelisting (GPO)
**Goal:** Block all USB storage devices by default, but allow specific Whitelisted Hardware IDs (VID/PID).

1.  **Configure Local Group Policy (GPO):**
    *   Path: `Computer Configuration -> Administrative Templates -> System -> Device Installation -> Device Installation Restrictions`
    *   Enable: **"Prevent installation of devices not described by other policy settings"**.
    *   Enable: **"Allow installation of devices that match any of these device IDs"**.
    *   Add Whitelist Format: `USB\VID_XXXX&PID_YYYY` (e.g., `USB\VID_0951&PID_1666`).
2.  **Automation Script Required:**
    *   Need a PowerShell script to automate applying these Local GPO registry keys so administrators can easily push this configuration to endpoints.

## Task 2: Linux Native Blocking & Whitelisting (`udev`)
**Goal:** Prevent unauthorized USB kernel modules from loading or unauthorize them at the bus level.

1.  **Configure `udev` rules (`/etc/udev/rules.d/99-usb-block.rules`):**
    *   *Default Block:* `ACTION=="add", SUBSYSTEMS=="usb", ATTR{authorized}="0"`
    *   *Whitelist Allow:* `ACTION=="add", SUBSYSTEMS=="usb", ATTR{idVendor}=="0951", ATTR{idProduct}=="1666", ATTR{authorized}="1"`
2.  **Automation Script Required:**
    *   Need a Bash script to generate and reload these `udev` rules automatically given a list of VIDs/PIDs.

## Task 3: Wazuh Detection Rules (Alerting Only)
**Goal:** Generate Wazuh alerts when the OS successfully blocks an unauthorized USB device. No Active Response is needed.

1.  **Windows Wazuh Rule:**
    *   Target Event: `Event ID 219` (Kernel-PnP: The driver \Driver\WUDFRd failed to load) or related Plug-and-Play block events.
    *   Need the exact Wazuh XML rule to trigger an alert on this block event.
2.  **Linux Wazuh Rule:**
    *   Target Log: `/var/log/syslog` or `dmesg`.
    *   Need the exact Wazuh XML rule to parse the `udev` rejection/unauthorized log.

## Instructions for Coding Agent
Please generate the following artifacts based on the architecture above:
1.  `windows_gpo_setup.ps1`: PowerShell script to set the Local GPO registry keys for blocking all USBs and whitelisting specific Hardware IDs.
2.  `linux_udev_setup.sh`: Bash script to create the `udev` rules and reload the service.
3.  `wazuh_rules.xml`: The Wazuh Manager rules to alert when the OS blocks a device on both Windows (Event ID 219 or similar) and Linux.
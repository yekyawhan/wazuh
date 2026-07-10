# USB Unauthorized Device Blocking — Setup Guide

Wazuh Centralized Configuration + OS-native policy (Windows GPO / Linux udev) ကို အသုံးပြု၍ ခွင့်ပြုချက်မရှိသော USB များကို block လုပ်ပြီး၊ block ဖြစ်စဉ်များကို Wazuh မှ alert ထုတ်ပေးသည့် စနစ်အတွက် လမ်းညွှန်ဖြစ်သည်။

Order: **Manager side first → then onboard each endpoint.**

---

## 1. Manager Side Setup (Wazuh Server)

### 1.1 Create the whitelist
`/var/ossec/etc/shared/default/usb_whitelist.txt` — one USB Hardware ID per line. Both formats are accepted (the sync scripts convert automatically):
```
# Windows format
USB\VID_0951&PID_1666
# Linux format (VID:PID) also works
0781:5591
```

### 1.2 Add the sync + logging config
`/var/ossec/etc/shared/default/agent.conf` — this runs the sync on a schedule, and (Windows) forwards the Kernel-PnP channel so blocked installs raise an alert:
```xml
<agent_config os="Windows">
  <!-- run the whitelist sync every hour -->
  <localfile>
    <log_format>command</log_format>
    <command>powershell -ExecutionPolicy Bypass -File "C:\Program Files (x86)\ossec-agent\active-response\bin\hybrid_sync_usb.ps1"</command>
    <frequency>3600</frequency>
  </localfile>
  <!-- forward Kernel-PnP so blocked installs (Event ID 219) alert -->
  <localfile>
    <location>Microsoft-Windows-Kernel-PnP/Configuration</location>
    <log_format>eventchannel</log_format>
  </localfile>
</agent_config>

<agent_config os="Linux">
  <localfile>
    <log_format>command</log_format>
    <command>/var/ossec/active-response/bin/hybrid_sync_usb_linux.sh</command>
    <frequency>3600</frequency>
  </localfile>
</agent_config>
```

### 1.3 Add the alert rules
`/var/ossec/etc/rules/local_rules.xml`:
```xml
<group name="usb,device-control,">

  <!-- sync ran successfully on an agent -->
  <rule id="100030" level="3">
    <match>hybrid_sync_usb</match>
    <description>USB whitelist sync ran on agent.</description>
  </rule>

  <!-- Linux: udev blocked a device (matches the logger line the script emits) -->
  <rule id="100031" level="8">
    <decoded_as>syslog</decoded_as>
    <match>usb-block: DENIED</match>
    <description>Unauthorized USB device blocked by OS policy (Linux).</description>
    <group>usb_blocked,</group>
  </rule>

  <!-- Windows: GPO blocked a device install (needs the Kernel-PnP localfile in 1.2) -->
  <rule id="100032" level="8">
    <if_group>windows</if_group>
    <field name="win.system.eventID">^219$</field>
    <description>Unauthorized USB device blocked by OS policy (Windows).</description>
    <group>usb_blocked,</group>
  </rule>

  <!-- repeated attempts = higher severity -->
  <rule id="100035" level="12" frequency="5" timeframe="60">
    <if_matched_group>usb_blocked</if_matched_group>
    <description>Repeated unauthorized USB attempts on one host (high risk).</description>
    <group>usb_blocked,pci_dss_10.2.4,</group>
  </rule>

</group>
```

### 1.4 Fix ownership + restart
```bash
chown wazuh:wazuh /var/ossec/etc/shared/default/usb_whitelist.txt 2>/dev/null || chown ossec:ossec /var/ossec/etc/shared/default/usb_whitelist.txt
systemctl restart wazuh-manager
```

---

## 2. Endpoint Setup (one time, per agent)

Run the onboarding installer — it deploys the sync script, **enables `logcollector.remote_commands=1`** (required: agents ignore the manager's command without it, and it can only be set locally), restarts the agent, and runs the sync once. **Administrator (Windows) / root (Linux).**

**Windows** — CDN / GitHub raw:
```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12';iwr https://cdn.jsdelivr.net/gh/yekyawhan/wazuh@git-home/usb-unauthorized/enable-usb-sync.ps1 -UseBasicParsing | iex
```
```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12';iwr https://raw.githubusercontent.com/yekyawhan/wazuh/git-home/usb-unauthorized/enable-usb-sync.ps1 -UseBasicParsing | iex
```

**Linux** — CDN / GitHub raw:
```bash
curl -sL https://cdn.jsdelivr.net/gh/yekyawhan/wazuh@git-home/usb-unauthorized/enable-usb-sync.sh | sudo bash
```
```bash
curl -sL https://raw.githubusercontent.com/yekyawhan/wazuh/git-home/usb-unauthorized/enable-usb-sync.sh | sudo bash
```

> If you prefer to do it manually: download the sync script into the agent's
> `active-response/bin/`, add `logcollector.remote_commands=1` to the agent's
> `local_internal_options.conf`, then restart the agent. The installer just
> automates those three steps.

---

## 3. Utility — get a USB device's ID

To authorize a new device, find its VID/PID and add it to `usb_whitelist.txt` on the manager. Output is de-duplicated and hides hubs.

**Windows** — CDN / raw:
```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12';iwr https://cdn.jsdelivr.net/gh/yekyawhan/wazuh@git-home/usb-unauthorized/get_usb_info.ps1 -UseBasicParsing | iex
```
```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12';iwr https://raw.githubusercontent.com/yekyawhan/wazuh/git-home/usb-unauthorized/get_usb_info.ps1 -UseBasicParsing | iex
```
**Linux** — CDN / raw:
```bash
curl -sL https://cdn.jsdelivr.net/gh/yekyawhan/wazuh@git-home/usb-unauthorized/get_usb_info.sh | bash
```
```bash
curl -sL https://raw.githubusercontent.com/yekyawhan/wazuh/git-home/usb-unauthorized/get_usb_info.sh | bash
```

---

## 4. Advanced Monitoring & Audit Loop

Blocking alone isn't enough — track **who tried to plug in what** so you have an audit trail.

### 4.1 Dashboard table of block events
1. **Visualize → Create Visualization → Data Table**.
2. **Buckets → Split rows →** `agent.name` (or `agent.id`).
3. Filter: `rule.id: (100031 OR 100032)`.

You'll see which host generated the most unauthorized-USB attempts.

### 4.2 High-risk correlation
Rule `100035` (added in 1.3) already raises a **Level 12** alert when the same host is blocked 5+ times in 60 seconds — a strong signal of someone repeatedly trying different USBs.

### 4.3 Automated reporting
Use the Wazuh **Reporting** feature to email the block-events dashboard daily or weekly to the SOC inbox.

---

## Quick reference — day-to-day

| Task | What to do |
| --- | --- |
| Allow a new device | Find its ID (section 3) → add the line to `usb_whitelist.txt` on the manager. Agents apply it on the next sync. |
| Onboard a new endpoint | Run the section-2 one-liner once. |
| Force an update now | On the manager, edit the file; on CDN, purge it (or agents pick it up on their next sync). |

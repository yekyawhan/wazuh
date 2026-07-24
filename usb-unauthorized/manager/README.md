# Manager Custom Rules — USB Device Control

Custom Wazuh rules for USB unauthorized device blocking alerts.

## Deploy

Copy `Custom_USB.xml` to the Wazuh Manager and restart:

```bash
sudo cp Custom_USB.xml /var/ossec/etc/rules/Custom_USB.xml
sudo chown wazuh:wazuh /var/ossec/etc/rules/Custom_USB.xml
sudo systemctl restart wazuh-manager
```

## Rules

| ID | Level | Trigger | Description |
|---|---|---|---|
| 100030 | 5 | `hybrid_sync_usb` in log | USB whitelist sync ran on agent |
| 100031 | 8 | `usb-block: DENIED` in log | **Unauthorized USB blocked (Linux)** |
| 100032 | 8 | Windows EventID 420 + USB class GUID | **Unauthorized USB blocked (Windows)** |
| 100035 | 12 | 5× rule 100031/100032 in 60s | Repeated unauthorized USB attempts (high risk) |
| 100040 | 5 | `cybersecurity patch deployment:` | SOC triggered Active Response |

## Prerequisites — Agent localfile config

The rules match log lines. The Wazuh agent must be reading the right log files.

### Linux agents

Add to agent `ossec.conf` (or push via manager `agent.conf`):

```xml
<localfile>
  <log_format>syslog</log_format>
  <location>/var/log/syslog</location>
</localfile>
<localfile>
  <log_format>syslog</log_format>
  <location>/var/log/wazuh-usb-sync.log</location>
</localfile>
```

- `/var/log/syslog` → picks up `usb-block: DENIED` from udev rule
- `/var/log/wazuh-usb-sync.log` → picks up sync events from `hybrid_sync_usb_linux_v2.sh`

### Windows agents

Add to agent `ossec.conf`:

```xml
<localfile>
  <log_format>eventchannel</log_format>
  <location>Microsoft-Windows-Kernel-PnP/Configuration</location>
</localfile>
```

This captures EventID 420 (device install blocked by policy) which rule 100032 matches.

## Verify on Dashboard

1. Go to **Modules → Security Events**
2. Search: `rule.id:100031` (Linux) or `rule.id:100032` (Windows)
3. Or filter by group: `usb_blocked`

## Test (Linux)

On any Linux agent with the USB sync installed:

```bash
logger -t usb-block "DENIED unauthorized USB storage kernel=test vendor=1234 product=5678"
```

Then check dashboard for alert rule 100031.

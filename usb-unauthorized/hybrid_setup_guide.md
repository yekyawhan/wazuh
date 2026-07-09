# Hybrid USB Blocking Setup (Centralized + Offline GPO)

## 1. Manager Side Setup (Central Control)
Run these on your Wazuh Manager:

1. Create the whitelist file:
```bash
nano /var/ossec/etc/shared/default/usb_whitelist.txt
```
*Add your allowed USB IDs (one per line, e.g., `USB\VID_0951&PID_1666`).*

2. Configure Agents to sync it via `agent.conf`:
```bash
nano /var/ossec/etc/shared/default/agent.conf
```
*Add the following block:*
```xml
<agent_config os="Windows">
  <localfile>
    <log_format>command</log_format>
    <command>powershell -ExecutionPolicy Bypass -File "C:\Program Files (x86)\ossec-agent\active-response\bin\hybrid_sync_usb.ps1"</command>
    <!-- Checks and applies updates every 1 hour (3600 seconds) -->
    <frequency>3600</frequency>
  </localfile>
</agent_config>
```

3. Ensure correct permissions:
```bash
chown ossec:ossec /var/ossec/etc/shared/default/usb_whitelist.txt
```

## 2. Agent Side Setup (Windows Endpoint)
Run this ONCE on the Windows endpoint to put the script in place.

```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/yekyawhan/wazuh/git-home/usb-unauthorized/hybrid_sync_usb.ps1" -OutFile "C:\Program Files (x86)\ossec-agent\active-response\bin\hybrid_sync_usb.ps1"
```

## How It Works:
1. When you update `usb_whitelist.txt` on the Manager, Wazuh automatically pushes it to `C:\Program Files (x86)\ossec-agent\shared\` on the Windows endpoints.
2. The `agent.conf` command runs `hybrid_sync_usb.ps1` periodically.
3. The script reads the synced text file and updates the Local Windows GPO registry keys.
4. USB access is instantly restricted offline based on the latest synced policy.

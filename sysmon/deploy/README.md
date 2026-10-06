# Wazuh Sysmon Centralized Deployment

## Overview

Centralized Sysmon configuration management via Wazuh shared folders and agent groups. Automatically distributes `custom-sysmon-tuned.xml` to Windows endpoints and applies updates via womodule commands.

## Architecture

```
Siem1 Manager (172.16.10.2)
  └─ /var/ossec/etc/shared/windows_sysmon_tuned/
      ├─ sysmon-tuned.xml           (config file)
      └─ agent.conf                  (womodule commands)
           ↓ (synced every 5-10 min)
Windows Agents (group: windows_sysmon_tuned)
  └─ C:\Program Files (x86)\ossec-agent\shared\
      ├─ sysmon-tuned.xml
      └─ agent.conf
           ↓ (womodule runs on start + daily)
      C:\Windows\Sysmon64.exe -c C:\Windows\Temp\sysmon-tuned.xml
```

## Files

```
/home/y3kh/.claude/my-project/wazuh/sysmon/
├── config/
│   └── custom-sysmon-tuned.xml        # Master config (source of truth)
└── deploy/
    ├── centralized_push.sh            # Initial deployment
    ├── add_agents.sh                  # Add agents to group
    └── validate_fleet.sh              # Validate deployment
```

## Deployment Steps

### 1. Initial Setup (One-time)

Run `centralized_push.sh` to:
- Upload config to Siem1
- Create shared folder `/var/ossec/etc/shared/windows_sysmon_tuned/`
- Create agent group `windows_sysmon_tuned`
- Configure womodule auto-update command
- Add pilot agent 002 to group
- Restart manager

```bash
cd /home/y3kh/.claude/my-project/wazuh/sysmon/deploy
./centralized_push.sh
```

**Expected output:**
```
=== Wazuh Centralized Sysmon Deployment ===
[1/6] Uploading Sysmon config to manager...
[2/6] Creating shared folder structure...
[3/6] Creating agent group...
[4/6] Creating agent.conf with Sysmon update command...
[5/6] Assigning pilot agent (002) to group...
[6/6] Restarting Wazuh manager...
=== Deployment Complete ===
```

### 2. Add More Agents

Add agents by ID:

```bash
./add_agents.sh 015 016 017
```

Or manually via SSH:

```bash
ssh ykh@172.16.10.2
sudo /var/ossec/bin/agent_groups -a -i 015 -g windows_sysmon_tuned
sudo /var/ossec/bin/agent_groups -a -i 016 -g windows_sysmon_tuned
```

### 3. Validation

Check fleet status:

```bash
./validate_fleet.sh
```

Verify individual agent (on Windows endpoint):

```powershell
# Check shared config received
dir "C:\Program Files (x86)\ossec-agent\shared\sysmon-tuned.xml"

# Check current Sysmon config hash
C:\Windows\Sysmon64.exe -c

# Check womodule logs
Get-Content "C:\Program Files (x86)\ossec-agent\ossec.log" | Select-String -Pattern "sysmon" -Context 2,2
```

## Womodule Behavior

The `agent.conf` contains two womodules:

### 1. Config Update (runs on agent start + every 24h)
```xml
<wodle name="command">
  <tag>sysmon-config-update</tag>
  <command>powershell.exe -NoProfile ... Sysmon64.exe -c ...</command>
  <interval>1d</interval>
  <run_on_start>yes</run_on_start>
</wodle>
```

**Trigger:**
- Agent restart (manual or via `services.msc`)
- 24h interval timer
- Manager restart (forces agent reconnect)

### 2. Health Check (every 6h)
```xml
<wodle name="command">
  <tag>sysmon-health-check</tag>
  <command>Get-Service -Name Sysmon64 | ConvertTo-Json</command>
  <interval>6h</interval>
</wodle>
```

Logs appear in `/var/ossec/logs/ossec.log` on manager:
```
wazuh-modulesd:command[002]: INFO: (8220): Output from agent '002' for 'sysmon-config-update': Sysmon config updated successfully
```

## Manual Trigger

To force immediate config update on an agent:

**Option A:** Restart Wazuh service (preferred)
```powershell
Restart-Service -Name WazuhSvc -Force
```

**Option B:** Restart manager (all agents sync)
```bash
ssh ykh@172.16.10.2 'sudo systemctl restart wazuh-manager'
```

**Option C:** Run command manually
```powershell
C:\Windows\Sysmon64.exe -c "C:\Program Files (x86)\ossec-agent\shared\sysmon-tuned.xml"
```

## Updating Config

To push new config version:

1. Update master: `config/custom-sysmon-tuned.xml`
2. Upload to Siem1:
```bash
scp config/custom-sysmon-tuned.xml ykh@172.16.10.2:/tmp/
ssh ykh@172.16.10.2 '
  sudo cp /tmp/custom-sysmon-tuned.xml /var/ossec/etc/shared/windows_sysmon_tuned/sysmon-tuned.xml
  sudo chown wazuh:wazuh /var/ossec/etc/shared/windows_sysmon_tuned/sysmon-tuned.xml
  sudo systemctl restart wazuh-manager
'
```
3. Wait 5-10 min for agents to sync
4. Agents apply on next restart or 24h womodule run

## Rollback

### Group-level Rollback
1. Upload old config version to shared folder
2. Restart manager to sync
3. Agents apply on next womodule run

### Individual Agent Rollback
```powershell
# On Windows agent
C:\Windows\Sysmon64.exe -c "C:\Windows\Temp\sysmon-backup-YYYYMMDD.xml"
```

### Remove Agent from Group
```bash
ssh ykh@172.16.10.2
sudo /var/ossec/bin/agent_groups -r -i 002 -g windows_sysmon_tuned
```

## Troubleshooting

### Agent not syncing config
**Check:**
```bash
# Manager: verify shared folder permissions
ssh ykh@172.16.10.2 'ls -la /var/ossec/etc/shared/windows_sysmon_tuned/'

# Agent: check last sync time
Get-ItemProperty "C:\Program Files (x86)\ossec-agent\shared\sysmon-tuned.xml" | Select-Object LastWriteTime

# Manager logs
ssh ykh@172.16.10.2 'sudo tail -f /var/ossec/logs/ossec.log | grep -i "agent 002"'
```

**Solution:** Restart agent service

### Womodule not running
**Check:**
```powershell
# Agent logs
Get-Content "C:\Program Files (x86)\ossec-agent\ossec.log" | Select-String -Pattern "womodule" -Context 5,5
```

**Solution:** Verify `agent.conf` syntax, restart agent

### Sysmon config errors (EID 255)
**Check:**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-Sysmon/Operational" -MaxEvents 50 | Where-Object {$_.Id -eq 255}
```

**Solution:** XML syntax error, validate config locally first

### Config hash mismatch
**Check:**
```bash
# Local hash
sha256sum config/custom-sysmon-tuned.xml

# Agent hash (on Windows)
C:\Windows\Sysmon64.exe -c | Select-String "Config hash"
```

**Solution:** Config not synced yet, wait or force restart

## Production Rollout Timeline

```
Day 0: Initial setup (centralized_push.sh) + pilot agent 002
Day 1: Monitor pilot 24h baseline
Day 2: Pilot metrics review + go/no-go
Day 3: Add Batch 1 (5 agents) via add_agents.sh
Day 4: Monitor Batch 1
Day 5: Add Batch 2 (10 agents)
Day 6: Monitor Batch 2
Day 7: Full fleet rollout
Day 8: Fleet validation + final metrics
```

## Metrics Collection

Before/after comparison (24h window):

```bash
# EID 1 count per agent
ssh ykh@172.16.10.2 "
curl -s -k -u 'admin:Cybersoc*3' 'https://localhost:9200/wazuh-alerts-*/_search' -H 'Content-Type: application/json' -d '{
  \"size\": 0,
  \"query\": {
    \"bool\": {
      \"must\": [
        {\"term\": {\"agent.id\": \"002\"}},
        {\"range\": {\"timestamp\": {\"gte\": \"now-24h\"}}},
        {\"term\": {\"data.win.system.eventID\": 1}}
      ]
    }
  }
}' | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"hits\"][\"total\"][\"value\"])'
"
```

Expected reduction: ~60% (110k → 44k EID1/day)

## Credentials

- **Siem1 SSH:** `ykh` / `ykhster`
- **Siem1 ES:** `admin` / `Cybersoc*3`
- **Scripts location:** `/home/y3kh/.claude/my-project/wazuh/sysmon/deploy/`

## References

- Master config: `/home/y3kh/.claude/my-project/wazuh/sysmon/config/custom-sysmon-tuned.xml`
- Wazuh agent groups: https://documentation.wazuh.com/current/user-manual/agent-management/grouping-agents.html
- Wazuh command womodule: https://documentation.wazuh.com/current/user-manual/reference/ossec-conf/wodle-command.html
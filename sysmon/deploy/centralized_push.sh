#!/bin/bash
# Wazuh Centralized Sysmon Config Push - Option B
# Deploys custom-sysmon-tuned.xml via Wazuh shared folder + agent groups
# Target: Siem1 manager (172.16.10.2)
# Author: Laypyay
# Date: 2026-10-06

set -e

SIEM1_HOST="172.16.10.2"
SIEM1_USER="ykh"
SIEM1_PASS="${SIEM1_PASS:-}"  # Set via env or prompt
CONFIG_SOURCE="/home/y3kh/.claude/my-project/wazuh/sysmon/config/custom-sysmon-tuned.xml"
GROUP_NAME="windows_sysmon_tuned"

echo "=== Wazuh Centralized Sysmon Deployment ==="
echo "Target Manager: $SIEM1_HOST"
echo "Config: $CONFIG_SOURCE"
echo "Agent Group: $GROUP_NAME"
echo ""

# Verify config exists
if [ ! -f "$CONFIG_SOURCE" ]; then
    echo "ERROR: Config file not found: $CONFIG_SOURCE"
    exit 1
fi

echo "[1/6] Uploading Sysmon config to manager..."
sshpass -p "$SIEM1_PASS" scp -o StrictHostKeyChecking=no \
    "$CONFIG_SOURCE" "$SIEM1_USER@$SIEM1_HOST:/tmp/custom-sysmon-tuned.xml"

echo "[2/6] Creating shared folder structure..."
sshpass -p "$SIEM1_PASS" ssh -o StrictHostKeyChecking=no "$SIEM1_USER@$SIEM1_HOST" << 'EOSSH'
# Create group shared folder
sudo mkdir -p /var/ossec/etc/shared/windows_sysmon_tuned

# Move config to shared folder
sudo cp /tmp/custom-sysmon-tuned.xml /var/ossec/etc/shared/windows_sysmon_tuned/sysmon-tuned.xml

# Set permissions
sudo chown -R wazuh:wazuh /var/ossec/etc/shared/windows_sysmon_tuned
sudo chmod 750 /var/ossec/etc/shared/windows_sysmon_tuned
sudo chmod 640 /var/ossec/etc/shared/windows_sysmon_tuned/sysmon-tuned.xml

echo "Shared folder created: /var/ossec/etc/shared/windows_sysmon_tuned/"
ls -la /var/ossec/etc/shared/windows_sysmon_tuned/
EOSSH

echo "[3/6] Creating agent group..."
sshpass -p "$SIEM1_PASS" ssh -o StrictHostKeyChecking=no "$SIEM1_USER@$SIEM1_HOST" << 'EOSSH'
# Check if group exists
if sudo /var/ossec/bin/agent_groups -l -g windows_sysmon_tuned 2>/dev/null | grep -q "windows_sysmon_tuned"; then
    echo "Group 'windows_sysmon_tuned' already exists"
else
    sudo /var/ossec/bin/agent_groups -a -g windows_sysmon_tuned -q
    echo "Group 'windows_sysmon_tuned' created"
fi
EOSSH

echo "[4/6] Creating agent.conf with Sysmon update command..."
cat > /tmp/agent_sysmon.conf << 'EOFCONF'
<agent_config os="Windows">
  <!-- Sysmon Config Auto-Update -->
  <wodle name="command">
    <disabled>no</disabled>
    <tag>sysmon-config-update</tag>
    <command>powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { if (Test-Path 'C:\Program Files (x86)\Sysmon64.exe') { if (Test-Path 'C:\Program Files (x86)\ossec-agent\shared\sysmon-tuned.xml') { Copy-Item 'C:\Program Files (x86)\ossec-agent\shared\sysmon-tuned.xml' 'C:\Windows\Temp\sysmon-tuned.xml' -Force; $result = & 'C:\Program Files (x86)\Sysmon64.exe' -c 'C:\Windows\Temp\sysmon-tuned.xml' 2>&1; if ($LASTEXITCODE -eq 0) { Write-Output 'Sysmon config updated successfully' } else { Write-Output 'Sysmon config update failed' } } else { Write-Output 'Shared config not found' } } else { Write-Output 'Sysmon not installed' } } catch { Write-Output \"Error: $_\" }"</command>
    <interval>1d</interval>
    <ignore_output>no</ignore_output>
    <run_on_start>yes</run_on_start>
    <timeout>120</timeout>
  </wodle>

  <!-- Sysmon Health Check -->
  <wodle name="command">
    <disabled>no</disabled>
    <tag>sysmon-health-check</tag>
    <command>powershell.exe -NoProfile -Command "Get-Service -Name Sysmon64 -ErrorAction SilentlyContinue | Select-Object Status,StartType | ConvertTo-Json -Compress"</command>
    <interval>6h</interval>
    <ignore_output>no</ignore_output>
    <run_on_start>no</run_on_start>
    <timeout>30</timeout>
  </wodle>
</agent_config>
EOFCONF

sshpass -p "$SIEM1_PASS" scp -o StrictHostKeyChecking=no \
    /tmp/agent_sysmon.conf "$SIEM1_USER@$SIEM1_HOST:/tmp/agent_sysmon.conf"

sshpass -p "$SIEM1_PASS" ssh -o StrictHostKeyChecking=no "$SIEM1_USER@$SIEM1_HOST" << 'EOSSH'
# Create or update agent.conf in shared folder
AGENT_CONF="/var/ossec/etc/shared/windows_sysmon_tuned/agent.conf"

if [ -f "$AGENT_CONF" ]; then
    echo "Backing up existing agent.conf..."
    sudo cp "$AGENT_CONF" "${AGENT_CONF}.backup.$(date +%Y%m%d-%H%M%S)"
fi

sudo cp /tmp/agent_sysmon.conf "$AGENT_CONF"
sudo chown wazuh:wazuh "$AGENT_CONF"
sudo chmod 640 "$AGENT_CONF"

echo "agent.conf created: $AGENT_CONF"
EOSSH

echo "[5/6] Assigning pilot agent (002) to group..."
sshpass -p "$SIEM1_PASS" ssh -o StrictHostKeyChecking=no "$SIEM1_USER@$SIEM1_HOST" << 'EOSSH'
# Add agent 002 (WIN11-TESTBOX) to group
sudo /var/ossec/bin/agent_groups -a -i 002 -g windows_sysmon_tuned -q

# Verify assignment
echo "Agent 002 groups:"
sudo /var/ossec/bin/agent_groups -s -i 002
EOSSH

echo "[6/6] Restarting Wazuh manager to sync shared files..."
sshpass -p "$SIEM1_PASS" ssh -o StrictHostKeyChecking=no "$SIEM1_USER@$SIEM1_HOST" << 'EOSSH'
echo "Restarting wazuh-manager..."
sudo systemctl restart wazuh-manager

# Wait for restart
sleep 5

# Verify service status
sudo systemctl status wazuh-manager --no-pager | head -10
EOSSH

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Next steps:"
echo "1. Wait 5-10 minutes for agent 002 to sync shared files"
echo "2. Check agent 002 shared folder on Windows:"
echo "   dir 'C:\Program Files (x86)\ossec-agent\shared\sysmon-tuned.xml'"
echo "3. Manually trigger womodule on agent 002 or wait for next agent restart"
echo "4. Verify Sysmon config update on agent 002:"
echo "   C:\Windows\Sysmon64.exe -c"
echo "5. Check Wazuh logs for command output:"
echo "   tail -f /var/ossec/logs/ossec.log | grep -i sysmon"
echo ""
echo "To add more agents to the group:"
echo "  ssh $SIEM1_USER@$SIEM1_HOST 'sudo /var/ossec/bin/agent_groups -a -i AGENT_ID -g windows_sysmon_tuned'"
echo ""

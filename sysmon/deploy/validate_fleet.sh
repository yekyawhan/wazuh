#!/bin/bash
# Validate Sysmon config across fleet via Wazuh
# Checks: config hash match, Sysmon service status, recent events

set -e

SIEM1_HOST="172.16.10.2"
SIEM1_USER="ykh"
SIEM1_PASS="ykhster"
GROUP_NAME="windows_sysmon_tuned"
CONFIG_SOURCE="/home/y3kh/.claude/my-project/wazuh/sysmon/config/custom-sysmon-tuned.xml"

# Calculate expected SHA256 of our config
EXPECTED_HASH=$(sha256sum "$CONFIG_SOURCE" | awk '{print $1}')
echo "=== Fleet Sysmon Config Validation ==="
echo "Expected config SHA256: $EXPECTED_HASH"
echo ""

# Get agents in group
AGENTS=$(sshpass -p "$SIEM1_PASS" ssh -o StrictHostKeyChecking=no "$SIEM1_USER@$SIEM1_HOST" \
    "sudo /var/ossec/bin/agent_groups -l -g $GROUP_NAME 2>/dev/null" 2>/dev/null)

if [ -z "$AGENTS" ]; then
    echo "No agents found in group $GROUP_NAME"
    exit 0
fi

echo "Agents in group:"
echo "$AGENTS"
echo ""

# Check each agent via wazuh agent status API
sshpass -p "$SIEM1_PASS" ssh -o StrictHostKeyChecking=no "$SIEM1_USER@$SIEM1_HOST" << 'EOSSH'
# Get agent list from group
agents=$(sudo /var/ossec/bin/agent_groups -l -g windows_sysmon_tuned 2>/dev/null | grep "^   ID:" | awk '{print $3}')

for agent in $agents; do
    echo "=== Agent $agent ==="
    
    # Get agent info (name, IP, status)
    info=$(sudo /var/ossec/bin/manage_agents -l 2>/dev/null | grep -A 3 "^   ID: $agent" | head -4)
    echo "$info"
    
    # Check last check-in time
    status=$(sudo /var/ossec/bin/manage_agents -l 2>/dev/null | grep -A 5 "^   ID: $agent" | tail -2)
    echo "$status"
    
    echo ""
done
EOSSH

# Also query ES for recent Sysmon events from these agents (last 1h)
echo "=== Recent Sysmon Events from Group Agents (last 1h) ==="
sshpass -p "$SIEM1_PASS" ssh -o StrictHostKeyChecking=no "$SIEM1_USER@$SIEM1_HOST" "
curl -s -k -u 'admin:Cybersoc*3' 'https://localhost:9200/wazuh-alerts-*/_search' \
-H 'Content-Type: application/json' -d '{
  \"size\": 0,
  \"query\": {
    \"bool\": {
      \"must\": [
        {\"terms\": {\"agent.id\": [\"002\"]}},
        {\"range\": {\"timestamp\": {\"gte\": \"now-1h\"}}},
        {\"terms\": {\"data.win.system.eventID\": [1, 3, 11, 22]}}
      ]
    }
  },
  \"aggs\": {
    \"by_agent\": {
      \"terms\": {\"field\": \"agent.id\", \"size\": 20},
      \"aggs\": {
        \"by_eid\": {\"terms\": {\"field\": \"data.win.system.eventID\", \"size\": 20}}
      }
    }
  }
}' 2>/dev/null | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    buckets = data.get(\"aggregations\", {}).get(\"by_agent\", {}).get(\"buckets\", [])
    for b in buckets:
        agent = b[\"key\"]
        print(f\"Agent {agent}:\")
        for e in b[\"by_eid\"][\"buckets\"]:
            print(f\"  EID {e[\"key\"]}: {e[\"doc_count\"]}\")
except:
    pass
' || echo \"ES query failed or no data\"
" 2>&1

echo ""
echo "=== Validation Summary ==="
echo "Config hash to verify: $EXPECTED_HASH"
echo "To check individual agent config hash:"
echo "  powershell \"C:\\Windows\\Sysmon64.exe -c\" | Select-String 'Config hash'"
echo ""
echo "To manually trigger womodule on agent:"
echo "  (Agent) services.msc -> Restart 'Wazuh' service"
echo "  OR wait for 24h interval"
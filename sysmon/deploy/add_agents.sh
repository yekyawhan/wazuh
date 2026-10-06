#!/bin/bash
# Add Windows agents to Sysmon tuned group
# Usage: ./add_agents.sh <agent_id1> <agent_id2> ...

set -e

SIEM1_HOST="172.16.10.2"
SIEM1_USER="ykh"
SIEM1_PASS="${SIEM1_PASS:-}"  # Set via env or prompt
GROUP_NAME="windows_sysmon_tuned"

if [ $# -eq 0 ]; then
    echo "Usage: $0 <agent_id1> [agent_id2] [agent_id3] ..."
    echo "Example: $0 002 015 016 017"
    exit 1
fi

echo "=== Adding agents to group: $GROUP_NAME ==="
echo ""

for agent_id in "$@"; do
    echo "Processing agent $agent_id..."
    
    sshpass -p "$SIEM1_PASS" ssh -o StrictHostKeyChecking=no "$SIEM1_USER@$SIEM1_HOST" << EOSSH
# Check if agent exists
if ! sudo /var/ossec/bin/manage_agents -l 2>/dev/null | grep -q "^   ID: $agent_id"; then
    echo "  ERROR: Agent $agent_id not found"
    exit 1
fi

# Add to group
sudo /var/ossec/bin/agent_groups -a -i $agent_id -g $GROUP_NAME -q

# Verify
echo "  Agent $agent_id groups:"
sudo /var/ossec/bin/agent_groups -s -i $agent_id | grep -v "^$"
EOSSH
    
    echo ""
done

echo "=== Summary ==="
sshpass -p "$SIEM1_PASS" ssh -o StrictHostKeyChecking=no "$SIEM1_USER@$SIEM1_HOST" << 'EOSSH'
echo "Agents in $GROUP_NAME group:"
sudo /var/ossec/bin/agent_groups -l -g windows_sysmon_tuned 2>/dev/null || echo "Group is empty or does not exist"
EOSSH

echo ""
echo "Note: Agents will sync shared config within 5-10 minutes"
echo "Config will apply on next agent restart or womodule run (24h interval)"

#!/bin/bash

# ===============================================
# Wazuh Share Sync Linux Uninstaller
#
# Removes:
#   - systemd service
#   - systemd timer
#   - share-sync.sh binary
#
# Keeps:
#   - /var/ossec/active-response/bin/* (synced scripts)
#   - /var/ossec/logs/share-sync.log
# ===============================================

SERVICE_FILE="/etc/systemd/system/wazuh-share-sync.service"
TIMER_FILE="/etc/systemd/system/wazuh-share-sync.timer"
SCRIPT="/var/ossec/bin/share-sync.sh"

if [ "$EUID" -ne 0 ]
then
    echo "Run as root"
    exit 1
fi

echo "Stopping timer..."
systemctl stop wazuh-share-sync.timer 2>/dev/null

echo "Disabling timer..."
systemctl disable wazuh-share-sync.timer 2>/dev/null

echo "Removing service + timer..."
rm -f "$SERVICE_FILE"
rm -f "$TIMER_FILE"

echo "Removing share-sync.sh binary..."
rm -f "$SCRIPT"

systemctl daemon-reload
systemctl reset-failed 2>/dev/null

echo ""
echo "======================================"
echo " Wazuh Share Sync Uninstalled"
echo "======================================"

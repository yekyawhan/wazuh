#!/bin/bash

# ===============================================
# Wazuh Share Sync Installer Linux
#
# Install:
#   systemd service
#   systemd timer
#
# Run once per agent
# ===============================================


SERVICE_FILE="/etc/systemd/system/wazuh-share-sync.service"

TIMER_FILE="/etc/systemd/system/wazuh-share-sync.timer"


SCRIPT="/var/ossec/etc/shared/share-sync.sh"



if [ "$EUID" -ne 0 ]
then

    echo "Run as root"

    exit 1

fi



if [ ! -f "$SCRIPT" ]
then

    echo "Missing:"
    echo "$SCRIPT"

    exit 1

fi



chmod +x "$SCRIPT"



echo "Creating systemd service..."

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Wazuh Share Sync Service


[Service]
Type=oneshot
ExecStart=$SCRIPT

EOF




echo "Creating systemd timer..."

cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Wazuh Share Sync Timer


[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Unit=wazuh-share-sync.service


[Install]
WantedBy=timers.target

EOF



systemctl daemon-reload


systemctl enable wazuh-share-sync.timer


systemctl restart wazuh-share-sync.timer



echo ""
echo "======================================"
echo " Wazuh Share Sync Installed"
echo " Interval: 1 Minute"
echo " Service: wazuh-share-sync.service"
echo " Timer: wazuh-share-sync.timer"
echo "======================================"

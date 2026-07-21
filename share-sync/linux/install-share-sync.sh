#!/bin/bash

# ===============================================
# Wazuh Share Sync Installer Linux
#
# Install:
#   1. Copy share-sync.sh to /var/ossec/bin/ (PROTECTED from manager sync)
#   2. Run as ossec user (systemd hardening)
#   3. systemd service (oneshot) + timer (every 1 minute)
#
# Run once per agent
# Re-run safely — idempotent
# ===============================================

set -e

SOURCE_SCRIPT="/var/ossec/etc/shared/share-sync.sh"
DEST_SCRIPT="/var/ossec/bin/share-sync.sh"
DEST_DIR="/var/ossec/bin"
SERVICE_FILE="/etc/systemd/system/wazuh-share-sync.service"
TIMER_FILE="/etc/systemd/system/wazuh-share-sync.timer"

LOG_DIR="/var/ossec/logs"

if [ "$EUID" -ne 0 ]
then
    echo "Run as root"
    exit 1
fi

if [ ! -f "$SOURCE_SCRIPT" ]
then
    echo "Missing: $SOURCE_SCRIPT"
    echo "Copy share-sync.sh to /var/ossec/etc/shared/ first."
    exit 1
fi

# Wazuh AR runs as user 'ossec' group 'wazuh' (UID-based, fallback root)
if id ossec >/dev/null 2>&1
then
    RUN_USER="ossec"
    RUN_GROUP="wazuh"
else
    RUN_USER="root"
    RUN_GROUP="root"
fi

# ----- Deploy binary -----
# Binary: root:wazuh 0750 — wazuh group can read+exec (AR execution path),
# but manager-sync (ossec) cannot overwrite
mkdir -p "$DEST_DIR"
install -m 0750 -o root -g wazuh "$SOURCE_SCRIPT" "$DEST_SCRIPT" 2>/dev/null || \
install -m 0750 -o root "$SOURCE_SCRIPT" "$DEST_SCRIPT"

mkdir -p "$LOG_DIR"
touch "$LOG_DIR/share-sync.log"
chown "$RUN_USER:$RUN_GROUP" "$LOG_DIR/share-sync.log" 2>/dev/null || true

# ----- Create service -----
echo "Creating systemd service..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Wazuh Share Sync

[Service]
Type=oneshot
User=$RUN_USER
Group=$RUN_GROUP
ExecStart=$DEST_SCRIPT
StandardOutput=append:$LOG_DIR/share-sync.log
StandardError=append:$LOG_DIR/share-sync.log

# Hardening — service can only touch AR bin + log
ProtectSystem=strict
ProtectHome=yes
NoNewPrivileges=yes
ReadWritePaths=/var/ossec/active-response/bin /var/ossec/logs
EOF

# ----- Create timer -----
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
systemctl enable wazuh-share-sync.timer >/dev/null
systemctl restart wazuh-share-sync.timer

echo ""
echo "======================================"
echo " Wazuh Share Sync Installed"
echo " Binary: $DEST_SCRIPT"
echo " User: $RUN_USER"
echo " Timer: wazuh-share-sync.timer (every 1 min)"
echo "======================================"

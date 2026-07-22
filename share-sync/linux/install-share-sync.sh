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

SOURCE_SCRIPT="/var/ossec/etc/shared/share-sync/share-sync.sh"
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
    echo "Copy share-sync.sh to /var/ossec/etc/shared/share-sync/ first."
    exit 1
fi

# Service runs as root — the 'wazuh' account has /sbin/nologin, so a
# systemd User=wazuh unit fails with 203/EXEC. Root is also required to
# write root:wazuh files into active-response/bin/.
RUN_USER="root"
RUN_GROUP="root"

# ----- Deploy binary -----
# Binary: root:wazuh 0750 — wazuh group can read+exec (AR execution path),
# but manager-sync (ossec) cannot overwrite
mkdir -p "$DEST_DIR"
install -m 0750 -o root -g wazuh "$SOURCE_SCRIPT" "$DEST_SCRIPT"

mkdir -p "$LOG_DIR"
touch "$LOG_DIR/share-sync.log"
chown "$RUN_USER:$RUN_GROUP" "$LOG_DIR/share-sync.log" 2>/dev/null || true

# ----- Enable Wazuh remote commands (idempotent) -----
INTERNAL_OPTS="/var/ossec/etc/local_internal_options.conf"
CHANGED=0

mkdir -p "$(dirname "$INTERNAL_OPTS")"
touch "$INTERNAL_OPTS"

grep -qE '^\s*wazuh_command\.remote_commands\s*=\s*1' "$INTERNAL_OPTS" || {
    echo "wazuh_command.remote_commands=1" >> "$INTERNAL_OPTS"
    echo "Enabled wazuh_command.remote_commands=1"
    CHANGED=1
}

grep -qE '^\s*logcollector\.remote_commands\s*=\s*1' "$INTERNAL_OPTS" || {
    echo "logcollector.remote_commands=1" >> "$INTERNAL_OPTS"
    echo "Enabled logcollector.remote_commands=1"
    CHANGED=1
}

if [ "$CHANGED" = 1 ]
then
    echo "Restarting Wazuh (remote command config changed)..."
    systemctl restart wazuh-agent 2>/dev/null || systemctl restart wazuh-manager 2>/dev/null || true
fi

# ----- Create service -----
echo "Creating systemd service..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Wazuh Share Sync

[Service]
Type=oneshot
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

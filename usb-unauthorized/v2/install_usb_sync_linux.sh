#!/bin/bash

set -e

BASE="/usr/local/bin"

echo "[+] Installing Wazuh USB Sync v2"

mkdir -p $BASE


curl -fsSL \
https://raw.githubusercontent.com/yekyawhan/wazuh/git-home/usb-unauthorized/v2/hybrid_sync_usb_linux_v2.sh \
-o $BASE/hybrid_sync_usb_linux_v2.sh


chmod +x $BASE/hybrid_sync_usb_linux_v2.sh


cat > /etc/systemd/system/wazuh-usb-sync.service <<EOF
[Unit]
Description=Wazuh USB Whitelist Sync v2
After=wazuh-agent.service

[Service]
Type=oneshot
ExecStart=$BASE/hybrid_sync_usb_linux_v2.sh

EOF


cat > /etc/systemd/system/wazuh-usb-sync.path <<EOF
[Unit]
Description=Watch Wazuh USB whitelist changes

[Path]
PathChanged=/var/ossec/etc/shared/usb_whitelist.txt

[Install]
WantedBy=multi-user.target
EOF


systemctl daemon-reload

systemctl enable wazuh-usb-sync.service
systemctl enable --now wazuh-usb-sync.path


systemctl start wazuh-usb-sync.service


echo "[+] Installation completed"
echo "[+] USB whitelist sync is active"

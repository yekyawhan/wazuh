#!/bin/bash
#
# uninstall-suricata-ips.sh
# Reverts install-suricata-ips.sh: flushes the NFQUEUE chain, stops/removes
# the systemd unit, and removes the Wazuh localfile injection.
#
set -euo pipefail

NAME="suricata-ips"
QUEUE_NUM="$(awk -F= '/SURICATA_QUEUE/{print $2}' /etc/${NAME}.conf 2>/dev/null || echo 0)"
IFACE="$(awk -F= '/SURICATA_IFACE/{print $2}' /etc/${NAME}.conf 2>/dev/null || true)"
WAZUH_OSSEC="/var/ossec"

[ "$EUID" -eq 0 ] || { echo "[ERROR] run as root"; exit 1; }

echo "[+] Stopping ${NAME}..."
systemctl disable ${NAME} --now 2>/dev/null || true
rm -f /etc/systemd/system/${NAME}.service
systemctl daemon-reload

echo "[+] Flushing iptables SURICATA_IPS chain..."
iptables -w -D FORWARD -i "${IFACE}" -j SURICATA_IPS 2>/dev/null || true
iptables -w -D INPUT   -i "${IFACE}" -j SURICATA_IPS 2>/dev/null || true
iptables -w -F SURICATA_IPS 2>/dev/null || true
iptables -w -X SURICATA_IPS 2>/dev/null || true

if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save 2>/dev/null || true
fi

# Restore Wazuh ossec.conf
if [ -f "${WAZUH_OSSEC}/etc/ossec.conf.bak.suricata-ips" ]; then
    mv "${WAZUH_OSSEC}/etc/ossec.conf.bak.suricata-ips" "${WAZUH_OSSEC}/etc/ossec.conf"
    systemctl restart wazuh-agent 2>/dev/null || true
fi

rm -f /etc/${NAME}.conf
echo "[OK] Uninstalled."

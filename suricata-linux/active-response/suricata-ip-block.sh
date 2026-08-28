#!/bin/bash
#
# suricata-ip-block.sh
# ---------------------------------------------------------------------------
# Wazuh Active Response (Linux) for Suricata critical alerts.
# Reads stdin (alert JSON) and blocks the offending src_ip in iptables
# with a 1-hour cooldown -- prevents permanent lockouts from false positives.
#
# Usage (ossec.conf):
#   <active-response>
#     <command>suricata-ip-block</command>
#     <location>local</location>
#     <rules_id>100110</rules_id>
#     <timeout>3600</timeout>
#   </active-response>
# ---------------------------------------------------------------------------

set -uo pipefail

IPT="/sbin/iptables"
CHAIN="WAZUH_SURICATA_BLOCK"
TIMEOUT="${AR_TIMEOUT:-3600}"   # seconds
ACTION="${AR_ACTION:-add}"

[ "$EUID" -eq 0 ] || exit 1

ensure_chain() { $IPT -w -N "$CHAIN" 2>/dev/null || true; }
del_expired() {
    [ -f /tmp/suricata-ar-blocklist ] || return 0
    while read -r ts ip; do
        if [ -n "${ts:-}" ] && [ "$ts" -lt "$(date +%s)" ]; then
            $IPT -w -D "$CHAIN" -s "$ip" -j DROP 2>/dev/null || true
            sed -i "/^${ip} /d" /tmp/suricata-ar-blocklist 2>/dev/null || true
        fi
    done < /tmp/suricata-ar-blocklist 2>/dev/null
}

ensure_chain
del_expired

# Read alert JSON from stdin
ALERT="$(cat)"
SRC_IP="$(printf '%s' "$ALERT" | jq -r '..|objects|.src_ip? // .data?.src_ip? // .srcip? // empty' 2>/dev/null | head -1)"

[ -n "${SRC_IP:-}" ] || exit 0
# basic IP validation
[[ "$SRC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 0

case "$ACTION" in
    add)
        if $IPT -w -C "$CHAIN" -s "$SRC_IP" -j DROP 2>/dev/null; then
            exit 0   # already blocked
        fi
        $IPT -w -I "$CHAIN" -s "$SRC_IP" -j DROP
        $IPT -w -I FORWARD -j "$CHAIN" 2>/dev/null || true
        $IPT -w -I INPUT   -j "$CHAIN" 2>/dev/null || true
        expire=$(( $(date +%s) + TIMEOUT ))
        echo "${SRC_IP} ${expire}" >> /tmp/suricata-ar-blocklist
        echo "[suricata-ar] blocked ${SRC_IP} for ${TIMEOUT}s"
        ;;
    delete)
        $IPT -w -D "$CHAIN" -s "$SRC_IP" -j DROP 2>/dev/null || true
        sed -i "/^${SRC_IP} /d" /tmp/suricata-ar-blocklist 2>/dev/null || true
        ;;
esac

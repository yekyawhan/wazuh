#!/bin/bash
#
# uninstall-suricata-all.sh
# Single script that fully removes BOTH install-suricata-ips.sh and
# install-suricata-ids.sh, regardless of which one (or both) was installed.
# Idempotent: safe to run on a clean box -- reports "already clean".
#
# Removes: suricata-ips.service, suricata-ids.service, suricata-health.timer,
#          suricata-rules.timer, helpers in /usr/local/bin, /etc/suricata-*.conf,
#          iptables SURICATA_IPS chain + jump rules + persistent rules,
#          unmasks stock suricata.service, restores Wazuh ossec.conf backup.
#
# Optional: SURICATA_PURGE=1  -> also wipe /etc/suricata, /var/lib/suricata,
#                                 /var/log/suricata, logrotate, apt package.
#
set -uo pipefail

WAZUH_OSSEC="/var/ossec"
PURGE="${SURICATA_PURGE:-0}"
MODES="suricata-ips suricata-ids"

[ "$EUID" -eq 0 ] || { echo "[ERROR] run as root"; exit 1; }

IFACE="$(awk -F= '/^SURICATA_IFACE=/{print $2}' /etc/suricata-ips.conf /etc/suricata-ids.conf 2>/dev/null | head -1 || true)"
[ -n "$IFACE" ] || IFACE="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"

echo "=== Suricata full uninstall (IPS + IDS) ==="

# ---------------------------------------------------------------
# 1. Services + timers
# ---------------------------------------------------------------
FOUND_SVC=0
for NAME in $MODES; do
    if systemctl list-unit-files "${NAME}.service" --no-pager 2>/dev/null | grep -q "^${NAME}"; then
        echo "[+] Stopping ${NAME}..."
        systemctl disable "${NAME}" --now 2>/dev/null || true
        FOUND_SVC=1
    fi
    rm -f /etc/systemd/system/${NAME}.service
done

echo "[+] Stopping rule-refresh + health timers..."
systemctl stop    suricata-health.timer suricata-rules.timer 2>/dev/null || true
systemctl disable suricata-health.timer suricata-rules.timer 2>/dev/null || true
rm -f /etc/systemd/system/suricata-health.service \
      /etc/systemd/system/suricata-health.timer \
      /etc/systemd/system/suricata-rules.service \
      /etc/systemd/system/suricata-rules.timer
systemctl daemon-reload

# ---------------------------------------------------------------
# 2. iptables: jump rules (any iface) + chain + persistence
# ---------------------------------------------------------------
echo "[+] Cleaning iptables SURICATA_IPS..."
for IPT in iptables nft iptables-nft; do
    command -v "$IPT" >/dev/null 2>&1 || continue
    "$IPT" -w -S 2>/dev/null | awk '/-j SURICATA_IPS/ && !/^-N/ && !/^-A SURICATA_IPS/ {print}' | \
        while IFS= read -r rule; do
            "$IPT" -w $(printf '%s' "$rule" | sed 's/^-A /-D /') 2>/dev/null || true
        done
    "$IPT" -w -F SURICATA_IPS 2>/dev/null || true
    "$IPT" -w -X SURICATA_IPS 2>/dev/null || true
done

for f in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
    [ -f "$f" ] || continue
    if grep -q SURICATA_IPS "$f" 2>/dev/null; then
        cp "$f" "$f.bak.suricata-$(date +%Y%m%d)"
        sed -i '/SURICATA_IPS/d' "$f"
        command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent reload 2>/dev/null || true
    fi
done

# ---------------------------------------------------------------
# 3. Helpers + state files
# ---------------------------------------------------------------
echo "[+] Removing helpers + state..."
rm -f /usr/local/bin/suricata-health-monitor.sh \
      /usr/local/bin/refresh-suricata-rules.sh \
      /usr/local/bin/suricata-ar-dispatch.sh
for NAME in $MODES; do rm -f /etc/${NAME}.conf; done

# ---------------------------------------------------------------
# 4. Stock suricata.service: unmask (do NOT enable -- eth0 default crash-loops)
# ---------------------------------------------------------------
systemctl unmask suricata.service 2>/dev/null || true
systemctl daemon-reload
echo "    stock suricata.service: $(systemctl is-enabled suricata.service 2>/dev/null) (unmasked; start manually if wanted)"

# ---------------------------------------------------------------
# 5. Wazuh ossec.conf restore (any of our backups)
# ---------------------------------------------------------------
for b in "${WAZUH_OSSEC}/etc/ossec.conf.bak.suricata-ips" \
         "${WAZUH_OSSEC}/etc/ossec.conf.bak.suricata-ids" \
         "${WAZUH_OSSEC}/etc/ossec.conf.bak.suricata"; do
    if [ -f "$b" ]; then
        echo "[+] Restoring Wazuh ossec.conf from $(basename "$b")..."
        mv "$b" "${WAZUH_OSSEC}/etc/ossec.conf"
        systemctl restart wazuh-agent 2>/dev/null || true
        break
    fi
done

# ---------------------------------------------------------------
# 6. Optional full purge
# ---------------------------------------------------------------
if [ "$PURGE" = "1" ]; then
    echo "[+] PURGE: config, rules, logs, logrotate, package..."
    rm -f /etc/logrotate.d/suricata
    rm -rf /etc/suricata /var/lib/suricata /var/log/suricata /var/run/suricata*
    if command -v suricata >/dev/null 2>&1 && dpkg -l suricata >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y suricata 2>/dev/null || true
        apt-get autoremove -y 2>/dev/null || true
    fi
fi

# ---------------------------------------------------------------
# 7. Self-verify: prove nothing survived
# ---------------------------------------------------------------
echo "[=] Post-check:"
LEFT=""
for NAME in $MODES suricata-health suricata-rules; do
    systemctl list-unit-files "${NAME}.*" --no-pager 2>/dev/null | grep -q "^${NAME}\." && LEFT="$LEFT ${NAME}.unit"
    [ -e "/etc/systemd/system/${NAME}.service" ] || [ -e "/etc/systemd/system/${NAME}.timer" ] && LEFT="$LEFT ${NAME}.file"
done
iptables -w -S 2>/dev/null | grep -q SURICATA_IPS && LEFT="$LEFT iptables"
[ -f /usr/local/bin/refresh-suricata-rules.sh ] && LEFT="$LEFT helpers"
pgrep -x suricata >/dev/null 2>&1 && LEFT="$LEFT running-process"

if [ -z "$LEFT" ]; then
    echo "[OK] CLEAN — no IPS/IDS/timers/iptables/helpers left."
else
    echo "[WARN] leftovers:$LEFT"; exit 1
fi
[ "$PURGE" = "1" ] || echo "[i] Config/rules/logs kept. Rerun with SURICATA_PURGE=1 for full wipe."

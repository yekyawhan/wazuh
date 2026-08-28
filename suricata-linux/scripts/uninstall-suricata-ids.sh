#!/bin/bash
#
# uninstall-suricata-ids.sh
# ---------------------------------------------------------------------------
# Removes the IDS-only Suricata install (passive mode).
# No iptables to clean — IDS mode never touches netfilter.
# ---------------------------------------------------------------------------

set -euo pipefail

NAME="suricata-ids"
[ "$EUID" -eq 0 ] || { echo "[ERROR] Run as root (sudo)." >&2; exit 1; }

echo "[+] Stopping and disabling ${NAME}..."
systemctl stop ${NAME} 2>/dev/null || true
systemctl disable ${NAME} 2>/dev/null || true
rm -f /etc/systemd/system/${NAME}.service

echo "[+] Stopping timers..."
systemctl stop suricata-health.timer suricata-rules.timer 2>/dev/null || true
systemctl disable suricata-health.timer suricata-rules.timer 2>/dev/null || true
rm -f /etc/systemd/system/suricata-health.{service,timer}
rm -f /etc/systemd/system/suricata-rules.{service,timer}
rm -f /etc/logrotate.d/suricata

echo "[+] Removing Wazuh localfile entry..."
LOCAL="/var/ossec/etc/ossec.conf"
if grep -q "suricata/eve.json" "${LOCAL}" 2>/dev/null; then
    cp "${LOCAL}" "${LOCAL}.bak.uninstall-ids"
    python3 - <<'PY'
import re
p = "/var/ossec/etc/ossec.conf"
s = open(p).read()
s = re.sub(r'\s*<localfile>\s*<log_format>json</log_format>\s*<location>/var/log/suricata/eve\.json</location>\s*</localfile>', '', s)
open(p, "w").write(s)
PY
    systemctl restart wazuh-agent 2>/dev/null || true
fi

systemctl daemon-reload
echo "[OK] Suricata IDS removed. Config left at /etc/suricata/ (delete manually if wanted)."

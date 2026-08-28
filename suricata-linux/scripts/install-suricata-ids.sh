#!/bin/bash
#
# install-suricata-ids.sh
# ---------------------------------------------------------------------------
# IDS-ONLY (passive) Suricata installer for Linux (Wazuh sensor).
#
# Unlike install-suricata-ips.sh this does NOT use NFQUEUE or iptables.
# Suricata passively sniffs traffic via af-packet and logs alerts to
# eve.json which Wazuh forwards to the manager. No packets are ever
# dropped or delayed — safe for hypervisors and critical infrastructure.
#
# What it does:
#   1. Installs Suricata.
#   2. Configures af-packet passive capture on the target interface.
#   3. EVE JSON output → /var/log/suricata/eve.json.
#   4. Systemd unit with auto-restart.
#   5. Wazuh localfile registration for eve.json.
#   6. Health watchdog + rule refresh timers.
#
# Idempotent: re-running is safe.
# ---------------------------------------------------------------------------

set -euo pipefail

NAME="suricata-ids"
IFACE="${SURICATA_IFACE:-$(ip -o route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')}"
WAZUH_OSSEC="/var/ossec"
EVE_LOG="/var/log/suricata/eve.json"
CONFIG_DIR="/etc/suricata"

fail() { echo "[ERROR] $*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || fail "Run as root (sudo)."
[ -n "$IFACE" ] || fail "No interface detected. Set SURICATA_IFACE=<iface>."

echo "=============================================="
echo "   Suricata IDS-ONLY Installer (passive)"
echo "=============================================="
echo "[*] Interface : ${IFACE}"
echo "[*] Mode      : IDS (no NFQUEUE, no iptables, no blocking)"
echo ""

# ---------------------------------------------------------------
# 1. Install packages
# ---------------------------------------------------------------
echo "[+] Installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
    suricata \
    jq \
    python3 \
    ca-certificates

# Stop any conflicting suricata.service (Ubuntu ships one from the OISF pkg)
if systemctl list-unit-files suricata.service >/dev/null 2>&1; then
    systemctl stop suricata.service 2>/dev/null || true
    systemctl disable suricata.service 2>/dev/null || true
fi

# ---------------------------------------------------------------
# 2. Configure Suricata for passive af-packet + EVE JSON
# ---------------------------------------------------------------
echo "[+] Configuring Suricata (af-packet passive on ${IFACE})..."
cp -n "${CONFIG_DIR}/suricata.yaml" "${CONFIG_DIR}/suricata.yaml.orig" 2>/dev/null || true

python3 - <<PY
import re
p = "/etc/suricata/suricata.yaml"
s = open(p).read()

# Set af-packet interface
afp = """af-packet:
  - interface: ${IFACE}
    threads: auto
    cluster-id: 99
    cluster-type: cluster_flow
    defrag: yes
    use-mmap: yes
    mmap-locked: yes
"""
s = re.sub(r"af-packet:.*?(?=\n\S|\Z)", afp, s, flags=re.S)

# Ensure EVE JSON outputs to file (Wazuh reads it)
eve_block = """  - eve-log:
      enabled: yes
      filetype: regular
      filename: eve.json
      pcap-file: false
      types:
        - alert:
            metadata: yes
            tagged-packets: yes
        - anomaly:
        - http:
        - dns:
        - tls:
            extended: yes
        - flow
        - ssh
        - stats:
            totals: yes
"""
s = re.sub(r"  - eve-log:.*?(?=\n  - |\noutputs:|\Z)", eve_block, s, flags=re.S)

open(p, "w").write(s)
print("[+] suricata.yaml patched (IDS passive)")
PY

# ---------------------------------------------------------------
# 3. systemd unit
# ---------------------------------------------------------------
echo "[+] Installing systemd unit..."
cat > /etc/systemd/system/${NAME}.service <<EOF
[Unit]
Description=Suricata IDS (passive af-packet)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/suricata -c ${CONFIG_DIR}/suricata.yaml -i ${IFACE}
Restart=always
RestartSec=3
TimeoutStartSec=120
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ${NAME} --now
systemctl restart ${NAME}

# ---------------------------------------------------------------
# 4. Wazuh localfile forward of eve.json
# ---------------------------------------------------------------
if [ -d "${WAZUH_OSSEC}/etc" ]; then
    echo "[+] Registering Wazuh localfile for ${EVE_LOG}"
    LOCAL="${WAZUH_OSSEC}/etc/ossec.conf"
    if ! grep -q "suricata/eve.json" "${LOCAL}"; then
        cp "${LOCAL}" "${LOCAL}.bak.suricata-ids"
        python3 - <<PY
p = "${WAZUH_OSSEC}/etc/ossec.conf"
s = open(p).read()
block = '''  <ossec_config>
    <localfile>
      <log_format>json</log_format>
      <location>/var/log/suricata/eve.json</location>
    </localfile>'''
s = s.replace("<ossec_config>", block, 1)
open(p,"w").write(s)
PY
        systemctl restart wazuh-agent 2>/dev/null || true
    fi
fi

# ---------------------------------------------------------------
# 5. Health + rule refresh timers
# ---------------------------------------------------------------
echo "[+] Installing health watchdog + rule refresh timers..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

cp "${SCRIPT_DIR}/suricata-health-monitor.sh" /usr/local/bin/
cp "${SCRIPT_DIR}/refresh-suricata-rules.sh" /usr/local/bin/
chmod 755 /usr/local/bin/suricata-health-monitor.sh /usr/local/bin/refresh-suricata-rules.sh

cp "${BASE_DIR}/etc/suricata-health.service" /etc/systemd/system/
cp "${BASE_DIR}/etc/suricata-health.timer" /etc/systemd/system/
cp "${BASE_DIR}/etc/suricata-rules.service" /etc/systemd/system/
cp "${BASE_DIR}/etc/suricata-rules.timer" /etc/systemd/system/
cp "${BASE_DIR}/etc/suricata-logrotate" /etc/logrotate.d/suricata

systemctl daemon-reload
systemctl enable --now suricata-health.timer suricata-rules.timer

sleep 2
echo ""
echo "[OK] Suricata IDS active (passive, no blocking):"
systemctl is-active ${NAME} || true
echo ""
echo "Verify: tail -f /var/log/suricata/eve.json | jq 'select(.event_type==\"alert\")'"
echo "Uninstall: scripts/uninstall-suricata-ids.sh"

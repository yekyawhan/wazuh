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
# Interface selection (priority):
#   1. $SURICATA_IFACE env var (fleet deploys)
#   2. Interactive picker (TTY only, 10s timeout)
#   3. Auto-detect via default route
#
# Idempotent: re-running is safe.
# ---------------------------------------------------------------------------

set -euo pipefail

NAME="suricata-ids"
WAZUH_OSSEC="/var/ossec"
EVE_LOG="/var/log/suricata/eve.json"
CONFIG_DIR="/etc/suricata"

fail() { echo "[ERROR] $*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || fail "Run as root (sudo)."

# ---------------------------------------------------------------
# 0. Interface selection: env -> interactive (TTY) -> auto-detect
# ---------------------------------------------------------------
AUTO_IFACE="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
AUTO_IFACE="${AUTO_IFACE:-$(ip -o route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')}"

if [ -n "${SURICATA_IFACE:-}" ]; then
    IFACE="$SURICATA_IFACE"
elif [ -t 0 ] && [ -t 1 ]; then
    echo "Available interfaces on $(hostname):"
    ip -br link | awk '$1 != "lo" {printf "  [%d] %s  %s\n", ++n, $1, $2}'
    read -r -t 10 -p "Select interface [${AUTO_IFACE:-none}] (10s): " USER_IFACE || true
    IFACE="${USER_IFACE:-$AUTO_IFACE}"
else
    IFACE="$AUTO_IFACE"
fi

[ -n "$IFACE" ] || fail "No interface detected/selected. Set SURICATA_IFACE=<iface> or run from a TTY."
ip link show "$IFACE" >/dev/null 2>&1 || fail "Interface '$IFACE' does not exist on this host."

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
    systemctl mask suricata.service 2>/dev/null || true
fi

# ---------------------------------------------------------------
# 2. Configure Suricata for passive af-packet + EVE JSON
# ---------------------------------------------------------------
echo "[+] Configuring Suricata (af-packet passive on ${IFACE})..."
cp -n "${CONFIG_DIR}/suricata.yaml" "${CONFIG_DIR}/suricata.yaml.orig" 2>/dev/null || true

IFACE="${IFACE}" python3 - <<'PY'
import re, os
p = "/etc/suricata/suricata.yaml"
s = open(p).read()
iface = os.environ["IFACE"]

# Set af-packet interface block (anchored, multiline-safe)
afp = f"""af-packet:
  - interface: {iface}
    threads: auto
    cluster-id: 99
    cluster-type: cluster_flow
    defrag: yes
    use-mmap: yes
    mmap-locked: yes
"""

if re.search(r"(?m)^af-packet:", s):
    s = re.sub(r"(?m)^af-packet:.*?(?=\n[a-zA-Z0-9_#-]+:|\Z)", afp, s, flags=re.S)
else:
    s = s + "\n" + afp

# Ensure EVE JSON outputs to file (Wazuh reads it)
eve_block = '''  - eve-log:
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
            ja3-fingerprints: yes
        - flow
        - ssh
        - stats:
            totals: yes
'''
s = re.sub(r"  - eve-log:.*?(?=\n  - |\noutputs:|\Z)", eve_block, s, flags=re.S)

open(p, "w").write(s)
print(f"[+] suricata.yaml patched (IDS passive on {iface})")
PY

# ---------------------------------------------------------------
# 2b. Download ruleset (ET Open) via suricata-update
# ---------------------------------------------------------------
echo "[+] Fetching rules via suricata-update (ET Open)..."
suricata-update update-sources >/dev/null 2>&1 || true
suricata-update enable-source et/open >/dev/null 2>&1 || true
suricata-update || echo "[WARN] suricata-update failed — continuing"

# ---------------------------------------------------------------
# 2c. Validate config before starting service
# ---------------------------------------------------------------
echo "[+] Validating suricata.yaml + rules (suricata -T)..."
if ! suricata -T -c "${CONFIG_DIR}/suricata.yaml" >/tmp/suricata-T-ids.log 2>&1; then
    tail -20 /tmp/suricata-T-ids.log >&2
    fail "Config validation FAILED. See /tmp/suricata-T-ids.log."
fi
echo "[OK] Config validated."

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
import xml.etree.ElementTree as ET
p = "${WAZUH_OSSEC}/etc/ossec.conf"
tree = ET.parse(p)
root = tree.getroot()
lf = ET.SubElement(root, 'localfile')
ET.SubElement(lf, 'log_format').text = 'json'
ET.SubElement(lf, 'location').text = '/var/log/suricata/eve.json'
tree.write(p)
print("[+] localfile injected, XML valid")
PY
        python3 -c "import xml.etree.ElementTree as ET; ET.parse('${WAZUH_OSSEC}/etc/ossec.conf')" || fail "ossec.conf became invalid XML — restoring backup"
        systemctl restart wazuh-agent 2>/dev/null || true
    fi
fi

# ---------------------------------------------------------------
# 5. Health + rule refresh timers
# ---------------------------------------------------------------
echo "[+] Installing health watchdog + rule refresh timers..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

if [ -f "${SCRIPT_DIR}/suricata-health-monitor.sh" ]; then
    cp "${SCRIPT_DIR}/suricata-health-monitor.sh" /usr/local/bin/
    cp "${SCRIPT_DIR}/refresh-suricata-rules.sh" /usr/local/bin/
    chmod 755 /usr/local/bin/suricata-health-monitor.sh /usr/local/bin/refresh-suricata-rules.sh

    cp "${BASE_DIR}/etc/suricata-health.service" /etc/systemd/system/ 2>/dev/null || true
    cp "${BASE_DIR}/etc/suricata-health.timer" /etc/systemd/system/ 2>/dev/null || true
    cp "${BASE_DIR}/etc/suricata-rules.service" /etc/systemd/system/ 2>/dev/null || true
    cp "${BASE_DIR}/etc/suricata-rules.timer" /etc/systemd/system/ 2>/dev/null || true
    cp "${BASE_DIR}/etc/suricata-logrotate" /etc/logrotate.d/suricata 2>/dev/null || true

    systemctl daemon-reload
    systemctl enable --now suricata-health.timer suricata-rules.timer 2>/dev/null || true
fi

sleep 2
echo ""
echo "[OK] Suricata IDS active (passive, no blocking):"
systemctl is-active ${NAME} || true
echo ""
echo "Verify: tail -f /var/log/suricata/eve.json | jq 'select(.event_type==\"alert\")'"
echo "Uninstall: scripts/uninstall-suricata-ids.sh"

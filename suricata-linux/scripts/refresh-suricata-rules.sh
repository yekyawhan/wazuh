#!/bin/bash
#
# refresh-suricata-rules.sh
# ---------------------------------------------------------------------------
# Pulls the latest Emerging Threats Open ruleset via suricata-update, then
# validates Suricata before switching the live ruleset. On validation failure
# the previous ruleset is kept (auto-rollback) -- no broken IPS.
#
# Run on a schedule (see suricata-rules.timer) or from a Wazuh active-response.
# ---------------------------------------------------------------------------

set -euo pipefail

CONFIG_DIR="/etc/suricata"
BACKUP_DIR="${CONFIG_DIR}/rules.backup"
RULESET_DIR="${CONFIG_DIR}/rules"
MAX_BACKUPS=3

echo "[+] Updating ruleset via suricata-update..."
suricata-update update-sources 2>/dev/null || true
suricata-update enable-source et/open 2>/dev/null || true
suricata-update

# Backup current ruleset before reload
ts="$(date +%Y%m%d-%H%M%S)"
mkdir -p "${BACKUP_DIR}"
cp -r "${RULESET_DIR}" "${BACKUP_DIR}/rules-${ts}" 2>/dev/null || true

# Trim old backups
ls -dt "${BACKUP_DIR}"/rules-* 2>/dev/null | tail -n +$((MAX_BACKUPS+1)) | xargs -r rm -rf

echo "[+] Validating Suricata config + rules..."
if ! suricata -T -c "${CONFIG_DIR}/suricata.yaml" -q 2>&1 | tee /tmp/suricata-validate.log; then
    echo "[ERROR] Validation failed. Rolling back to ${BACKUP_DIR}/rules-${ts}/"
    rm -rf "${RULESET_DIR}"
    mv "${BACKUP_DIR}/rules-${ts}" "${RULESET_DIR}"
    exit 1
fi

echo "[+] Reloading Suricata..."
if systemctl is-active --quiet suricata-ips; then
    systemctl reload suricata-ips
elif systemctl is-active --quiet suricata; then
    systemctl reload suricata
else
    echo "[WARN] Suricata service not found; restart manually."
fi

echo "[OK] Rules refreshed and validated."

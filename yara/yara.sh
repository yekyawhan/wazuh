#!/bin/bash
# ==============================================================================
# Wazuh + YARA Production Installation / Upgrade Script
# ==============================================================================
#
# Author:
#   Ye Kyaw Han, Hsu Sandy Thein
#
# Target:
#   Ubuntu / Debian
#
# YARA:
#   4.5.8
#
# Features:
#   - Install / upgrade YARA from source
#   - Preserve existing YARA installation
#   - Download YARA rules from local repository
#   - Validate rules before activation
#   - Wazuh Active Response integration
#   - Automatic malware quarantine
#   - SHA256-based quarantine filename
#   - Collision-resistant quarantine
#   - Secure quarantine directory (root:root 700)
#   - Quarantined files (root:root 600)
#   - Executable permission removed
#   - Weekly YARA rule updates
#   - Daily quarantine cleanup (>30 days)
#   - Atomic rule replacement
#
# Installation log:
#   /var/log/yara-install.log
#
# Rule update log:
#   /var/log/yara-update.log
#
# Local Rules Repository:
#   http://10.3.11.48/rules/yara_rules.yar
#
# ==============================================================================

set -Eeuo pipefail

# ==============================================================================
# Configuration
# ==============================================================================

YARA_VERSION="4.5.8"
YARA_URL="https://github.com/VirusTotal/yara/archive/v${YARA_VERSION}.tar.gz"

YARA_PREFIX="/usr/local"
YARA_BIN="${YARA_PREFIX}/bin/yara"

RULES_SERVER="http://10.3.11.48/rules/yara_rules.yar"

RULES_DIR="/var/ossec/yara/rules"
RULES_FILE="${RULES_DIR}/yara_rules.yar"
RULES_TMP="${RULES_DIR}/.yara_rules.yar.tmp"

WAZUH_DIR="/var/ossec"

ACTIVE_RESPONSE_DIR="${WAZUH_DIR}/active-response"
ACTIVE_RESPONSE_BIN="${ACTIVE_RESPONSE_DIR}/bin"

YARA_RESPONSE="${ACTIVE_RESPONSE_BIN}/yara.sh"

QUARANTINE_DIR="${ACTIVE_RESPONSE_DIR}/quarantine"

INSTALL_LOG="/var/log/yara-install.log"
UPDATE_LOG="/var/log/yara-update.log"
ACTIVE_RESPONSE_LOG="${WAZUH_DIR}/logs/active-responses.log"

WORK_DIR="/tmp/yara-install"

CRON_UPDATE="30 23 * * 0 /usr/local/bin/update-yara-rules.sh"
CRON_CLEANUP="0 1 * * * /usr/local/bin/yara-quarantine-cleanup.sh"

# ==============================================================================
# Installation Log
# ==============================================================================

touch "$INSTALL_LOG"
chmod 640 "$INSTALL_LOG"
chown root:wazuh "$INSTALL_LOG" 2>/dev/null || true

# IMPORTANT:
# Do NOT use:
#   exec > >(tee -a "$INSTALL_LOG") 2>&1
#
# Installation log should contain only important final status.

install_log() {
    printf '[%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$*" >> "$INSTALL_LOG"
}

# ==============================================================================
# Error Handler
# ==============================================================================

error_handler() {
    local exit_code=$?
    local line_number=$1

    echo "ERROR: Installation failed at line ${line_number} (exit code ${exit_code})." >&2

    exit "$exit_code"
}

trap 'error_handler ${LINENO}' ERR

# ==============================================================================
# Root Check
# ==============================================================================

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Please run this script as root or using sudo." >&2
    exit 1
fi

# ==============================================================================
# Cleanup
# ==============================================================================

cleanup() {
    rm -rf "$WORK_DIR"
    rm -f "$RULES_TMP"
}

trap cleanup EXIT

mkdir -p "$WORK_DIR"

# ==============================================================================
# Dependency Installation
# ==============================================================================

echo "[*] Updating APT repositories..."

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq

echo "[*] Installing required dependencies..."

apt-get install -y -qq \
    make \
    gcc \
    autoconf \
    automake \
    libtool \
    libssl-dev \
    pkg-config \
    jq \
    curl \
    wget \
    tar \
    gzip

# ==============================================================================
# Detect Existing YARA
# ==============================================================================

CURRENT_YARA_VERSION=""

if command -v yara >/dev/null 2>&1; then
    CURRENT_YARA_VERSION="$(yara --version 2>/dev/null || true)"
fi

# ==============================================================================
# YARA Installation / Upgrade
# ==============================================================================

if [[ "$CURRENT_YARA_VERSION" == "$YARA_VERSION" ]]; then

    echo "[+] YARA ${YARA_VERSION} is already installed."

else

    if [[ -n "$CURRENT_YARA_VERSION" ]]; then
        echo "[*] Existing YARA version: ${CURRENT_YARA_VERSION}"
        echo "[*] Upgrading to YARA ${YARA_VERSION}..."
    else
        echo "[*] YARA is not installed."
        echo "[*] Installing YARA ${YARA_VERSION}..."
    fi

    cd "$WORK_DIR"

    SOURCE_ARCHIVE="yara-${YARA_VERSION}.tar.gz"
    SOURCE_DIR="yara-${YARA_VERSION}"

    echo "[*] Downloading YARA ${YARA_VERSION}..."

    curl -fsSL \
        --retry 3 \
        --connect-timeout 15 \
        --max-time 300 \
        -o "$SOURCE_ARCHIVE" \
        "$YARA_URL"

    echo "[*] Extracting YARA source..."

    tar -xzf "$SOURCE_ARCHIVE"

    cd "$SOURCE_DIR"

    echo "[*] Preparing build environment..."

    ./bootstrap.sh >/dev/null 2>&1

    echo "[*] Configuring YARA..."

    ./configure \
        --prefix="$YARA_PREFIX" \
        --sysconfdir=/etc \
        --localstatedir=/var \
        >/dev/null 2>&1

    echo "[*] Compiling YARA..."

    make -j"$(nproc)" >/dev/null 2>&1

    echo "[*] Installing YARA..."

    make install >/dev/null 2>&1

    # Update shared library cache.
    if ! grep -qE '^/usr/local/lib/?$' /etc/ld.so.conf; then
        echo "/usr/local/lib" >> /etc/ld.so.conf
    fi

    ldconfig

    hash -r

fi

# ==============================================================================
# YARA Binary Verification
# ==============================================================================

if [[ ! -x "$YARA_BIN" ]]; then

    if command -v yara >/dev/null 2>&1; then
        YARA_BIN="$(command -v yara)"
    else
        echo "ERROR: YARA binary not found." >&2
        exit 1
    fi

fi

FINAL_YARA_VERSION="$("$YARA_BIN" --version 2>/dev/null || true)"

if [[ "$FINAL_YARA_VERSION" != "$YARA_VERSION" ]]; then
    echo "ERROR: YARA version verification failed." >&2
    echo "Expected: ${YARA_VERSION}" >&2
    echo "Detected: ${FINAL_YARA_VERSION}" >&2
    exit 1
fi

# ==============================================================================
# YARA Installation Success Log
# ==============================================================================

# ONLY this installation status is written to /var/log/yara-install.log.
install_log "YARA is successfully installed (version ${FINAL_YARA_VERSION})"

# ==============================================================================
# Prepare Wazuh Directories
# ==============================================================================

echo "[*] Preparing Wazuh YARA directories..."

install -d \
    -m 750 \
    -o root \
    -g wazuh \
    "$RULES_DIR"

install -d \
    -m 750 \
    -o root \
    -g root \
    "$ACTIVE_RESPONSE_DIR"

install -d \
    -m 750 \
    -o root \
    -g root \
    "$ACTIVE_RESPONSE_BIN"

# ==============================================================================
# Download and Validate YARA Rules
# ==============================================================================

echo "[*] Downloading YARA rules from local repository..."

curl -fsSL \
    --retry 3 \
    --connect-timeout 10 \
    --max-time 120 \
    -o "$RULES_TMP" \
    "$RULES_SERVER"

if [[ ! -s "$RULES_TMP" ]]; then
    echo "ERROR: Downloaded YARA rules file is empty." >&2
    exit 1
fi

echo "[*] Validating YARA rules..."

if ! "$YARA_BIN" -w -r "$RULES_TMP" /dev/null >/dev/null 2>&1; then
    echo "ERROR: Downloaded YARA rules failed validation. Keeping previous ruleset." >&2
    rm -f "$RULES_TMP"
    exit 1
fi

# Atomic replacement.
mv -f "$RULES_TMP" "$RULES_FILE"

chmod 640 "$RULES_FILE"
chown root:wazuh "$RULES_FILE"

echo "[+] YARA rules installed successfully."

# ==============================================================================
# Create Wazuh YARA Active Response
# ==============================================================================

echo "[*] Creating Wazuh YARA Active Response..."

cat > "$YARA_RESPONSE" <<'YARA_EOF'
#!/bin/bash

# ==============================================================================
# Wazuh YARA Active Response
# ==============================================================================

set -u

LOG_FILE="/var/ossec/logs/active-responses.log"
QUARANTINE_DIR="/var/ossec/active-response/quarantine"

log() {
    printf '[%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$*" >> "$LOG_FILE"
}

# ==============================================================================
# Read Wazuh JSON
# ==============================================================================

if ! read -r INPUT_JSON; then
    log "wazuh-yara: ERROR - Failed to read Active Response input."
    exit 1
fi

# ==============================================================================
# Parse Parameters
# ==============================================================================

YARA_PATH="$(echo "$INPUT_JSON" | jq -r '.parameters.extra_args[1] // empty')"
YARA_RULES="$(echo "$INPUT_JSON" | jq -r '.parameters.extra_args[3] // empty')"
FILENAME="$(echo "$INPUT_JSON" | jq -r '.parameters.alert.syscheck.path // empty')"

# ==============================================================================
# Validate Parameters
# ==============================================================================

if [[ -z "$YARA_PATH" || -z "$YARA_RULES" || -z "$FILENAME" ]]; then
    log "wazuh-yara: ERROR - Missing YARA path, rules or filename."
    exit 1
fi

if [[ ! -x "${YARA_PATH}/yara" ]]; then
    log "wazuh-yara: ERROR - YARA executable not found: ${YARA_PATH}/yara"
    exit 1
fi

if [[ ! -f "$YARA_RULES" ]]; then
    log "wazuh-yara: ERROR - YARA rules file not found: ${YARA_RULES}"
    exit 1
fi

# ==============================================================================
# Check File
# ==============================================================================

if [[ ! -f "$FILENAME" ]]; then
    log "wazuh-yara: INFO - File no longer exists: ${FILENAME}"
    exit 0
fi

# ==============================================================================
# Wait for File to Stabilize
# ==============================================================================

previous_size=-1
current_size=0

for _ in {1..30}; do

    if [[ ! -f "$FILENAME" ]]; then
        log "wazuh-yara: INFO - File disappeared during stabilization: ${FILENAME}"
        exit 0
    fi

    current_size="$(stat -c %s "$FILENAME" 2>/dev/null || echo 0)"

    if [[ "$current_size" -eq "$previous_size" ]]; then
        break
    fi

    previous_size="$current_size"

    sleep 1
done

# ==============================================================================
# YARA Scan
# ==============================================================================

if [[ ! -f "$FILENAME" ]]; then
    log "wazuh-yara: INFO - File no longer exists: ${FILENAME}"
    exit 0
fi

YARA_OUTPUT="$(
    "${YARA_PATH}/yara" \
        -w \
        -r \
        "$YARA_RULES" \
        "$FILENAME" \
        2>&1
)"

YARA_EXIT=$?

if [[ "$YARA_EXIT" -gt 1 ]]; then
    log "wazuh-yara: ERROR - YARA scan failed: ${FILENAME}"
    log "wazuh-yara: ERROR - ${YARA_OUTPUT}"
    exit 1
fi

# ==============================================================================
# No Detection
# ==============================================================================

if [[ -z "$YARA_OUTPUT" ]]; then
    exit 0
fi

# ==============================================================================
# Detection Logging
# ==============================================================================

while IFS= read -r line; do

    [[ -z "$line" ]] && continue

    log "wazuh-yara: DETECTION - ${line}"

done <<< "$YARA_OUTPUT"

# ==============================================================================
# SKIP SYSTEM RULE FILES
# ==============================================================================
# Suricata/Snort/YARA rule files contain detection signatures that match
# YARA patterns but are NOT malware. Log the detection but do not quarantine.

case "$FILENAME" in
    *.rules|*.yar|*.yara)
        log "wazuh-yara: INFO - Skipping quarantine for system rule file: ${FILENAME}"
        exit 0
        ;;
esac

# ==============================================================================
# QUARANTINE
# ==============================================================================

if [[ ! -f "$FILENAME" ]]; then
    log "wazuh-yara: INFO - File disappeared before quarantine: ${FILENAME}"
    exit 0
fi

# Secure quarantine directory.
install -d \
    -m 700 \
    -o root \
    -g root \
    "$QUARANTINE_DIR"

BASENAME="$(basename -- "$FILENAME")"

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"

SHA256="$(sha256sum -- "$FILENAME" | awk '{print $1}')"

QUARANTINE_FILE="${QUARANTINE_DIR}/${TIMESTAMP}_${SHA256}_${BASENAME}"

# ==============================================================================
# Collision Protection
# ==============================================================================

COUNTER=1

while [[ -e "$QUARANTINE_FILE" ]]; do

    QUARANTINE_FILE="${QUARANTINE_DIR}/${TIMESTAMP}_${SHA256}_${COUNTER}_${BASENAME}"

    COUNTER=$((COUNTER + 1))

done

log "wazuh-yara: INFO - SHA256: ${SHA256}"

# ==============================================================================
# Move to Quarantine
# ==============================================================================

if mv -- "$FILENAME" "$QUARANTINE_FILE"; then

    # Remove ALL execute permissions.
    chmod 600 "$QUARANTINE_FILE"

    # Ensure quarantine file cannot be executed.
    chown root:root "$QUARANTINE_FILE"

    log "wazuh-yara: ACTION - File quarantined successfully: ${QUARANTINE_FILE}"

else

    log "wazuh-yara: ERROR - Failed to quarantine file: ${FILENAME}"

    exit 1

fi

exit 0
YARA_EOF

chmod 750 "$YARA_RESPONSE"
chown root:root "$YARA_RESPONSE"

# ==============================================================================
# Quarantine Hardening
# ==============================================================================

echo "[*] Hardening quarantine directory..."

install -d \
    -m 700 \
    -o root \
    -g root \
    "$QUARANTINE_DIR"

# ==============================================================================
# Create YARA Rules Update Script
# ==============================================================================

echo "[*] Creating YARA rules update script..."

cat > /usr/local/bin/update-yara-rules.sh <<'UPDATE_EOF'
#!/bin/bash

set -Eeuo pipefail

RULES_SERVER="http://10.3.11.48/rules/yara_rules.yar"

RULES_DIR="/var/ossec/yara/rules"
RULES_FILE="${RULES_DIR}/yara_rules.yar"
RULES_TMP="${RULES_DIR}/.yara_rules.yar.tmp"

UPDATE_LOG="/var/log/yara-update.log"

YARA_BIN="/usr/local/bin/yara"

log() {
    printf '[%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$*" >> "$UPDATE_LOG"
}

cleanup() {
    rm -f "$RULES_TMP"
}

trap cleanup EXIT

mkdir -p "$RULES_DIR"

touch "$UPDATE_LOG"
chmod 640 "$UPDATE_LOG"
chown root:wazuh "$UPDATE_LOG" 2>/dev/null || true

if [[ ! -x "$YARA_BIN" ]]; then
    log "ERROR: YARA binary not found: ${YARA_BIN}"
    exit 1
fi

log "Starting YARA rules update."

curl -fsSL \
    --retry 3 \
    --connect-timeout 10 \
    --max-time 120 \
    -o "$RULES_TMP" \
    "$RULES_SERVER"

if [[ ! -s "$RULES_TMP" ]]; then
    log "ERROR: Downloaded rules file is empty."
    exit 1
fi

if ! "$YARA_BIN" -w -r "$RULES_TMP" /dev/null >/dev/null 2>&1; then
    log "ERROR: New YARA rules failed validation."
    exit 1
fi

mv -f "$RULES_TMP" "$RULES_FILE"

chmod 640 "$RULES_FILE"
chown root:wazuh "$RULES_FILE"

log "YARA rules replaced successfully."

if systemctl restart wazuh-agent; then
    log "Wazuh agent restarted successfully."
else
    log "ERROR: Failed to restart Wazuh agent."
    exit 1
fi

log "YARA rules update completed successfully."
UPDATE_EOF

chmod 750 /usr/local/bin/update-yara-rules.sh
chown root:root /usr/local/bin/update-yara-rules.sh

# ==============================================================================
# Create Quarantine Cleanup Script
# ==============================================================================

echo "[*] Creating quarantine cleanup script..."

cat > /usr/local/bin/yara-quarantine-cleanup.sh <<'CLEANUP_EOF'
#!/bin/bash

set -Eeuo pipefail

QUARANTINE_DIR="/var/ossec/active-response/quarantine"

[[ -d "$QUARANTINE_DIR" ]] || exit 0

find "$QUARANTINE_DIR" \
    -xdev \
    -type f \
    -mtime +30 \
    -delete
CLEANUP_EOF

chmod 750 /usr/local/bin/yara-quarantine-cleanup.sh
chown root:root /usr/local/bin/yara-quarantine-cleanup.sh

# ==============================================================================
# Configure Cron
# ==============================================================================

echo "[*] Configuring cron jobs..."

CURRENT_CRONTAB="$(crontab -l 2>/dev/null || true)"

CURRENT_CRONTAB="$(
    echo "$CURRENT_CRONTAB" |
    grep -vF "/usr/local/bin/update-yara-rules.sh" ||
    true
)"

CURRENT_CRONTAB="$(
    echo "$CURRENT_CRONTAB" |
    grep -vF "/usr/local/bin/yara-quarantine-cleanup.sh" ||
    true
)"

{
    [[ -n "$CURRENT_CRONTAB" ]] && echo "$CURRENT_CRONTAB"
    echo "$CRON_UPDATE"
    echo "$CRON_CLEANUP"
} | crontab -

# ==============================================================================
# Final Validation
# ==============================================================================

echo "[*] Performing final validation..."

"$YARA_BIN" --version >/dev/null 2>&1

[[ -f "$RULES_FILE" ]]
[[ -x "$YARA_RESPONSE" ]]

[[ "$(stat -c '%a' "$QUARANTINE_DIR")" == "700" ]]
[[ "$(stat -c '%U:%G' "$QUARANTINE_DIR")" == "root:root" ]]

bash -n "$YARA_RESPONSE"
bash -n /usr/local/bin/update-yara-rules.sh
bash -n /usr/local/bin/yara-quarantine-cleanup.sh

# ==============================================================================
# Final Output
# ==============================================================================

echo
echo "=============================================================="
echo "Wazuh + YARA installation completed successfully"
echo "=============================================================="
echo
echo "YARA:"
echo "  Binary       : ${YARA_BIN}"
echo "  Version      : ${FINAL_YARA_VERSION}"
echo
echo "Rules:"
echo "  Source       : ${RULES_SERVER}"
echo "  Local file   : ${RULES_FILE}"
echo
echo "Active Response:"
echo "  Script       : ${YARA_RESPONSE}"
echo
echo "Quarantine:"
echo "  Directory    : ${QUARANTINE_DIR}"
echo "  Ownership    : root:root"
echo "  Directory    : 700"
echo "  Files        : 600"
echo "  Execute      : Disabled"
echo
echo "Logs:"
echo "  Installation : ${INSTALL_LOG}"
echo "  Rule update  : ${UPDATE_LOG}"
echo "  Active Resp. : ${ACTIVE_RESPONSE_LOG}"
echo
echo "Cron:"
echo "  Rules update : Sunday 23:30"
echo "  Cleanup      : Daily 01:00 (>30 days)"
echo
echo "=============================================================="

exit 0


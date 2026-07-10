#!/usr/bin/env bash
# enable-usb-sync.sh - one-time per-agent onboarding for the USB whitelist sync (Linux).
# Does everything needed on an agent in one run:
#   1. deploys hybrid_sync_usb_linux.sh into the Wazuh AR bin folder
#   2. enables logcollector.remote_commands=1 (REQUIRED - agents ignore the
#      manager's <command> without it; it can ONLY be set locally, by design)
#   3. restarts the Wazuh agent
#   4. runs the sync once to prove it works
#
# Run:  sudo ./enable-usb-sync.sh
# Uses hybrid_sync_usb_linux.sh next to this file if present, else downloads it.
set -euo pipefail

SYNC_URL="${SYNC_URL:-https://cdn.jsdelivr.net/gh/yekyawhan/wazuh@git-home/usb-unauthorized/hybrid_sync_usb_linux.sh}"
AGENT_DIR="/var/ossec"
BIN_DIR="$AGENT_DIR/active-response/bin"
DEST="$BIN_DIR/hybrid_sync_usb_linux.sh"
LIO="$AGENT_DIR/etc/local_internal_options.conf"
RUN_NOW=1
[[ "${1:-}" == "--skip-run" ]] && RUN_NOW=0

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)."; exit 1; }
[[ -d "$AGENT_DIR" ]] || { echo "Wazuh agent not found at $AGENT_DIR - is the agent installed?"; exit 1; }
mkdir -p "$BIN_DIR"

# 1. deploy the sync script (local copy next to this installer first, else download)
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo '')"
if [[ -n "$SELF_DIR" && -f "$SELF_DIR/hybrid_sync_usb_linux.sh" && "$SELF_DIR/hybrid_sync_usb_linux.sh" != "$DEST" ]]; then
    cp "$SELF_DIR/hybrid_sync_usb_linux.sh" "$DEST"
    echo "[1/4] deployed hybrid_sync_usb_linux.sh from local copy -> $DEST"
else
    curl -sL "$SYNC_URL" -o "$DEST"
    echo "[1/4] downloaded hybrid_sync_usb_linux.sh -> $DEST"
fi
chmod +x "$DEST"

# 2. enable remote commands (idempotent - can only be set locally on the agent)
touch "$LIO"
if grep -q '^\s*logcollector.remote_commands\s*=\s*1' "$LIO"; then
    echo "[2/4] logcollector.remote_commands=1 already set"
else
    echo 'logcollector.remote_commands=1' >> "$LIO"
    echo "[2/4] enabled logcollector.remote_commands=1"
fi

# 3. restart the agent so the new setting takes effect
if systemctl restart wazuh-agent 2>/dev/null; then
    echo "[3/4] wazuh-agent restarted (systemctl)"
else
    "$AGENT_DIR/bin/wazuh-control" restart >/dev/null 2>&1 && echo "[3/4] wazuh-agent restarted (wazuh-control)" || echo "[3/4] WARN: could not restart agent - restart it manually"
fi

# 4. run the sync once now to prove it works
if [[ "$RUN_NOW" -eq 1 ]]; then
    echo "[4/4] running sync once..."
    "$DEST" || true
else
    echo "[4/4] skipped immediate run (will run on the agent.conf schedule)"
fi

echo ""
echo "DONE - this agent is onboarded."
echo "Manager side (once): put usb_whitelist.txt in /var/ossec/etc/shared/default/ and add the agent.conf <command> block."
echo "If the sync said 'Whitelist file not found', that's expected until the manager pushes usb_whitelist.txt."

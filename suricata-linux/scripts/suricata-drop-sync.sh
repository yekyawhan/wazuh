#!/bin/bash
#
# suricata-drop-sync.sh
# ---------------------------------------------------------------------------
# Resolve the drop list from the Wazuh centralized share and keep
# /etc/suricata-drop.list in step with it, then re-apply + reload Suricata.
#
# Precedence (first match that exists wins the baseline, extras append):
#   suricata-drop.list.replace  -> complete replacement, baseline ignored
#   suricata-drop.list.production + suricata-drop.list.local (additive)
#
# Files live in <agent>/var/ossec/etc/shared/suricata-linux/etc/ which Wazuh
# fills from the agent's *group* directories, so a group that ships
# suricata-drop.list.local gets fleet baseline + its own extra drops, and one
# that ships .replace gets exactly its own list. Same path on every agent ->
# no group-name plumbing needed agent-side.
#
# Modes:
#   (default)    sync + apply + validate + reload if the list changed
#   --copy-only  sync the file only (caller does apply/reload) - used by
#                refresh-suricata-rules.sh
#   --force      apply/reload even if unchanged
#
# Triggered by suricata-drop-sync.path (share file write) and by
# refresh-suricata-rules.sh. Idempotent; no shared file = no-op.
# ---------------------------------------------------------------------------
set -uo pipefail

SHARED_DIR="${SHARED_DIR:-/var/ossec/etc/shared/suricata-linux/etc}"
BASE="${SHARED_DIR}/suricata-drop.list.production"
LOCAL="${SHARED_DIR}/suricata-drop.list.local"
REPLACE="${SHARED_DIR}/suricata-drop.list.replace"
LIVE="/etc/suricata-drop.list"
RULES="/var/lib/suricata/rules/suricata.rules"
CONFIG_DIR="/etc/suricata"
APPLY="/usr/local/bin/suricata-drop-apply.sh"

MODE="${1:-full}"

md5() { [ -f "$1" ] && md5sum "$1" | cut -d' ' -f1 || echo none; }

# ---- resolve desired content ------------------------------------------------
if [ -f "$REPLACE" ]; then
    SRC="$REPLACE"; MODE_DESC="replace"
elif [ -f "$BASE" ]; then
    SRC="$BASE"; MODE_DESC="baseline"
    [ -f "$LOCAL" ] && MODE_DESC="baseline+local"
else
    echo "[drop-sync] no shared drop list under ${SHARED_DIR}"
    [ "$MODE" = "--copy-only" ] && exit 0
    if [ "$MODE" != "--force" ]; then
        echo "[drop-sync] nothing to sync — skipping apply/reload"
        exit 0
    fi
    echo "[drop-sync] --force with no share list — applying current $LIVE"
    SRC=""
fi

if [ -n "$SRC" ]; then
    TMP="$(mktemp /tmp/suricata-drop.XXXXXX)"
    cat "$SRC" > "$TMP"
    if [ "$MODE_DESC" = "baseline+local" ]; then
        echo "" >> "$TMP"
        echo "# ---- group-local additions (from Wazuh share) ----" >> "$TMP"
        cat "$LOCAL" >> "$TMP"
    fi
    if [ "$(md5 "$TMP")" != "$(md5 "$LIVE")" ]; then
        if install -m 644 "$TMP" "$LIVE.new" 2>/dev/null && mv -f "$LIVE.new" "$LIVE"; then
            CHANGED=1
        else
            cp -p "$TMP" "$LIVE"
            CHANGED=1
        fi
        echo "[drop-sync] $LIVE updated from ${MODE_DESC} share list ($(grep -cvE '^\s*(#|$)' "$LIVE") entries)"
    else
        CHANGED=0
        echo "[drop-sync] $LIVE already in step with share (${MODE_DESC})"
    fi
    rm -f "$TMP"
else
    CHANGED=0
fi

[ "$MODE" = "--copy-only" ] && exit 0
if [ "$CHANGED" -eq 0 ] && [ "$MODE" != "--force" ]; then
    echo "[drop-sync] nothing changed — skipping apply/reload"
    exit 0
fi

# ---- apply + validate + reload ---------------------------------------------
[ -x "$APPLY" ] || { echo "[drop-sync] ERROR: $APPLY missing"; exit 1; }
[ -f "$RULES" ] || { echo "[drop-sync] ERROR: ruleset $RULES missing"; exit 1; }

echo "[drop-sync] applying drop list..."
"$APPLY" || true

if ! suricata -T -c "${CONFIG_DIR}/suricata.yaml" 2>&1 | tail -5; then
    echo "[drop-sync] ERROR: validation failed — live ruleset NOT reloaded"
    echo "[drop-sync] previous backup: $RULES.bak.drop-apply"
    exit 1
fi

echo "[drop-sync] reloading Suricata..."
if systemctl is-active --quiet suricata-ips; then
    systemctl kill -s USR2 suricata-ips.service
elif systemctl is-active --quiet suricata; then
    systemctl kill -s USR2 suricata.service
else
    echo "[drop-sync] WARN: no suricata service active — reload skipped"
fi

echo "[drop-sync] done: $(grep -c '^drop ' "$RULES") drop rules live"

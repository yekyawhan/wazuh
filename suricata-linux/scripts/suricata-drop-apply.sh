#!/bin/bash
#
# suricata-drop-apply.sh
# ---------------------------------------------------------------------------
# Flip `alert` -> `drop` in the LIVE ruleset for selected rules, so the
# inline engine itself verdict-drops packets (no Wazuh AR round-trip, no
# suricata-update drop.rules file). Works with plain ET Open.
#
# List file (default /etc/suricata-drop.list), one entry per line:
#   2034567                 # by SID
#   category:ET MALWARE     # whole category (prefix match on msg:"ET ...)
#   # comment               # ignored
# Missing/empty file = no-op (pure alert mode, ET Open default).
#
# Idempotent. Run AFTER rule generation, BEFORE `suricata -T` validation
# (installer 3c + refresh-suricata-rules.sh do this automatically).
# ---------------------------------------------------------------------------
set -uo pipefail

LIST="${DROP_LIST:-/etc/suricata-drop.list}"
RULES="${SURICATA_RULES:-/var/lib/suricata/rules/suricata.rules}"

[ -f "$RULES" ] || { echo "[drop-apply] ERROR: ruleset $RULES not found"; exit 1; }
if [ ! -f "$LIST" ]; then
    echo "[drop-apply] no $LIST — ruleset untouched (alert-only)"; exit 0
fi

mapfile -t ENTRIES < <(grep -vE '^\s*(#|$)' "$LIST")
if [ "${#ENTRIES[@]}" -eq 0 ]; then
    echo "[drop-apply] $LIST empty — ruleset untouched (alert-only)"; exit 0
fi

cp -p "$RULES" "$RULES.predrop" 2>/dev/null || true
changed=0
for e in "${ENTRIES[@]}"; do
    case "$e" in
        category:*)
            pat="${e#category:}"
            if grep -qE "^alert .*msg:\"${pat}" "$RULES"; then
                sed -i "/^alert .*msg:\"${pat}/ s/^alert /drop /" "$RULES"
                echo "    category '$pat' -> drop ($(grep -cE "^drop .*msg:\"${pat}" "$RULES") rules)"
                changed=$((changed+1))
            elif grep -qE "^drop .*msg:\"${pat}" "$RULES"; then
                echo "    category '$pat' already drop"
            else
                echo "[drop-apply] WARN: no rule matched category '$pat'"
            fi
            ;;
        [0-9]*)
            sid="${e%% *}"
            if grep -q "^alert .*; *sid:${sid};" "$RULES"; then
                sed -i "/sid:${sid};/ s/^alert /drop /" "$RULES"
                echo "    sid ${sid} -> drop"
                changed=$((changed+1))
            elif grep -q "^drop .*; *sid:${sid};" "$RULES"; then
                echo "    sid ${sid} already drop"
            else
                echo "[drop-apply] WARN: sid ${sid} not in ruleset (typo? rule disabled?)"
            fi
            ;;
        *) echo "[drop-apply] WARN: bad entry '$e' (use SID number or category:PREFIX)" ;;
    esac
done

echo "[drop-apply] $changed entr(y/ies) converted — drop rules now: $(grep -c '^drop ' "$RULES") / $(wc -l < "$RULES") lines"

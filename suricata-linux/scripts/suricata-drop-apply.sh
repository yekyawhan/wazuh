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
#   category:ET TROJAN      # whole category -> flips every rule whose
#                           # msg:"<PREFIX>..." starts with that category.
#                           # NB: ET Open puts `sid:` BEFORE `msg:`, so the
#                           # match is on the msg prefix, not sid adjacency.
#   # comment               # ignored (blank lines too)
# Missing/empty file = no-op (pure alert mode, ET Open default).
#
# Production list lives in git: etc/suricata-drop.list.production, copied to
# /etc/suricata-drop.list on the agents. This script is re-run by
# refresh-suricata-rules.sh every 6h (suricata-update regenerates the ruleset
# and would otherwise revert every drop back to alert).
#
# Idempotent — already-`drop` lines are never touched. Run AFTER rule
# generation, BEFORE `suricata -T` validation + suricata-ips restart (callers
# install-suricata-ips.sh 3c + refresh-suricata-rules.sh do that gate).
# ---------------------------------------------------------------------------
set -uo pipefail

LIST="${DROP_LIST:-/etc/suricata-drop.list}"
RULES="${SURICATA_RULES:-/var/lib/suricata/rules/suricata.rules}"

[ -f "$RULES" ] || { echo "[drop-apply] ERROR: ruleset $RULES not found"; exit 1; }
if [ ! -f "$LIST" ]; then
    echo "[drop-apply] no $LIST — ruleset untouched (alert-only)"; exit 0
fi

mapfile -t ENTRIES < <(grep -vE '^\s*(#|$)' "$LIST" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
if [ "${#ENTRIES[@]}" -eq 0 ]; then
    echo "[drop-apply] $LIST empty — ruleset untouched (alert-only)"; exit 0
fi

cp -p "$RULES" "$RULES.bak.drop-apply" 2>/dev/null || true

# chars that would break a BRE address / regex — reject instead of guessing
BAD_CHARS='][\\.^$*+?~"/'

entries_applied=0
rules_flipped=0
for e in "${ENTRIES[@]}"; do
    case "$e" in
        category:*)
            pat="${e#category:}"
            pat="${pat#"${pat%%[![:space:]]*}"}"          # ltrim
            [ -n "$pat" ] || { echo "[drop-apply] WARN: empty category in '$e'"; continue; }
            if printf '%s' "$pat" | LC_ALL=C grep -q "[$BAD_CHARS]"; then
                echo "[drop-apply] WARN: category '$pat' has sed/grep metachars — skipped"
                continue
            fi
            addr="\(msg:\"${pat}"                          # -E form: literal "(msg:"
            before=$(grep -cE "^drop [^ ]+ .*$addr" "$RULES" || true)
            sed -i -E "/$addr/ s/^alert /drop /" "$RULES"
            after=$(grep -cE "^drop [^ ]+ .*$addr" "$RULES" || true)
            n=$(( after - before ))
            if [ "$n" -gt 0 ]; then
                echo "    category '$pat' -> drop ($n rules)"
                entries_applied=$((entries_applied+1)); rules_flipped=$((rules_flipped+n))
            elif [ "$after" -gt 0 ]; then
                echo "    category '$pat' already drop ($after rules, 0 new)"
            else
                echo "[drop-apply] WARN: no rule matched category '$pat'"
            fi
            ;;
        [0-9]*)
            sid="${e%% *}"
            if ! printf '%s' "$sid" | LC_ALL=C grep -qE '^[0-9]+$'; then
                echo "[drop-apply] WARN: bad SID '$sid' — skipped"; continue
            fi
            addr=";[[:space:]]*sid:${sid};"
            before=$(grep -cE "^drop .*$addr" "$RULES" || true)
            sed -i -E "/$addr/ s/^alert /drop /" "$RULES"
            after=$(grep -cE "^drop .*$addr" "$RULES" || true)
            n=$(( after - before ))
            if [ "$n" -gt 0 ]; then
                echo "    sid ${sid} -> drop ($n rules)"
                entries_applied=$((entries_applied+1)); rules_flipped=$((rules_flipped+n))
            elif [ "$after" -gt 0 ]; then
                echo "    sid ${sid} already drop (0 new)"
            else
                echo "[drop-apply] WARN: sid ${sid} not in ruleset (typo? rule disabled?)"
            fi
            ;;
        *) echo "[drop-apply] WARN: bad entry '$e' (use SID number or category:PREFIX)" ;;
    esac
done

echo "[drop-apply] $entries_applied entr(y/ies) applied, $rules_flipped rules flipped — drop rules now: $(grep -c '^drop ' "$RULES" || true) / $(wc -l < "$RULES") lines"

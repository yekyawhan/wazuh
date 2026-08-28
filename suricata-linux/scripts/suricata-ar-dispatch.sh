#!/bin/bash
#
# suricata-ar-dispatch.sh
# ---------------------------------------------------------------------------
# Agent-side auto-block dispatcher. Tails /var/log/suricata/eve.json and, for
# every alert whose signature matches bruteforce / C2 / recon patterns, invokes
# suricata-ip-block.sh to drop the offender in iptables.
#
# This is what makes the inline IPS reactive WITHOUT requiring the Wazuh
# manager to push an active-response -- the agent decides on its own.
#
# Env / override (drop-in /etc/systemd/system/suricata-ar-dispatch.service.d/override.conf):
#   EVE_LOG       path to eve.json
#   AR_BIN        path to ip-block script
#   BLOCK_TIMEOUT seconds (default 3600)
#   WHITELIST     space-separated CIDR list that must NEVER be blocked
# ---------------------------------------------------------------------------

set -uo pipefail

EVE_LOG="${EVE_LOG:-/var/log/suricata/eve.json}"
AR_BIN="${AR_BIN:-/usr/local/bin/suricata-ip-block.sh}"
BLOCK_TIMEOUT="${BLOCK_TIMEOUT:-3600}"
# Never block these (default gateway, mgmt, RFC1918 you trust, etc.)
WHITELIST="${WHITELIST:-127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16}"

[ "$EUID" -eq 0 ] || { echo "[ERROR] run as root"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "[ERROR] jq missing"; exit 1; }
[ -f "$AR_BIN" ] || { echo "[ERROR] AR_BIN $AR_BIN not found"; exit 1; }

# Patterns that justify an immediate block. Kept aligned with rules 100160/161/162.
pat_brute='brute|bruteforce|dictionary|repeated auth|login attempt|password guessing|ET SCAN (.*)Login'
pat_c2='C2|command and control|beacon|callback|cobalt strike|meterpreter|reverse shell|dnscat|empire|malware'
pat_recon='scan|recon|port scan|ET SCAN|suspicious connection|possible exploit'
all_pat="(${pat_brute})|(${pat_c2})|(${pat_recon})"

ip_in_cidr() { # ip cidr -> 0 if inside
    local ip="$1" net="$2"
    local ipn netn mask bits
    ipn=$(printf '%d' 0x$(printf "$ip" | awk -F. '{print sprintf("%02X%02X%02X%02X",$1,$2,$3,$4)}') 2>/dev/null) || return 1
    bits=${net#*/}; net=${net%/*}
    netn=$(printf '%d' 0x$(printf "$net" | awk -F. '{print sprintf("%02X%02X%02X%02X",$1,$2,$3,$4)}') 2>/dev/null) || return 1
    mask=$(( (0xFFFFFFFF << (32-bits)) & 0xFFFFFFFF ))
    [ $((ipn & mask)) -eq $((netn & mask)) ]
}

is_whitelisted() {
    local ip="$1"
    for c in $WHITELIST; do
        if ip_in_cidr "$ip" "$c"; then return 0; fi
    done
    return 1
}

block() {
    local ip="$1" why="$2"
    if is_whitelisted "$ip"; then
        echo "[dispatch] SKIP whitelisted $ip ($why)"
        return
    fi
    echo "[dispatch] BLOCK $ip ($why)"
    AR_TIMEOUT="$BLOCK_TIMEOUT" AR_ACTION=add \
        printf '{"src_ip":"%s","reason":"%s"}' "$ip" "$why" | "$AR_BIN"
}

echo "[dispatch] watching $EVE_LOG"
tail -n 0 -F "$EVE_LOG" 2>/dev/null | while IFS= read -r line; do
    # Only alert events, fast pre-filter
    case "$line" in
        *'"event_type":"alert"'*) ;;
        *) continue ;;
    esac

    sig="$(printf '%s' "$line" | jq -r '.alert.signature // empty' 2>/dev/null)"
    [ -n "$sig" ] || continue

    # Already-blocked check is inside suricata-ip-block.sh; just dispatch.
    if printf '%s' "$sig" | grep -Eiq "$all_pat"; then
        ip="$(printf '%s' "$line" | jq -r '.src_ip // empty' 2>/dev/null)"
        [ -n "$ip" ] || continue
        if printf '%s' "$sig" | grep -Eiq "$pat_c2"; then
            block "$ip" "C2:$sig"
        elif printf '%s' "$sig" | grep -Eiq "$pat_brute"; then
            block "$ip" "BRUTE:$sig"
        else
            block "$ip" "RECON:$sig"
        fi
    fi
done

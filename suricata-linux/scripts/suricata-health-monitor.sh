#!/bin/bash
#
# suricata-health-monitor.sh
# ---------------------------------------------------------------------------
# Lightweight watchdog for the Suricata IPS / IDS engine.
#
# Checks:
#   - suricata process alive
#   - NFQUEUE still draining (queue not backed up / overloaded)
#   - eve.json is being written (freshness)
#   - disk usage on the eve.log partition
#
# Emits a Wazuh-compatible JSON line to stdout (piped to a localfile) so the
# manager can alert on agent-side health without SSH.
#
# Install: copy to /usr/local/bin/, enable the systemd timer
#          (suricata-health.timer) shipped alongside this.
# ---------------------------------------------------------------------------

set -uo pipefail

EVE_LOG="${EVE_LOG:-/var/log/suricata/eve.json}"
QUEUE_NUM="${SURICATA_QUEUE:-0}"
THRESHOLD_AGE_SEC="${THRESHOLD_AGE_SEC:-120}"
DISK_WARN_PCT="${DISK_WARN_PCT:-90}"
AGENT_NAME="$(hostname)"
NOW="$(date +%s)"

status="ok"
messages=()

# --- process alive ---
# Suricata's main thread shows as comm "Suricata-Main" (not "suricata"),
# so match by the running binary path to be robust to thread renames.
if ! pgrep -f '/usr/bin/suricata .*-q' >/dev/null 2>&1; then
    status="critical"
    messages+=("suricata process not running")
fi

# --- eve.json freshness ---
if [ -f "$EVE_LOG" ]; then
    last_mod="$(stat -c %Y "$EVE_LOG" 2>/dev/null || echo 0)"
    age=$(( NOW - last_mod ))
    if [ "$age" -gt "$THRESHOLD_AGE_SEC" ]; then
        status="warning"
        messages+=("eve.json stale (${age}s old)")
    fi
else
    status="warning"
    messages+=("eve.json missing")
fi

# --- NFQUEUE backlog (kernel queue not draining) ---
# /proc/net/netfilter/nfnetlink_queue columns: Q peer pid ... (field 8 = backlog)
if [ -r /proc/net/netfilter/nfnetlink_queue ]; then
    qline="$(awk -v q="$QUEUE_NUM" '$1==q {print $8}' /proc/net/netfilter/nfnetlink_queue 2>/dev/null)"
    if [ -n "$qline" ] && [ "${qline:-0}" -gt 1000 ]; then
        status="warning"
        messages+=("nfqueue ${QUEUE_NUM} backlog ${qline}")
    fi
fi

# --- disk ---
disk_pct="$(df --output=pcent "$EVE_LOG" 2>/dev/null | tail -1 | tr -dc '0-9')"
if [ -n "${disk_pct:-}" ] && [ "${disk_pct:-0}" -ge "${DISK_WARN_PCT}" ]; then
    status="critical"
    messages+=("disk ${disk_pct}% full")
fi

# --- emit JSON for Wazuh localfile ---
printf '{"suricata_health":{"agent":"%s","status":"%s","queue":%s,"messages":[%s],"ts":%s}}\n' \
    "$AGENT_NAME" "$status" "$QUEUE_NUM" \
    "$(IFS=,; printf '"%s"' "${messages[@]}")" "$NOW"

exit 0

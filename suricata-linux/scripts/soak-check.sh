#!/usr/bin/env bash
# soak-check.sh — run FROM siem2 (ssh securityadmin@100.120.44.85 "bash -s" < soak-check.sh)
# One-shot snapshot of the testbox2 72h soak. Prints a compact report block.
set -u
T=cyber@10.3.11.49
S() { ssh -o BatchMode=yes -o ConnectTimeout=8 $T "$@"; }

echo "=== SURICATA IPS SOAK CHECK $(date -u +%FT%TZ) ==="
IPS=$(S "systemctl is-active suricata-ips")
WAZ=$(S "systemctl is-active wazuh-agent")
DSP=$(S "systemctl is-active suricata-ar-dispatch")
echo "services: suricata-ips=$IPS wazuh-agent=$WAZ ar-dispatch=$DSP"

BLK=$(S "grep -o '\"action\":\"blocked\"' /var/log/suricata/eve.json | wc -l")
EVE_AGE=$(S "echo \$(( \$(date +%s) - \$(stat -c %Y /var/log/suricata/eve.json) ))")
DROPN=$(S "grep -c '^drop ' /var/lib/suricata/rules/suricata.rules")
TOTAL=$(S "wc -l < /var/lib/suricata/rules/suricata.rules")
ACCEPT=$(S "tail -200 /var/log/suricata/stats.log | grep -m1 'ips.accepted' | awk '{print \$NF}'")
IPSB=$(S "tail -200 /var/log/suricata/stats.log | grep -m1 'ips.blocked' | awk '{print \$NF}' || echo 0")
[ -z "$IPSB" ] && IPSB=0
echo "ruleset: drop=$DROPN / $TOTAL lines | ips.accepted=$ACCEPT ips.blocked=$IPSB"
echo "eve.json: blocked-actions=$BLK age=${EVE_AGE}s"

# drop-list vs live mismatch check (production list must be fully applied)
EXPECT=$(S "grep -vE '^\s*(#|\$)' /etc/suricata-drop.list | wc -l")
MISMATCH=$(S 'cnt=0
for c in "ET MALWARE" "ET CNC"; do
  a=$(grep -c "^alert .*msg:\"$c" /var/lib/suricata/rules/suricata.rules)
  cnt=$((cnt+a))
done
echo $cnt')
echo "drop-list: entries=$EXPECT | unconverted MALWARE/CNC alerts=$MISMATCH"

# health timer + last monitor status
HM=$(S "sudo journalctl -u suricata-health.service -n 40 --no-pager | grep -o '\"status\":\"[a-z]*\"' | tail -1")
echo "health last: ${HM:-no-runs}"

# engine zombie check: accepted must be climbing OR low traffic (can't fully separate; report age)
DISK=$(S "df --output=pcent /var/log/suricata | tail -1 | tr -dc '0-9'")
echo "disk /var/log/suricata: ${DISK}%"
echo "=== END ==="

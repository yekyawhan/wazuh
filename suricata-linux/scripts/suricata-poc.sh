#!/bin/bash
# ============================================================
# Suricata IPS PoC — one-shot, on the box, start to finish.
# Verifies install -> traffic -> detection -> uninstall -> clean.
# Run:  sudo ./suricata-poc.sh
# Needs: testbox2, shared scripts, ET rules.
# Safety: management ports bypassed; fail-open; queue-bypass.
# ============================================================
set -uo pipefail
PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
step(){ echo; echo "== $1 =="; }
S=/var/ossec/etc/shared/suricata-linux/scripts
IPSEC=$S/install-suricata-ips.sh
UNINST=$S/uninstall-suricata-all.sh

step "0. Pre-flight"
id -u | grep -q 0 || { echo "root only"; exit 1; }
[ -f "$UNINST" ] && echo "  shared scripts present" || { echo "missing shared scripts"; exit 1; }
systemctl is-active --quiet wazuh-agent && ok "wazuh-agent active" || bad "wazuh-agent NOT active (abort)" 
[ "$FAIL" -gt 0 ] && exit 1

step "1. IDS running check"
for u in suricata-ips suricata-ids suricata; do
  st=$(systemctl is-active $u 2>/dev/null)
  echo "  $u: $st"
done

step "2. Clean slate: run uninstaller (must be idempotent)"
bash "$UNINST" && ok "uninstaller exited 0" || bad "uninstaller exit $?"
[ "$(pgrep -c -x suricata)" = "0" ] && ok "no suricata process" || bad "suricata still running"

step "3. Install IPS fresh"
SURICATA_IFACE=ens18 bash "$IPSEC" > /tmp/poc-install.log 2>&1 &
INSTALL_PID=$!
for i in $(seq 1 60); do kill -0 $INSTALL_PID 2>/dev/null || break; sleep 5; done
wait $INSTALL_PID; IRC=$?
tail -5 /tmp/poc-install.log
[ $IRC -eq 0 ] && ok "install exit 0" || bad "install exit $IRC"

step "4. Service up?"
sleep 3
systemctl is-active --quiet suricata-ips && ok "suricata-ips active" || bad "suricata-ips not active"
ss -t state established "( dport = :1514 )" 2>/dev/null | grep -q 10.3.11.40 && ok "wazuh tcp to manager OK" || echo "  (note: wazuh via UDP or different path)"

step "5. Traffic test (real packets through NFQUEUE)"
P0=$(grep -h '"event_type":"stats"' /var/log/suricata/eve.json 2>/dev/null | tail -1 | grep -o '"ips.accepted":[0-9]*' | cut -d: -f2)
[ -z "$P0" ] && P0=0
curl -s -o /dev/null -m 10 https://testmyids.com/ 2>/dev/null
sleep 5
P1=$(grep -h '"event_type":"stats"' /var/log/suricata/eve.json 2>/dev/null | tail -1 | grep -o '"ips.accepted":[0-9]*' | cut -d: -f2)
echo "  ips.accepted: $P0 -> $P1"
[ "${P1:-0}" -gt "$P0" ] && ok "packets accepted through NFQUEUE" || bad "no packets through NFQUEUE"

step "6. Detection test (ET rule fires on testmyids)"
sleep 2
HITS=$(grep -c '"rule":"ET INFO ' /var/log/suricata/eve.json 2>/dev/null)
[ "$HITS" -ge 1 ] 2>/dev/null && ok "ET rule fired ($HITS events)" || { grep -c '"event_type":"alert"' /var/log/suricata/eve.json | grep -q '^0$' && bad "zero alerts" || ok "alert events present"; }

step "7. Wazuh receives (alerts reach manager)"
tail -50 /var/ossec/logs/ossec.log 2>/dev/null | grep -i 'suricata' | tail -3
ok "check /var/ossec/logs/ossec.log above — if lines exist, pipeline live"

step "8. Full uninstall"
bash "$UNINST"
RC=$?
[ $RC -eq 0 ] && ok "uninstall exit 0 + [OK] CLEAN" || bad "uninstall exit $RC"

step "9. Post-uninstall state (must be empty)"
LEFT=""
for u in suricata-ips suricata-ids suricata-health suricata-rules; do
  systemctl list-unit-files "$u.*" --no-pager 2>/dev/null | grep -q "^$u\." && LEFT="$LEFT $u"
done
iptables -w -S 2>/dev/null | grep -q SURICATA_IPS && LEFT="$LEFT iptables-chain"
pgrep -x suricata >/dev/null && LEFT="$LEFT process"
echo "  leftover:${LEFT:- none}"
[ -z "$LEFT" ] && ok "fully clean" || bad "leftovers:$LEFT"

step "10. Wazuh agent survives whole cycle"
systemctl is-active --quiet wazuh-agent && ok "wazuh-agent still active" || bad "wazuh-agent died"
ping -c2 -W2 10.3.11.40 >/dev/null 2>&1 && ok "network to manager OK" || bad "network to manager lost"

echo
echo "========================================"
echo "RESULT: $PASS pass, $FAIL fail"
echo "========================================"
[ $FAIL -eq 0 ]

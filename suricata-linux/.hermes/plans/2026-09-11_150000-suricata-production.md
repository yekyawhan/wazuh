# Suricata IPS Production Plan (siem2 fleet 81 agents)

> **For Hermes:** Use suricata-inline-ips-wazuh + wazuh-n8n-alert-pipeline + wazuh-custom-rules-integrations skills. Task-by-task, live-verify each step on testbox2 before fleet.

**Goal:** suricata-linux pipeline ကို 1-box pilot ကနေ production fleet (81 agents) အပြည့် professional-grade တင်မြှင့်။

**Architecture:** 4-layer defense — (L1) engine packet-drop via drop.list, (L2) AR dispatcher host-firewall auto-block, (L3) Wazuh detection rules + central alerting, (L4) n8n SOAR (notify/enrich/digest, not blocking)။ Blocking က အောက်က layer တွေမှာတည်ရှိပြီး n8n က အပေါ်ဆုံး orchestrator သာ။

**Tech Stack:** Suricata 7 (NFQUEUE), Wazuh 4.x manager siem2, n8n (siem2 :5678), ET Open + drop.list conversion (commit dd0a1f8)။

---

## Phase 0 — Manager-side rules (fleet မချရသီး လုပ်ရမယ့်အရင်ဆုံး)

မလုပ်ရင် blind deployment ဖြစ် — box ၇၀ ကျော်မှာ IPS လုပ်နေစဉ် manager က ဘာမှမမြင်ရ။

### Task 1: Drop-event detection rules (`rules/suricata-rules.xml`)

`data.alert.action` = `blocked` ဖြစ်တဲ့ event တွေကို high-severity (level 12-14) rule အသစ် — IPS တကယ် packet ဖြတ်တယ်ဆိုတာ ချက်ချင်းသိရမယ်။

- Create: rule `100170` (existing 100160-162 နောက်ထပ်) — `<field name="data.alert.action">blocked</field>` + if_sid parent 100100 ခေါက်။
- `wazuh-logtest` နဲ့ eve.json blocked line တကယ် feed လုပ်စစ် (testbox2 `/var/log/suricata/eve.json` ထဲက ရိုးရိုး line)။
- Deploy: siem2 `/var/ossec/etc/rules/` + `wazuh-analysisd -t` exit 0 + restart analysisd (offline-validate-then-restart rule per skill)။
- Duplicate-ID sweep: `grep -rn 'id="100170"' /var/ossec/etc/rules/` ပထမဆုံး။

### Task 2: Health/blackout detection rules

IPS ကွယ်ရင် ဘယ်သူမှမသိ — detection blackout alert:
- suricata-ips service down (agent systemd log "inactive/failed")
- `ips.accepted` delta = 0 over 2 timer ticks (engine zombie)
- wazuh-agent disconnect (built-in rules ရှိ — link ချိတ်ဆက်သာ)
- rules count drop (rules file ပြန်ဆောက်ပြီး < 1000 rules)

Create: `etc/suricata-health-alerts.xml` sample event lines + matching rules (100171-100174) — health-monitor script (existing) JSON event ထုတ်ပုံနဲ့ ကိုက်အောင်။ logtest နဲ့ verify။

### Task 3: JA3-hit rule

fbad794 မှာ JA3 hash ရပြီး — eve.json `tls.ja3.hash` မှာ known-bad (Cobalt Strike default ja3 အစရှိ) match လုပ်တဲ့ rule 100175 (level 14) — C2 callback အမြန်ဆုံး signal။ JA3 feed = MISP (VIP .50 ရှိ) ကနေ pull — ဒါ Phase 3 အထိ ရွှေ့လို့ရ။

## Phase 1 — Production drop.list curation (testbox2 soak)

### Task 4: drop.list အနည်းဆုံး စတင်

 sid အားလုံး drop လုပ်ရင် FP = business traffic ရပ်။ စတင်ရန် အဆင့်:
- `category:ET TROJAN` + `category:ET MALWARE` + `category:ET CNC` သာ (စုပေါင်း ~3-5k rules ထက် မကျော်)
- ET HUNTING / INFO / POLICY = alert-only (drop ဘယ်တော့မှ မထည့်)
- testbox2 မှာ apply + `suricata -T` + 72h soak — FP တစ်ခုတောင် တွေ့ရင် sid ချင်း filter ထွက်

### Task 5: drop.list ကို repo ထဲ သိမ်း (change management)

- Create: `suricata-linux/etc/suricata-drop.list.production` — git-tracked, PR review နဲ့ပြောင်း
- installer က production list ကို default အနေနဲ့ ယူ (empty list = alert-only box အဖြစ် ကျန်)
- md5 sync: manager share + testbox2 verify

## Phase 2 — n8n SOAR workflow (siem2 n8n)

### Task 6: Wazuh integration block အသစ်

Step 2b rule အတိုင်း — အရေးကြီး: rule IDs သပ်သပ်, hook သပ်သပ်:
```xml
<integration>
  <name>custom-siem2-n8n</name>
  <hook_url>http://127.0.0.1:5678/webhook/suricata-soc</hook_url>
  <rule_id>100160, 100161, 100162, 100170, 100171, 100175</rule_id>
  <alert_format>json</alert_format>
</integration>
```
Existing block ထဲ rule_id ထပ်မထည့် (Step 2b pitfall)။

### Task 7: n8n workflow "Suricata IPS SOC"

Pattern = existing wazuh-alert workflow clone (skill Step 4 PUT recipe):
- Webhook → Filter (rule.id, severity gate) → dedupe (24h per src+sid, staticData) → Telegram instant (cyberadmin_soc_bot, group -1004301734497 တစ်ခုတည်း) + email (active==1 recipients from siem2-alert-recipients DataTable)
- Severity split: level 14 (drop/C2/JA3) = instant TG; level ≤10 = daily digest email
- Deactivate→PUT→activate + versionId verify (active-workflow PUT silent-drop pitfall)

### Task 8: Weekly IPS digest (optional, pattern ရှိပြီး)

Weekly Network-Dept digest workflow ထဲ panel တစ်ခုထည့် — top dropped sigs, per-agent blocked counts, health misses. Cron Sat 08:00။

## Phase 3 — Fleet rollout (batch, Ko Ye sign-off per batch)

### Task 9: Batch plan (recap, confirmed mode matrix)

| Batch | Boxen | Mode | Note |
|---|---|---|---|
| 0 | Cloudpve01-03 (3) | IDS only | fail-closed ဘယ်တော့မှ မချိတ် |
| 1 | Cloudmgmt01-03 + Cloudcompute01-09 (12) | IPS | mini-batch 4×, 24h soak အကြား |
| 2 | Cloudcepn01-05 (5) | IPS | CEPH — quorum risk, 1 box စဉ်, verify |
| 3 | adc-prod (~55) | IPS | batch of 5, per-box verify (agent active + ips.accepted climbing + SSH alive) |

### Task 10: Deploy automation လမ်းဆွဲ

Option A (recommended): siem2 ကနေ SSH loop script — batch per group, key auth Ko Ye installs; per-box: run installer from synced shared folder + verify gates (suricata-ips active, wazuh-agent active, iptables SURICATA_IPS counters climb) + auto-rollback (uninstaller) on failure signal.
Option B: Wazuh AR remote command "run installer" — manager က trigger; shared folder ကို auto-distribute လုပ်ပေမယ့် mutating action တစ်ကြားပြီး ကြီးမားလို့ rollback နည်းပါး။
Ko Ye ရွေး။ Option A ကို အကြံပေး — explicit, per-box verify လွယ်။

### Task 11: Per-batch verification gates (script)

Create: `scripts/fleet-batch-verify.sh` — batch run ပြီးတိုင်း:
- wazuh agent Status: Active (siem2 agent_control / API)
- `ips.accepted` delta > 0 (traffic flowing through engine)
- iptables SURICATA_IPS bypass counters not exploding (mgmt ports safe)
- drop rules count == expected from drop.list
- 24h soak: zero FP complaints + zero health alerts

## Phase 4 — Hardening + polish (post-fleet)

### Task 12: Central blocklist share (optional)

n8n (or manager cron) က confirmed-bad IP တွေကို all-agent blocklist push (Wazuh API PUT /lists — CDB pattern ရှိပြီး YARA malware-hashes မှာ)။ AR dispatcher local block (1h TTL) က ပထမဆုံးခံစစ်ချက်၊ central persistent blocklist = analyst-confirmed တွေသာ။

### Task 13: IPS dashboard

Wazuh dashboards မှာ ပုံမှန် index — optional Grafana panel (swarm .52, skill ရှိ) — top sigs, blocked trend, per-agent health. တန်ဖိုးမြင်ရင် နောက်ထပ်။

### Task 14: Docs + skill update

README: production runbook section (batch table, verify gates, rollback one-liner)။ Skill suricata-inline-ips-wazuh: fleet batch table + n8n workflow notes ထည့်။

---

## Risks / Tradeoffs

- **Drop FP = production outage.** Drop.list ကို သေးသေးထား၊ soak ရှည်၊ category ခွဲ။ Rollback = drop.list အလွတ် + drop-apply (5 မိနစ်内 rule alert ပြန်)။
- **CEPH quorum** — Cloudcepn batch မှာ box တစ်လုံး ဝင်ပြီးသားနဲ့ နောက်တစ်လုံး မစေဘဲ sequential + verify။
- **adc-prod 55 box** — batch of 5, 11 rounds; SSH key install ကိုယ်တိုင် လို (Ko Ye policy)။
- **n8n single container** — siem2 မှာ dockerized; blocking layer က n8n မလို (autonomous per-agent) — n8n သေလည်း IPS ဆက်လုပ်။ ဒါက လက်ရှိ architecture ရဲ့ အားသာချက်၊ မဖျက်ရ။
- **suricata-update absent on testbox2** — installer guard ခံထားပြီး; rule refresh က cache tarball ကနေ ရမယ် — batch တိုင်းမှာ suricata-update binary ရှိမရှိ check gate ထည့် (Task 11 ထဲ)။

## Open questions (Ko Ye sign-off)

1. drop.list production content — Trojan/Malware/CNC only? ဒါမှမဟုတ် ထပ်တဲ့ category?
2. n8n workflow (Task 6-7) ကို ခုရောလား, Phase 2 batch 1 ပြီးမှလာ?
3. Batch schedule — အခုလာပြီး စလား, အရင် soak 72h?
4. Deploy automation Option A (SSH loop) vs B (Wazuh AR)?

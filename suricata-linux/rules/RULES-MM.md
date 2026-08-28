# Suricata Rules — ရှင်းလင်းချက်

`rules/suricata-rules.xml` ထဲက rules တစ်ခုချင်းက ဘာကို detect လုပ်လဲ ဖော်ပြပါသည်။

---

## Severity Tiers (100110 / 100111 / 100112)

| Rule | Level | ဖမ်းမိတာ | ဘာကြောင့် level ဒီလောက်ရှိလဲ |
|---|---|---|---|
| **100110** | **12** (critical) | Suricata severity 1 alert (အန္တရာယ်အရှိဆုံး) | Critical exploit payload, RCE, trojan |
| **100111** | 9 (high) | Suricata severity 2 alert | Exploit attempt, attack tool detected |
| **100112** | 5 (medium) | Other alert | Generic alert |

Suricata severity = 1 က "ဒီ attack က 100% bad"၊ severity 2-3 က "ဖြစ်နိုင်ခြေရှိတယ်"။

---

## IPS-block အတည်ပြုချက် (100120)

**Rule ID:** 100120
**Level:** 10
**Filter:** Suricata engine က packet ကို **dropped/blocked/rejected** လုပ်လိုက်ကြောင်း အတည်ပြု

ဘာကြောင့် လိုအပ်လဲ:
- Suricata က alert မှတ်တယ်။
- Engine က အဲဒီ packet ကို **တကယ် block** လုပ်လား? — alert action field ကို check ဖို့ လိုသည်။
- Inline mode မှာ packet က accept (alert only) **or** drop/reject (IPS active) ဖြစ်နိုင်သည်။
- 100120 က action="blocked/dropped/reject" ဖြစ်တဲ့ alert တွေကို level 10 ပြန်ပေးသည်။

---

## Anomaly engine (100130)

Suricata က protocol-level anomaly တွေ detect လုပ်သည်။ HTTP malformed request၊ TLS version မမှန်၊ DNS ပုံမမှန်၊ etc.
ဒါက exploit မဟုတ်ပေမယ့် "ဘာများဖြစ်နေလဲ" သိဖို့ အရေးကြီးသည်။

---

## Stats / Engine (100140 / 100150)

Suricata က stats နဲ့ engine event တွေ ထုတ်ပေးတယ်။
- **100140** → stats snapshot (CPU, memory, drops)
- **100150** → engine event (start, stop, error)

---

## AUTO-BLOCK TIERS (100160 / 100161 / 100162)

ဒီ rules တွေက Wazuh dashboard မှာ မြင်ရဖို့သာ မဟုတ်ဘဲ **agent-side dispatcher daemon** က eve.json alert signature ကို scan ပြီး IP ကို iptables-နဲ့ drop လုပ်ဖို့ trigger ဖြစ်သည်။

### Rule 100160 — BRUTEFORCE (Level 10)

**Match keyword:** `brute`, `bruteforce`, `dictionary`, `repeated auth`, `login attempt`, `password guessing`

**ET signatures ဥပမာ:**
- "ET SCAN SSH Brute Force Attempt"
- "ET SCAN Multiple SSH Login Attempts"
- "ET FTP Login Brute Force"
- "ET SCAN RDP Brute Force Attempt"
- "ET POLICY RDP Login Brute Force"

**Auto-block duration:** 1 hour (BLOCK_TIMEOUT=3600)

**ဘာကြောင့် auto-block လုပ်သင့်လဲ:**
SSH/RDP login ထပ်ခါထပ်ခါ fail နေတာ attacker သိသာ။ 1 နာရီ block က lockout မဖြစ်ဘူး (lockout policy က 30 min ဆို ပိုမြန်)။
**Whitelist:** trusted IP range (mgmt, jump host, etc.)

---

### Rule 100161 — C2 / BEACONING (Level 12, CRITICAL)

**Match keyword:** `C2`, `command and control`, `beacon`, `callback`, `cobalt strike`, `meterpreter`, `reverse shell`, `dnscat`, `empire`, `malware`

**ET signatures ဥပမာ:**
- "ET C2 Cobalt Strike Beacon Observed"
- "ET TROJAN Reverse Shell Activity"
- "ET MALWARE Empire C2 Activity"
- "ET DNS Query for Suspicious .onion"
- "ET POLICY Meterpreter Reverse Shell"

**Auto-block duration:** 1 hour

**ဘာကြောင့် auto-block လုပ်သင့်လဲ:**
C2 traffic = compromised endpoint ရှိလို့ alert ထပ်ထွက်နေတာ။ block မလုပ်ရင် attacker က credential ခိုးယူနိုင်သည်။
**False positive:** Beacon ပုံစံ ဆင်တူတဲ့ legit update server တွေကို whitelist ထည့်ပါ။

---

### Rule 100162 — SCANNING / RECON (Level 8)

**Match keyword:** `scan`, `recon`, `port scan`, `ET SCAN`, `suspicious connection`, `possible exploit`

**ET signatures ဥပမာ:**
- "ET SCAN Nmap SYN Scan"
- "ET SCAN Behavioral Unusual Port Scan"
- "ET POLICY Suspicious Inbound to MSSQL"

**Auto-block duration:** 1 hour

**ဘာကြောင့် auto-block လုပ်သင့်လဲ:**
Port scan / recon က attack ရဲ့ အစပါဘဲ။ block လုပ်မှ attacker က vulnerable service ရှာမရတော့မည်။
**Note:** Recon က noisy (false positive များ) ဖြစ်နိုင်သည်။ BLOCK_TIMEOUT ကို 1h ထက် နည်းပြီး ထားလို့ရသည်။

---

## Override (whitelist tuning)

`/etc/systemd/system/suricata-ar-dispatch.service.d/override.conf` မှာ ထည့်ပါ —
```ini
[Service]
Environment=BLOCK_TIMEOUT=3600
Environment="WHITELIST=127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 203.0.113.0/24"
```

`203.0.113.0/24` ကို whitelist ထည့်ရင် — ဒီ range က IP တွေ auto-block **မခံရတော့ဘူး**။
Mgmt jump host၊ backup server၊ trusted update server စတာတွေ ထည့်ပါ။

---

## Manager လိုအပ်ခြင်း

Agent-side dispatcher က eve.json ကို **local monitor** လုပ်တဲ့အတွက် **Wazuh manager မလိုအပ်ဘူး**။
Manager install မရှိရင်တောင် auto-block အလုပ်လုပ်သည်။

Manager config လိုချင်ရင်တော့ (alert visualization):
```bash
sudo cp etc/suricata-decoder.xml /var/ossec/etc/decoders/
sudo cp rules/suricata-rules.xml  /var/ossec/etc/rules/
sudo systemctl restart wazuh-manager
```

---

## Rule ID Reference

| Rule ID | Level | Description | Auto-Block? |
|---|---|---|---|
| 100100 | 0 | Catch-all | — |
| 100110 | 12 | CRITICAL alert (sev 1) | — (base) |
| 100111 | 9 | HIGH alert (sev 2) | — (base) |
| 100112 | 5 | Generic alert | — (base) |
| 100120 | 10 | IPS blocked packet | — |
| 100130 | 8 | Anomaly | — |
| 100140 | 3 | Stats | — |
| 100150 | 0 | Engine event | — |
| **100160** | **10** | **BRUTEFORCE** | **✅** |
| **100161** | **12** | **C2/BEACON** | **✅** |
| **100162** | **8** | **SCAN/RECON** | **✅** |
| 100199 | 3 | Unclassified | — |
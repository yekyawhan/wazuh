# Suricata Inline IPS for Linux (Wazuh sensor)

Linux endpoint တစ်ခုပေါ်မှာ **Suricata IPS** က inline mode-နဲ့ အလုပ်လုပ်စေဖို့ ရည်ရွယ်တဲ့ production-ready pipeline ပါ။
NFQUEUE verdict၊ EVE-JSON → Wazuh၊ auto-block active response၊ self-healing rule refresh စတာတွေ ပါဝင်ပါတယ်။

`suricata-win-offline/` (Windows Suricata + WinDivert) ရဲ့ Linux ဗားရှင်းပါ။

---

## မိတ်ဆက်

ဒီ project က Linux server/tamp မှာ Suricata ကို **inline IPS** (packet accept/drop လုပ်နိုင်တယ်) အဖြစ် ထားရှိပြီး
Wazuh agent နဲ့ ချိတ်ထားကာ alert တွေကို SIEM သို့ ပို့ပြဖို့ ရည်ရွယ်ပါတယ်။

| Capability | ဘယ်လိုအလုပ်လုပ်လဲ |
|---|---|
| **Inline IPS (NFQUEUE)** | `iptables` chain → NFQUEUE 0 → Suricata packet ကို accept/drop裁定 |
| **Fail-closed** | Suricata engine သေရင် traffic အားလုံး DROP (bypass မခံရဘူး) |
| **EVE JSON → Wazuh** | `/var/log/suricata/eve.json` ကို `log_format=json` နဲ့ Wazuh agent ပို့သည် |
| **Rich rules** | severity tier ၃ ဆင့်၊ IPS drop rule၊ anomaly detection (sid 100100-100199) |
| **Auto-block BRUTEFORCE/C2** | agent-side dispatcher က eve.json ကို monitor ပြီး ဖမ်းမိရင် iptables-နဲ့ ခုန်ထည့်သည် |
| **Health watchdog** | 5 မိနစ်တစ်ကြိမ် health JSON ထုတ်၊ Wazuh dashboard မှာ မြင်နိုင် |
| **Rule refresh** | 6 နာရီတစ်ကြိတ် ET Open ruleset pull + validate + auto-rollback |
| **Log rotation** | daily eve.json rotate + USR2 reload |

---

## Repo structure

```text
suricata-linux/
├── scripts/
│   ├── install-suricata-ips.sh            # installer (idempotent)
│   ├── uninstall-suricata-ips.sh          # uninstall
│   ├── suricata-health-monitor.sh         # health check → /var/log/suricata/health.json
│   ├── refresh-suricata-rules.sh          # ET ruleset update + validate + rollback
│   └── suricata-ar-dispatch.sh            # agent-side auto-block daemon (bruteforce/C2/scanning)
├── etc/
│   ├── suricata-ar-dispatch.service       # dispatch daemon systemd unit
│   ├── suricata-health.{service,timer}    # health watchdog timer
│   ├── suricata-rules.{service,timer}     # rule refresh timer
│   ├── suricata-logrotate                 # daily eve.json logrotate
│   ├── suricata-decoder.xml               # Wazuh decoder (eve.json fields)
│   └── suricata-ar-dispatch.override.conf.example # tunable override
├── rules/
│   └── suricata-rules.xml                 # Wazuh rules (sid 100100-100199)
└── active-response/
    └── suricata-ip-block.sh              # iptables DROP helper (1h cooldown)
```

---

## Install

```bash
sudo apt-get install -y suricata jq
cd /path/to/suricata-linux
sudo ./scripts/install-suricata-ips.sh
```

Installer က —
1. Suricata + packages install
2. NFQUEUE inline mode configure
3. `SURICATA_IPS` iptables chain setup (fail-closed)
4. Systemd service (auto-restart + watchdog) start
5. `/var/log/suricata/eve.json` ကို Wazuh localfile အဖြစ် register

```
[*] Interface : eth1
[*] NFQUEUE   : 0

[OK] Suricata IPS active:
active
-N SURICATA_IPS
-A SURICATA_IPS -j NFQUEUE --queue-num 0
-A SURICATA_IPS -j DROP
```

### Tuning

```bash
# Default interface က auto detect လုပ်တယ်။ သိသိသာသာ forced လုပ်ချင်ရင်:
export SURICATA_IFACE=eth0
sudo ./scripts/install-suricata-ips.sh

# Queue number ပြောင်းချင်ရင်:
export SURICATA_QUEUE=1
sudo ./scripts/install-suricata-ips.sh
```

---

## Monitor & Maintenance

Systemd timers install လုပ်ပြီးမှ —
```bash
sudo cp scripts/suricata-health-monitor.sh        /usr/local/bin/
sudo cp scripts/refresh-suricata-rules.sh         /usr/local/bin/
sudo cp etc/suricata-health.{service,timer}       /etc/systemd/system/
sudo cp etc/suricata-rules.{service,timer}        /etc/systemd/system/
sudo cp etc/suricata-logrotate                    /etc/logrotate.d/suricata
sudo systemctl enable --now suricata-health.timer suricata-rules.timer
```

### Auto-block (BRUTEFORCE/C2/Scanning)

Agent-side auto-block daemon က eve.json ကို watch ပြီး Bruteforce သို့မဟုတ် C2 signature တွေ့ရင် attacker IP ကို iptables-နဲ့ 1 နာရီ block လုပ်ပေးသည်။ Wazuh manager လိုအပ်ခြင်း မရှိ။

```bash
sudo cp scripts/suricata-ar-dispatch.sh           /usr/local/bin/
sudo cp etc/suricata-ar-dispatch.service          /etc/systemd/system/
sudo mkdir -p /etc/systemd/system/suricata-ar-dispatch.service.d
sudo cp etc/suricata-ar-dispatch.override.conf.example \
    /etc/systemd/system/suricata-ar-dispatch.service.d/override.conf
sudo systemctl daemon-reload
sudo systemctl enable --now suricata-ar-dispatch.service
```

Override file မှာ ထိန်းညှိနိုင်သည် —
- **BLOCK_TIMEOUT** = block ကြာချိန် (စက္ကန့်)၊ default 3600 (1 နာရီ)
- **WHITELIST** = ဘယ် CIDR ကို block လုပ်သင့်မလဲ၊ default RFC1918 + loopback + link-local

### Rule Refresh

6 နာရီတစ်ကြိတ် automatically `suricata-update` နဲ့ ET Open ruleset ပို့ယူသည်။
`suricata -T` ဖြင့် validate ပြီးမှ load — validation မအောင်ရင် ရှေ့ version သို့ auto-rollback လုပ်သည်။

---

## Rules overview

`rules/suricata-rules.xml` — Wazuh dashboard မှာ မြင်ရစေမည့် rules:

| Rule ID | Level | Description | Group |
|---|---|---|---|
| 100100 | 0 | Catch-all (any event) | — |
| 100110 | 12 | CRITICAL severity alert | attack,ids |
| 100111 | 9 | HIGH severity alert | attack,ids |
| 100112 | 5 | LOW/MED severity alert | attack,ids |
| 100120 | 10 | IPS blocked traffic | attack,ids,ips |
| 100130 | 8 | Anomaly engine | ids,anomaly |
| 100140 | 3 | Stats snapshot | info |
| **100160** | **10** | **BRUTEFORCE detected** | **attack,bruteforce,autoblock,** |
| **100161** | **12** | **C2/Beacon detected** | **attack,c2,autoblock,** |
| **100162** | **8** | **Scanning/Recon** | **recon,scan,autoblock,** |

### Auto-block trigger groups

Dispatcher daemon က ဒီ group name တွေကို decode မှာ filter လုပ်သည် —
- `autoblock,bruteforce` → SSH/RDP/SMB login brute force များ
- `autoblock,c2` → Cobalt Strike, Empire, dnscat, meterpreter, reverse shell
- `autoblock,recon` → Port scan, recon, suspicious connection

---

## Verify

### Service status
```bash
systemctl status suricata-ips                # IPS engine
systemctl status suricata-ar-dispatch        # auto-block daemon
```

### iptables chain
```bash
iptables -L SURICATA_IPS -n -v              # NFQUEUE chain
iptables -L WAZUH_SURICATA_BLOCK -n -v      # Auto-block chain
cat /tmp/suricata-ar-blocklist              # Blocked IPs + expiry
```

### Eve.json alerts
```bash
tail -f /var/log/suricata/eve.json | jq 'select(.event_type=="alert")'
```

### Health monitor output
```bash
sudo /usr/local/bin/suricata-health-monitor.sh
# {"suricata_health":{"agent":"hostname","status":"ok","queue":0,"messages":[],"ts":...}}
```

---

## Uninstall

```bash
sudo ./scripts/uninstall-suricata-ips.sh
```

ဒါက — suricata-ips service disable, ossec.conf restore, iptables chain flush လုပ်ပေးသည်။
Auto-block daemon ကိုပါ delete လုပ်ချင်ရင်:
```bash
sudo systemctl stop suricata-ar-dispatch.service
sudo systemctl disable suricata-ar-dispatch.service
sudo rm /etc/systemd/system/suricata-ar-dispatch.service
sudo rm /usr/local/bin/suricata-ar-dispatch.sh
sudo systemctl daemon-reload
```

---

## Testbox Live-Test Result (172.16.10.40 / CYS-009)

| Component | Status |
|---|---|
| suricata-ips.service | ✅ active, NRestarts=0 |
| NFQUEUE inline | ✅ queue bound, backlog draining |
| Fail-closed postuer | ✅ engine crash → DROP |
| Auto-block (bruteforce) | ✅ tested: 203.0.113.50 blocked |
| Auto-block (C2) | ✅ tested: 198.51.100.7 blocked |
| Rule refresh | ✅ 6-hour timer + ET pull + validate |
| Health watchdog | ✅ 5-min emit, caught disk threshold |
| Log rotation | ✅ daily eve.json rotate |

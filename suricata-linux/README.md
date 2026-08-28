# Suricata Inline IPS / IDS for Linux (Wazuh sensor)

Linux endpoint တစ်ခုပေါ်မှာ **Suricata IPS** (inline) သို့မဟုတ် **IDS** (passive) mode-နဲ့ အလုပ်လုပ်စေဖို့ ရည်ရွယ်တဲ့ production-ready pipeline ပါ။
NFQUEUE verdict (IPS) / af-packet passive (IDS), EVE-JSON → Wazuh, auto-block active response, self-healing rule refresh စတာတွေ ပါဝင်ပါတယ်။

---

## Mode ရွေးချယ်ခြင်း

| Mode | Script | ဘယ်မှာသုံးမလဲ | Traffic blocking |
|---|---|---|---|
| **IPS (inline)** | `install-suricata-ips.sh` | Cloud compute/mgmt servers | ✅ NFQUEUE drop (fail-closed) |
| **IDS (passive)** | `install-suricata-ids.sh` | PVE hypervisors, critical infra | ❌ မရှိ — monitor only |

> ⚠️ **PVE hypervisor မှာ IPS မသွင်းပါနဲ့** — fail-closed က VM traffic အားလုံး drop နိုင်တယ်။ IDS-only သုံးပါ။

---

## Install (Agent တစ်လုံးချင်းစီမှာ)

Shared folder sync ပြီးရင် agent ပေါ်မှာ file တွေ ရောက်နေမယ်:

### IPS mode (Cloudcompute, Cloudmgmt servers)

```bash
sudo apt-get install -y suricata iptables iproute2 jq python3 ca-certificates
cd /var/ossec/etc/shared/suricata-linux
sudo chmod +x scripts/*.sh
sudo ./scripts/install-suricata-ips.sh
```

### IDS mode (PVE hypervisors — Cloudpve01/02/03)

```bash
sudo apt-get install -y suricata jq python3 ca-certificates
cd /var/ossec/etc/shared/suricata-linux
sudo chmod +x scripts/*.sh
sudo ./scripts/install-suricata-ids.sh
```

### Interface force လုပ်ချင်ရင်

```bash
# Default က auto-detect (default route interface)
export SURICATA_IFACE=vmbr0    # PVE bridge
sudo ./scripts/install-suricata-ids.sh
```

---

## Repo structure

```text
suricata-linux/
├── scripts/
│   ├── install-suricata-ips.sh            # IPS installer (NFQUEUE inline)
│   ├── install-suricata-ids.sh            # IDS installer (passive af-packet)
│   ├── uninstall-suricata-ips.sh          # IPS uninstall
│   ├── uninstall-suricata-ids.sh          # IDS uninstall
│   ├── suricata-health-monitor.sh         # health check → health.json
│   ├── refresh-suricata-rules.sh          # ET ruleset update + validate + rollback
│   └── suricata-ar-dispatch.sh            # agent-side auto-block daemon (IPS only)
├── etc/
│   ├── suricata-ar-dispatch.service       # dispatch daemon systemd unit
│   ├── suricata-health.{service,timer}    # health watchdog timer
│   ├── suricata-rules.{service,timer}     # rule refresh timer
│   ├── suricata-logrotate                 # daily eve.json logrotate
│   ├── suricata-decoder.xml               # Wazuh decoder (prematch-based)
│   └── suricata-ar-dispatch.override.conf.example
├── rules/
│   └── suricata-rules.xml                 # Wazuh rules (sid 100100-100199)
└── active-response/
    └── suricata-ip-block.sh              # iptables DROP helper (1h cooldown)
```

---

## Manager-side setup (one-time, siem2)

```bash
sudo cp /var/ossec/etc/shared/default/suricata-linux/etc/suricata-decoder.xml /var/ossec/etc/decoders/
sudo cp /var/ossec/etc/shared/default/suricata-linux/rules/suricata-rules.xml /var/ossec/etc/rules/
sudo chown wazuh:wazuh /var/ossec/etc/decoders/suricata-decoder.xml /var/ossec/etc/rules/suricata-rules.xml
sudo chmod 640 /var/ossec/etc/decoders/suricata-decoder.xml /var/ossec/etc/rules/suricata-rules.xml
sudo systemctl restart wazuh-manager
```

---

## IPS-only: Auto-block daemon

```bash
sudo cp scripts/suricata-ar-dispatch.sh /usr/local/bin/
sudo cp etc/suricata-ar-dispatch.service /etc/systemd/system/
sudo mkdir -p /etc/systemd/system/suricata-ar-dispatch.service.d
sudo cp etc/suricata-ar-dispatch.override.conf.example \
    /etc/systemd/system/suricata-ar-dispatch.service.d/override.conf
sudo systemctl daemon-reload
sudo systemctl enable --now suricata-ar-dispatch.service
```

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
| **100160** | **10** | **BRUTEFORCE detected** | **attack,bruteforce,autoblock** |
| **100161** | **12** | **C2/Beacon detected** | **attack,c2,autoblock** |
| **100162** | **8** | **Scanning/Recon** | **recon,scan,autoblock** |

---

## Verify

```bash
systemctl status suricata-ips     # IPS mode
systemctl status suricata-ids     # IDS mode
tail -f /var/log/suricata/eve.json | jq 'select(.event_type=="alert")'
sudo /usr/local/bin/suricata-health-monitor.sh
```

---

## Uninstall

```bash
sudo ./scripts/uninstall-suricata-ips.sh   # IPS
sudo ./scripts/uninstall-suricata-ids.sh   # IDS
```

---

## Fix log (2026-08-28)

| # | Bug | Fix |
|---|---|---|
| 1 | Decoder `program_name` (eve.json = pure JSON, no syslog prefix) | `prematch` ပြောင်း |
| 2 | Rules `$(field)` closing paren 8 နေရာ ပိတ်မထား | ပိတ်ပြီး |
| 3 | `systemctl reload` (ExecReload မရှိ) | `kill -s USR2` |
| 4 | ar-dispatch env vars printf ဘက်မှာ set | AR_BIN ဘက် ပြောင်း |
| 5 | health-monitor JSON comma မပါ | loop နဲ့ build |
| 6 | python3 dependency မထည့် | apt list ထဲ ထည့် |
| 7 | `<json>` block invalid (analysisd CRITICAL 1202) | ဖျက်ပြီး prematch-only |
| 8 | Rules field names `data.*` မဟုတ် | auto-parse namespace ပြောင်း |

---

## Testbox Live-Test Result (172.16.10.40 / CYS-009)

| Component | Status |
|---|---|
| suricata-ips.service | ✅ active, NRestarts=0 |
| NFQUEUE inline | ✅ queue bound, backlog draining |
| Fail-closed posture | ✅ engine crash → DROP |
| Auto-block (bruteforce) | ✅ tested: 203.0.113.50 blocked |
| Auto-block (C2) | ✅ tested: 198.51.100.7 blocked |
| Rule refresh | ✅ 6-hour timer + ET pull + validate |
| Health watchdog | ✅ 5-min emit, caught disk threshold |
| Log rotation | ✅ daily eve.json rotate |

# Suricata Inline IPS for Linux (Wazuh sensor)

A **production-shaped Suricata IPS pipeline** for Linux endpoints: inline NFQUEUE
verdict, EVE-JSON forwarded into Wazuh, custom decoders/rules, auto-blocking
active response, and self-healing rule refresh.

Companion to `suricata-win-offline/` (Windows builds from source + WinDivert);
this module covers the **Linux IPS variant**.

---

## What you get

| Capability | How |
|---|---|
| **Inline verdict (NFQUEUE)** | `iptables` chain → NFQUEUE 0 → Suricata accepts/drops |
| **Fail-closed posture** | NFQUEUE `fail-open: no` + DROP fallback if engine stalls |
| **EVE → Wazuh** | `<localfile><log_format>json</log_format>` forwards `/var/log/suricata/eve.json` |
| **Rich rules** | severity tiers, IPS-drop rule, anomaly, engine, stats (sid 100100-100199) |
| **Active response** | `suricata-ip-block.sh` auto-blocks the offender in `iptables` for 1h |
| **Health watchdog** | systemd timer emits `suricata_health` JSON every 5 min |
| **Rule refresh** | `suricata-update` + `suricata -T` validation + auto-rollback on bad rules |
| **Log rotation** | daily `eve.json` rotate + USR2 reload, weekly `health.json` rotate |

---

## Repo layout

```text
suricata-linux/
├── scripts/
│   ├── install-suricata-ips.sh      # one-shot installer (idempotent)
│   ├── uninstall-suricata-ips.sh    # reverts everything
│   ├── suricata-health-monitor.sh   # emits health JSON to /var/log/suricata/health.json
│   └── refresh-suricata-rules.sh    # ET refresh + validation + rollback
├── etc/
│   ├── suricata-health.{service,timer}        # watchdog (every 5 min)
│   ├── suricata-rules.{service,timer}         # rule refresh (every 6 h)
│   └── suricata-logrotate                    # daily eve.json rotate
├── rules/
│   └── suricata-rules.xml          # Wazuh rules (sid 100100-100199)
└── active-response/
    └── suricata-ip-block.sh        # auto-block offender for 1h
```

---

## Quick start (on the Linux sensor)

```bash
sudo apt-get install -y suricata jq
cd /path/to/suricata-linux
sudo ./scripts/install-suricata-ips.sh
```

That installs Suricata, configures NFQUEUE inline mode, sets up the
`SURICATA_IPS` iptables chain with fail-closed semantics, and registers
`/var/log/suricata/eve.json` as a Wazuh localfile.

```bash
sudo cp scripts/suricata-health-monitor.sh       /usr/local/bin/
sudo cp scripts/refresh-suricata-rules.sh        /usr/local/bin/
sudo cp etc/suricata-health.{service,timer}      /etc/systemd/system/
sudo cp etc/suricata-rules.{service,timer}       /etc/systemd/system/
sudo cp etc/suricata-logrotate                   /etc/logrotate.d/suricata
sudo systemctl enable --now suricata-health.timer suricata-rules.timer
```

---

## Manager side (once)

```bash
# Decoders
sudo cp rules/../etc/suricata-decoder.xml /var/ossec/etc/decoders/

# Rules
sudo cp rules/suricata-rules.xml          /var/ossec/etc/rules/

# Active response
sudo cp active-response/suricata-ip-block.sh /var/ossec/active-response/bin/
sudo chmod 750 /var/ossec/active-response/bin/suricata-ip-block.sh

sudo systemctl restart wazuh-manager
```

Then add to `/var/ossec/etc/ossec.conf`:

```xml
<active-response>
  <command>suricata-ip-block</command>
  <location>local</location>
  <rules_id>100110</rules_id>     <!-- only auto-block severity=1 hits -->
  <timeout>3600</timeout>
</active-response>
```

And add the agent-side health localfile (so the watchdog JSON reaches the
manager):

```xml
<localfile>
  <log_format>json</log_format>
  <location>/var/log/suricata/health.json</location>
</localfile>
```

---

## Operating notes

* **Interface auto-detect**: installer picks the default route interface. To
  force, `export SURICATA_IFACE=eth0` before install.
* **Queue number**: default NFQUEUE 0; change with `SURICATA_QUEUE=1 ./install…`.
* **Fail-closed** = if Suricata dies, traffic stops flowing on that interface.
  This is intentional. To fail-open (traffic bypasses), edit
  `/etc/suricata-ips.conf` and set `FAIL_CLOSED=0`, then reinstall.
* **Rule refresh** runs `suricata-update`, then `suricata -T` validates the
  ruleset. If validation fails, the previous ruleset is restored automatically.
* **Auto-block** is rule-gated to severity 1 hits only (sid 100110) to prevent
  lockouts from noisy signatures. Tune as needed.

## Verify

```bash
systemctl status suricata-ips
iptables -L SURICATA_IPS -n -v
tail -f /var/log/suricata/eve.json | jq 'select(.event_type=="alert")'
tail -f /var/log/suricata/health.json
```

## Uninstall

```bash
sudo ./scripts/uninstall-suricata-ips.sh
```

Restores `ossec.conf` from `.bak.suricata-ips`, removes the systemd unit, and
flushes the NFQUEUE chain.

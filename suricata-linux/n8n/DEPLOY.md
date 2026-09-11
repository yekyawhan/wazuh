# Suricata IPS SOC — n8n Workflow Deploy Runbook

Production n8n = siem2 dockerized (`127.0.0.1:5678`). Personal n8n ကို ဘယ်တော့မှ မသုံးရ။

Files:
- `workflow-suricata-soc.json` — workflow payload (create via POST)
- `wazuh-integration-block.xml` — ossec.conf integration block (separate, never merge into existing SSH block)

## 1. Payload to siem2

```bash
scp workflow-suricata-soc.json securityadmin@100.120.44.85:/tmp/
```

## 2. Create workflow (n8n API)

n8n API key: siem2 host env — `X-N8N-API-KEY` (sera env file ထဲမှာ)

```bash
ssh securityadmin@100.120.44.85
API_KEY="<X-N8N-API-KEY>"
curl -s -X POST http://127.0.0.1:5678/api/v1/workflows \
  -H "X-N8N-API-KEY: $API_KEY" -H "Content-Type: application/json" \
  --data @/tmp/workflow-suricata-soc.json | jq '{id, name, active}'
```

Note: `active` cannot be set at creation — activate in step 3.

## 3. Activate

```bash
curl -s -X POST "http://127.0.0.1:5678/api/v1/workflows/<ID>/activate" \
  -H "X-N8N-API-KEY: $API_KEY" | jq '{id, active, versionId}'
```

## 4. Verify

```bash
curl -s "http://127.0.0.1:5678/api/v1/workflows/<ID>" \
  -H "X-N8N-API-KEY: $API_KEY" | jq '{name, active, nodeCount: (.nodes|length), connections}'
```
Expect: `active: true`, 5 nodes, connections chain Webhook→Filter→Dedupe→Gate→TG.

## 5. Wazuh integration block (siem2, /var/ossec/etc/ossec.conf)

Reuse existing `/var/ossec/integrations/custom-siem2-n8n` script (argv[3]=hook_url). Insert as SEPARATE `<integration>` block — never append rule IDs to the existing SSH block (pitfall: mixed destinations silently drop).

```bash
echo {{SUDO_PW}} | sudo -S python3 - <<'PY'
import xml.etree.ElementTree as ET
p = '/var/ossec/etc/ossec.conf'
tree = ET.parse(p)
root = tree.getroot()
block = '''<integration>
  <name>custom-siem2-n8n</name>
  <hook_url>http://127.0.0.1:5678/webhook/suricata-soc</hook_url>
  <rule_id>100160, 100161, 100162, 100170, 100171, 100175</rule_id>
  <alert_format>json</alert_format>
</integration>'''
frag = ET.fromstring(block)
# idempotency: skip if hook_url already present
have = any(i.find('hook_url') is not None and 'suricata-soc' in (i.find('hook_url').text or '')
           for i in root.iter('integration'))
if not have:
    root.append(frag)
    tree.write(p)
    print('inserted')
else:
    print('already present')
PY
echo {{SUDO_PW}} | sudo -S /var/ossec/bin/wazuh-control restart analysisd integratord
```

> `tree.write()` ownership trap: after write, `sudo chown wazuh-manager...` — NOT needed on manager (manager runs root) but re-`grep` the block + `systemctl is-active wazuh-manager` after restart.

## 6. E2E test

```bash
# synthetic alert → webhook
curl -s -X POST http://127.0.0.1:5678/webhook/suricata-soc \
  -H "Content-Type: application/json" \
  -d '{"rule":{"id":"100170","level":13,"description":"Suricata IPS DROP CONFIRMED"},"agent":{"name":"wazuh-test"},"data":{"src_ip":"198.51.100.77","dest_ip":"10.3.11.49","dest_port":443,"alert":{"signature":"ET TROJANS Cobalt Strike Beacon","action":"blocked"}}}'
# expect {"message":"Workflow was started"}

# execution success?
docker ps --format '{{.Names}}' | grep -i n8n
docker logs --tail 20 <n8n-container> 2>&1 | grep -i error

# TG group message received? (cyberadmin_soc_bot → group -1004301734497)
```

## 7. Rollback

- n8n: `POST /api/v1/workflows/<ID>/deactivate` then `DELETE /api/v1/workflows/<ID>`
- Wazuh: remove `<integration>` block (idempotent insert writes only when missing — removal: ET re-parse, drop frag with hook_url containing 'suricata-soc', write, restart analysisd+integratord)

# Suricata IPS — n8n SOAR Workflows (siem2 production)

## What's live (2026-09-12, E2E-verified)

| Workflow | n8n ID | Trigger | Does |
|---|---|---|---|
| Suricata IPS SOC | `3x3QqoFaHDcxnI0c` | Wazuh webhook `/webhook/suricata-soc` (integration block, rules 100160/161/162/170/171/175) | body-unwrap → rule gate → 24h dedupe → **Telegram instant** (cyberadmin_soc_bot → group -1004301734497, native node + credential `eCt4h9eYogj45d07`) + **log to `suricata_ips_events` DataTable** |
| Suricata IPS Daily Digest | `aGfT6piuBW8jUhhj` | cron 09:00 Asia/Yangon | ledger same-day guard → read events 24h → read recipients (active==1) → AGB dark HTML mail (SMTP `siem2-smtp`) → ledger insert |

## DataTables (n8n, siem2 project)

| Table | ID | Purpose |
|---|---|---|
| suricata_ips_events | `0ARlCwjbJIHA8E2Q` | real-time accumulator — every routed alert appended by SOC workflow |
| suricata_digest_ledger | `ryM0V3Lm7leKYpo7` | one row per sent digest (`digest_date` = YYYY-MM-DD) — same-day resend guard |
| siem2-alert-recipients | `5pPjepCTI5LJtWbF` | digest recipients (name/email/role/active) — set active=1 to receive |

## Same-day guard (how "no resend" works)

`Ledger Check` node queries the ledger DataTable for `digest_date == today`:
row with `status: sent` exists → return 0 items → entire flow stops.
No row → events → mail → `Ledger Insert` writes today's row.
Double-verified: exec 1567 sent mail + wrote row; exec 1568 stopped at Ledger Check.

## Files

- `workflow-suricata-soc.json` — live export, secrets masked (`<TG_TOKEN>` only if inline; TG now uses n8n credential)
- `workflow-suricata-digest.json` — live export, `<API_KEY_AT_DEPLOY>` placeholder where the Ledger Check node calls the n8n API (needs the siem2 n8n API key at deploy time; it lives in `user_api_keys` on siem2)
- `wazuh-integration-block.xml` — ossec.conf block (already deployed on siem2)
- `DEPLOY.md` — original deploy runbook (SOC workflow)

## Re-deploy recipe

`POST /api/v1/workflows` with payload + `settings: {executionOrder: v1, binaryMode: separate}` then `POST /workflows/<id>/activate`. PUT on active workflow is silently dropped — deactivate → PUT → activate. See DEPLOY.md.

## Telegram actions available from TG

Inline buttons / bot commands can be added later (block IP, isolate, disable account) via:
- TG bot webhook → n8n → Wazuh API `PUT /active-response` (firewall-drop86400) — pattern verified in siem2-bf-block-pipeline skill (v3 agent-targeted, JWT bearer).
- Blocklists: `PUT /lists/files/...` CDB push (pattern in YARA workflow `CDB Blocklist Push` node).
Not yet wired — Ko Ye sign-off needed before any TG-triggered blocking.

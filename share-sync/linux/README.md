# Wazuh Share Sync — Linux

Systemd timer variant for Wazuh Linux agents.

## Files

| File | Purpose |
|---|---|
| `share-sync.sh` | One-shot sync: `shared/` → `active-response/bin/` |
| `install-share-sync.sh` | Install systemd service + timer |
| `uninstall-share-sync.sh` | Remove systemd service + timer |

## Install

**Online (Direct download):**
```bash
sudo curl -o /var/ossec/etc/shared/share-sync.sh https://raw.githubusercontent.com/yekyawhan/wazuh/git-home/share-sync/linux/share-sync.sh
sudo curl -o /var/ossec/etc/shared/install-share-sync.sh https://raw.githubusercontent.com/yekyawhan/wazuh/git-home/share-sync/linux/install-share-sync.sh
sudo chmod +x /var/ossec/etc/shared/install-share-sync.sh && sudo /var/ossec/etc/shared/install-share-sync.sh
```

**Offline (Local files):**
```bash
sudo chmod +x /var/ossec/etc/shared/install-share-sync.sh && sudo /var/ossec/etc/shared/install-share-sync.sh
```

## How it works

Installer copies `share-sync.sh` to **`/var/ossec/bin/`** — outside `shared/` so it's never overwritten by Wazuh manager sync.

Systemd timer fires every 1 minute:

```
wazuh-share-sync.timer  →  wazuh-share-sync.service  →  /var/ossec/bin/share-sync.sh
```

Service runs as `ossec` user with `ProtectSystem=strict` (only AR bin + log writable).

## Uninstall

```bash
sudo /var/ossec/etc/shared/uninstall-share-sync.sh
```

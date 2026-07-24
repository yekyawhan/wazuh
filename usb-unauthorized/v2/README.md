# Wazuh USB Unauthorized Device Blocking — Linux V2

Centralized USB mass-storage control for Linux agents. Whitelist on the Wazuh Manager (`usb_whitelist.txt`) is pushed via shared config; agent-side `systemd path unit` watches the file and applies udev rules on change.

## Files (under `v2/`)

- **`install_usb_sync_linux.sh`** — one-shot installer (run once as root)
- **`hybrid_sync_usb_linux_v2.sh`** — sync engine (deployed to `/usr/local/bin/hybrid_sync_usb_linux_v2.sh`)

## How it works (V2 design)

- **DENY by default**: udev rule blocks all USB mass-storage interfaces (`ID_USB_INTERFACES=*:08???*:*`)
- **ALLOW whitelist**: VID:PID pairs from `usb_whitelist.txt` get explicit `ATTR{authorized}="1"` rules *before* the deny rule
- **Retroactive**: `udevadm trigger` applies rules to already-connected devices immediately
- **Path-triggered**: `systemd.path` watches `/var/ossec/etc/shared/usb_whitelist.txt` → on change, triggers the sync service

## Quick Start — Install (run as root on agent)

```bash
# Download and run (from manager shared folder or GitHub)
curl -fsSL https://raw.githubusercontent.com/yekyawhan/wazuh/git-home/usb-unauthorized/v2/install_usb_sync_linux.sh | sudo bash
```

Or from the manager's shared folder (already synced to agent):
```bash
sudo /var/ossec/etc/shared/Linux-Client/install_usb_sync_linux.sh
```
## install from agent offline
```
sudo chmod +x /var/ossec/etc/shared/hybrid_sync_usb/hybrid_sync_usb_linux_v2.sh /var/ossec/etc/shared/hybrid_sync_usb/install_usb_sync_linux.sh && sudo /var/ossec/etc/shared/hybrid_sync_usb/install_usb_sync_linux.sh 
```

The installer:
1. Copies `hybrid_sync_usb_linux_v2.sh` → `/usr/local/bin/hybrid_sync_usb_linux_v2.sh` (chmod +x)
2. Creates `/var/ossec/etc/shared/usb_whitelist.txt` if missing
3. Installs systemd units:
   - `wazuh-usb-sync.service` — oneshot sync
   - `wazuh-usb-sync.path` — watches `/var/ossec/etc/shared/usb_whitelist.txt`
3. Enables & starts `wazuh-usb-sync.path`
4. Runs first sync immediately

## Uninstall

```bash
sudo systemctl disable --now wazuh-usb-sync.path wazuh-usb-sync.service
sudo rm -f /usr/local/bin/hybrid_sync_usb_linux_v2.sh
sudo rm -f /etc/systemd/system/wazuh-usb-sync.service /etc/systemd/system/wazuh-usb-sync.path
sudo rm -f /var/ossec/etc/shared/usb_whitelist.txt /etc/udev/rules.d/99-usb-block.rules
systemctl daemon-reload
```

## Whitelist format

On the Manager: `/var/ossec/etc/shared/Linux-Client/usb_whitelist.txt`

```
# VID:PID (any stick of that model)
0781:556b
# or Windows hardware ID
USB\VID_0781&PID_556B
```

Only one device per line. `#` comments and blank lines ignored.

## Logs

- Sync log: `/var/log/wazuh-usb-sync.log`
- udev denials: `dmesg -T | grep usb-block` or `journalctl -t usb-block`

## Service status

```bash
# Path watcher (should be active)
systemctl status wazuh-usb-sync.path

# Sync service (inactive=dead is normal for oneshot)
systemctl status wazuh-usb-sync.service
```

**`inactive (dead)` on the service = normal**. The `.path` unit triggers the `.service` on whitelist change; service runs, logs, exits cleanly (`inactive (dead)` = success).

## Centralization

Whitelist lives on Manager at `/var/ossec/etc/shared/Linux-Client/usb_whitelist.txt`. Pushed to agents via Wazuh shared config (`agent.conf` shared group). Agent's `systemd.path` watches the local copy → auto-sync on push.

## Test Logger 
```
logger -t usb-block "DENIED unauthorized USB storage kernel=test vendor=0781 product=556b"
```

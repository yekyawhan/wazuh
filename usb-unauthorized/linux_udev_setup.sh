#!/usr/bin/env bash
# Generate udev rules that default-deny USB devices and whitelist specific VID/PID pairs.
# Usage: sudo ./linux_udev_setup.sh -w "0951:1666 0781:5581"

set -euo pipefail

RULES_FILE="/etc/udev/rules.d/99-usb-block.rules"
WHITELIST=()

usage() {
    cat <<EOF
Usage: $0 [-w "VID1:PID1 VID2:PID2 ..."] [-f /path/to/rules]

Options:
  -w  Whitelisted VID:PID pairs (space-separated).
  -f  Output rules file path (default: /etc/udev/rules.d/99-usb-block.rules).
  -h  Show this help.
EOF
    exit 1
}

while getopts "w:f:h" opt; do
    case "$opt" in
        w) WHITELIST+=($OPTARG) ;;
        f) RULES_FILE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "Must run as root." >&2; exit 1; }

# Split "0951:1666 0781:5581" into array
PAIRS=()
for entry in "${WHITELIST[@]}"; do
    for pair in $entry; do
        PAIRS+=("$pair")
    done
done

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

{
    echo "# Managed by linux_udev_setup.sh - do not edit manually"
    echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    echo "# Default-deny: any USB device plugged in is unauthorized."
    echo 'ACTION=="add", SUBSYSTEMS=="usb", ATTR{authorized}="0"'
    echo ""
    echo "# Whitelist: explicitly authorize these VID/PID pairs."
    for pair in "${PAIRS[@]}"; do
        vid="${pair%%:*}"
        pid="${pair##*:}"
        if [[ ! "$vid" =~ ^[0-9a-fA-F]{4}$ || ! "$pid" =~ ^[0-9a-fA-F]{4}$ ]]; then
            echo "Invalid VID:PID: $pair" >&2
            exit 1
        fi
        echo "ACTION==\"add\", SUBSYSTEMS==\"usb\", ATTR{idVendor}==\"$vid\", ATTR{idProduct}==\"$pid\", ATTR{authorized}=\"1\""
    done
} > "$tmp"

install -m 0644 "$tmp" "$RULES_FILE"
echo "Wrote $RULES_FILE"

# Reload udev
if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules
    udevadm trigger --subsystem-match=usb --action=add
    echo "udev rules reloaded."
else
    echo "udevadm not found - reload udev manually." >&2
fi

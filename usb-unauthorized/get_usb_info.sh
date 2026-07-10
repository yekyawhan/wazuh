#!/usr/bin/env bash
# get_usb_info.sh - list USB devices in a clean form for whitelisting.
#
#   Default : hides root hubs, shows a name for each device.
#   -a      : show everything (including root hubs).
#
# Copy the VID:PID (Linux format) OR the WINDOWS-ID column into
# usb_whitelist.txt on the manager.

show_all="${1:-}"

printf "%-11s  %-38s  %s\n" "VID:PID" "DEVICE" "WINDOWS-ID"
printf "%-11s  %-38s  %s\n" "-----------" "--------------------------------------" "----------------------"

lsusb 2>/dev/null | while IFS= read -r line; do
    id=$(awk '{print $6}' <<<"$line")
    # only keep valid VID:PID lines
    [[ "$id" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]] || continue
    name=$(sed -E 's/^Bus [0-9]+ Device [0-9]+: ID [0-9a-fA-F]{4}:[0-9a-fA-F]{4} ?//' <<<"$line")
    [[ -z "$name" ]] && name="(unnamed device)"
    # hide root hubs unless -a
    if [[ "$show_all" != "-a" && "$name" =~ [Rr]oot\ [Hh]ub ]]; then continue; fi
    vid="${id%%:*}"; pid="${id##*:}"
    printf "%-11s  %-38s  USB\\VID_%s&PID_%s\n" "$id" "${name:0:38}" "$vid" "$pid"
done

echo ""
echo "Add the VID:PID (or WINDOWS-ID) of the device you want to allow into usb_whitelist.txt."
[[ "$show_all" != "-a" ]] && echo "(root hubs hidden - run with '-a' to see everything)"

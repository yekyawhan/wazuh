# Linux: Get VID:PID for whitelisting
lsusb | awk '{print $6}' | grep ":"

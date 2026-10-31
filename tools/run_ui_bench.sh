#!/bin/zsh
set -euo pipefail
repo=${0:A:h:h}
usbboot=${GAIN_USBBOOT:-usbboot}
report_file=$(mktemp -t gain-ui-bench.XXXXXX)
trap 'rm -f "$report_file"' EXIT
cd "$repo"
zig build bench-ui-f20 --summary all
python3 tools/prepare_usb.py "$usbboot" "${GAIN_SPL:-zig-out/bin/gain-spl.bin}" "${GAIN_SKIP_SPL:-0}"
"$usbboot" --cpu x1000 --addr 0x80004000 --download zig-out/bin/gain-ui-bench.bin --flush-caches --start1 0x80004000
# Leave ROM transport alone until the bounded RAM campaign has returned.
sleep 20
"$usbboot" --cpu x1000 --cpuinfo
"$usbboot" --cpu x1000 --addr 0xa0700000 --length 136 --upload "$report_file"
if [[ -n ${GAIN_UI_REPORT:-} ]]; then cp "$report_file" "$GAIN_UI_REPORT"; fi
zig build read-ui-bench -Dui-report="$report_file"

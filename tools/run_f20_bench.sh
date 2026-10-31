#!/bin/zsh
set -euo pipefail

repo=${0:A:h:h}
usbboot=${GAIN_USBBOOT:-usbboot}
spl=${GAIN_SPL:-zig-out/bin/gain-spl.bin}
skip_spl=${GAIN_SKIP_SPL:-0}
selected_cases=${GAIN_F20_CASES:-"0 1 3 4 5 6 7 8 9 10 13"}
report_bytes=528
report_file=$(mktemp -t gain-f20-bench.XXXXXX)
case_file=$(mktemp -t gain-f20-case.XXXXXX)
trap 'rm -f "$report_file" "$case_file"' EXIT

wait_for_rom() {
    local attempt=0
    while ! "$usbboot" --cpu x1000 --cpuinfo >/dev/null 2>&1; do
        attempt=$((attempt + 1))
        if (( attempt == 30 )); then
            print -u2 "benchmark case did not return to the ROM USB loop"
            return 1
        fi
        sleep 1
    done
}

cd "$repo"
zig build bench-f20 --summary all

python3 tools/prepare_usb.py "$usbboot" "$spl" "$skip_spl"
"$usbboot" --cpu x1000 --addr 0x80800000 \
    --download tests/fixtures/flac-device-192.flac
"$usbboot" --cpu x1000 --cpuinfo
for selected in ${=selected_cases}; do
    printf '%02x000000' "$selected" | xxd -r -p > "$case_file"
    "$usbboot" --cpu x1000 --addr 0xa06ff000 --download "$case_file"
    "$usbboot" --cpu x1000 --addr 0x80004000 \
        --download zig-out/bin/gain-f20-bench.bin --flush-caches \
        --start1 0x80004000
    wait_for_rom
    print "completed F20 benchmark case $selected"
    "$usbboot" --cpu x1000 --addr 0xa0700000 \
        --length "$report_bytes" --upload "$report_file"
    zig build read-f20-bench -Dreport="$report_file"
done
"$usbboot" --cpu x1000 --cpuinfo

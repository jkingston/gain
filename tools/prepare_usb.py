#!/usr/bin/env python3
"""Prepare a verified F20 ROM session without retraining warm DRAM."""

from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time


def wait_for_rom(usbboot, timeout=30):
    deadline = time.monotonic() + timeout
    while True:
        result = subprocess.run(
            [str(usbboot), "--cpu", "x1000", "--cpuinfo"],
            capture_output=True,
            timeout=5,
        )
        if result.returncode == 0 and b"X1000_v1" in result.stdout:
            return
        if time.monotonic() >= deadline:
            raise RuntimeError("F20 recovery did not enumerate before the deadline")
        time.sleep(0.2)


def prepare(usbboot, spl, skip_cold=False):
    def call(*arguments):
        subprocess.run(
            [str(usbboot), "--cpu", "x1000", *map(str, arguments)],
            check=True,
            timeout=20,
            stdout=subprocess.DEVNULL,
        )

    wait_for_rom(usbboot)
    with tempfile.TemporaryDirectory(prefix="gain-phy-") as directory:
        path = Path(directory) / "phy.bin"
        call("--addr", "0xb301100c", "--length", "4", "--upload", path)
        (phy,) = struct.unpack("<I", path.read_bytes())
    state = phy & 31
    if state == 31:
        return
    if state != 7:
        raise RuntimeError(
            f"Unexpected F20 PHY state {state:#x}; no DRAM training performed"
        )
    if skip_cold:
        raise RuntimeError("DRAM is cold; remove GAIN_SKIP_SPL before retrying")
    call("--stage1", spl)
    time.sleep(2)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("Usage: prepare_usb.py USBBOOT SPL SKIP_COLD")
    prepare(sys.argv[1], sys.argv[2], sys.argv[3] == "1")

#!/usr/bin/env python3
"""Reproducible RAM-only player checks. Never writes flash or the SD filesystem."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import time
from prepare_usb import prepare

ROOT = Path(__file__).resolve().parents[1]
FIELDS = "signature revision complete mode error_code sample_rate frames_low frames_high periods underruns heap_peak storage_steps ui_polls maximum_fill_ticks startup_ticks maximum_ui_ticks maximum_ui_gap_ticks maximum_irq_ticks output_stack ui_stack control_stack codec_stack storage_stack exit iterations elapsed_ticks cause epc error_length pcm_checksum volume_changes minimum_fifo".split()
MODES = {"normal": 0, "stop": 1, "next": 2, "previous": 3, "truncated": 5, "sd": 6, "sd-fault": 7, "mixed": 8}


def fixtures():
    text = (ROOT / "tests/codec_fixtures.zig").read_text()
    pattern = r'\.name\s*=\s*"([^"]+)".*?\.bytes\s*=\s*@embedFile\("([^"]+)"\).*?\.rate\s*=\s*(\d+).*?\.frames\s*=\s*(\d+)'
    result = []
    for name, relative, rate, frames in re.findall(pattern, text):
        result.append(dict(name=name, path=ROOT / "tests" / relative, rate=int(rate), frames=int(frames)))
    if not result:
        raise RuntimeError("No qualification fixtures found")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--usbboot", default=os.environ.get("GAIN_USBBOOT", "usbboot"))
    parser.add_argument("--output", type=Path, required=True, help="Evidence directory outside the source checkout")
    parser.add_argument("--fixture", help="One fixture name instead of the complete matrix")
    parser.add_argument("--mode", choices=MODES, default="normal")
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--seconds", type=int, default=120, help="SD duration; at most 600 seconds")
    parser.add_argument("--skip-build", action="store_true", help="Use an already-built and identified qualification image")
    args = parser.parse_args()
    output = args.output.resolve()
    if output == ROOT or ROOT in output.parents:
        parser.error("Store reports outside the source checkout")
    if not 1 <= args.repeat <= 1000 or not 1 <= args.seconds <= 600:
        parser.error("Repeat must be 1..1000; seconds must be 1..600")
    if not args.skip_build:
        subprocess.run(["zig", "build", "player-check-f20", "--summary", "all"], cwd=ROOT, check=True)
    image = ROOT / "zig-out/bin/gain-player-check.bin"
    reader = ROOT / "zig-out/bin/read-player-check"
    identity = hashlib.sha256(image.read_bytes()).hexdigest()
    output.mkdir(parents=True, exist_ok=True)
    (output / "image-sha256.txt").write_text(identity + "\n")
    cases = fixtures()
    if args.fixture:
        cases = [case for case in cases if case["name"] == args.fixture]
        if not cases:
            parser.error("Unknown fixture")
    elif args.mode not in ("normal", "mixed"):
        cases = cases[:1]
    if args.mode.startswith("sd"):
        cases = [dict(name=args.mode, path=None, rate=0, frames=0)]
    results = []
    with tempfile.TemporaryDirectory(prefix="gain-player-check-") as temporary:
        temp = Path(temporary)

        def usb(*arguments):
            subprocess.run([args.usbboot, "--cpu", "x1000", *map(str, arguments)], check=True, timeout=20, stdout=subprocess.DEVNULL)

        prepare(args.usbboot, ROOT / "zig-out/bin/gain-spl.bin")
        if args.mode == "mixed":
            payload = bytearray(4 + len(cases) * 16)
            struct.pack_into("<I", payload, 0, len(cases))
            for index, fixture in enumerate(cases):
                data = fixture["path"].read_bytes()
                struct.pack_into("<4I", payload, 4 + index * 16, len(payload), len(data), fixture["rate"], fixture["frames"])
                payload.extend(data)
            bundle = temp / "mixed.bin"
            bundle.write_bytes(payload)
            duration = sum((case["frames"] + case["rate"] - 1) // case["rate"] + 1 for case in cases)
            cases = [dict(name="mixed", path=bundle, rate=1, frames=duration, count=len(cases))]
        for case in cases:
            name = f"{case['name']}-{args.mode}-x{args.repeat}"
            mode = MODES[args.mode]
            length = case["path"].stat().st_size if case["path"] else 0
            if length > 7 * 1024 * 1024:
                raise RuntimeError("Fixture exceeds the reserved RAM upload region")
            duration = case["frames"] if mode == 8 else args.seconds if mode >= 6 else max(2, (case["frames"] + case["rate"] - 1) // case["rate"])
            if duration * args.repeat > 600:
                raise RuntimeError("Keep each campaign within 600 seconds")
            parameters = temp / "parameters.bin"
            parameters.write_bytes(struct.pack("<8I", length, mode, args.repeat, duration, 0, 0, 0, 0))
            if case["path"]:
                usb("--addr", "0xa1800000", "--download", case["path"])
            usb("--addr", "0xa0700000", "--download", parameters)
            usb("--addr", "0x80004000", "--download", image, "--flush-caches", "--start1", "0x80004000")
            # Do not disturb ROM USB while tasks own the device. The target's
            # independent bounded deadline returns on a stalled campaign.
            wait = (duration + 1) * args.repeat + 1 if mode in (0, 6, 7, 8) else 3
            time.sleep(wait)
            report_file = output / f"{name}.report"
            usb("--addr", "0xa0700000", "--length", "128", "--upload", report_file)
            result = dict(zip(FIELDS, struct.unpack("<32I", report_file.read_bytes())))
            result.update(name=name, image_sha256=identity)
            if result["signature"] != 0x47415031 or result["revision"] != 1 or result["complete"] != 1 or result["cause"] != 0:
                raise RuntimeError(f"Incomplete or faulted campaign: {result}")
            if result["error_length"]:
                if result["error_length"] > 128:
                    raise RuntimeError("Invalid error-name length")
                error_file = temp / "error.txt"
                usb("--addr", "0xa0700100", "--length", result["error_length"], "--upload", error_file)
                result["error"] = error_file.read_text()
            results.append(result)
            (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
            if mode in (5, 7):
                expected = "Truncated" if mode == 5 else "CardRemoved"
                if result.get("error") != expected:
                    raise RuntimeError(f"Expected {expected}: {result}")
            else:
                subprocess.run([reader, report_file], check=True)
                if result["iterations"] != args.repeat * case.get("count", 1):
                    raise RuntimeError("Not all replays completed")
                if mode in (0, 8):
                    oracle = subprocess.run([ROOT / "zig-out/bin/player-reference", case["name"], str(args.repeat)], check=True, capture_output=True, text=True)
                    expected = int(oracle.stderr.strip(), 16)
                    if result["pcm_checksum"] != expected:
                        raise RuntimeError(f"Native/host PCM mismatch: {result['pcm_checksum']:08x} != {expected:08x}")
                if mode == 0 and (result["sample_rate"] != case["rate"] or (result["frames_high"] << 32 | result["frames_low"]) != case["frames"]):
                    raise RuntimeError("Presentation length or rate mismatch")
                if mode == 6 and result["exit"] != 1:
                    raise RuntimeError("SD track ended before the requested soak duration")
                if mode in (1, 2, 3) and result["exit"] != mode:
                    raise RuntimeError("Control exit mismatch")
            print(f"PASS {name}", flush=True)
    print(f"{len(results)} cases passed; evidence: {output}", flush=True)


if __name__ == "__main__":
    main()

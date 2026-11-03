"""Qualify production music UI pacing, playback and indexing over RAM-only USB.

Music is read-only; Gain may update its preallocated catalogue/artwork/log files.
Evidence must be outside the checkout. No NAND operations are available.
"""

from __future__ import annotations
import argparse
import ctypes
import json
from pathlib import Path
import struct
import subprocess
import time
import hashlib
import os
import shutil
from gain_metrics import Gain
from prepare_usb import prepare
from run_usb_checks import mounted_volume
from analyse_display_trace import analyse, qualify


def wait_sampled(monitor, out, predicate, timeout):
    deadline = time.monotonic() + timeout
    with (out / "scan-wait.jsonl").open("a", buffering=1) as stream:
        while True:
            status = monitor.status()
            stream.write(
                json.dumps(dict(host_s=time.monotonic(), status=status)) + "\n"
            )
            if (
                status["failure"]
                or status["scan_failure"]
                or status["live_underruns"]
                or (not status["scan_active"] and not status["scan_complete"])
            ):
                raise RuntimeError(f"Scan failed: {status}")
            if predicate(status):
                return status
            if time.monotonic() >= deadline:
                raise RuntimeError("Scan deadline exceeded")
            time.sleep(0.25)


ROOT = Path(__file__).resolve().parents[1]


def connect(timeout=40):
    deadline = time.monotonic() + timeout
    while True:
        try:
            monitor = Gain()
            monitor.status()
            return monitor
        except RuntimeError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.25)


def wait(monitor, predicate, timeout=40):
    deadline = time.monotonic() + timeout
    while True:
        status = monitor.status()
        if status["failure"] or status["scan_failure"]:
            raise RuntimeError(f"Device operation failed: {status}")
        if predicate(status):
            return status
        if time.monotonic() >= deadline:
            raise RuntimeError(f"Timeout: {status}")
        time.sleep(0.25)


def screen(monitor, output, name):
    # Read-only framebuffer chunks; intended for stable compositions, not an
    # atomic video capture or a presentation-timing measurement.
    raw = bytearray()
    while len(raw) < 320 * 240 * 2:
        chunk = ctypes.create_string_buffer(1024)
        n = monitor.lib.libusb_control_transfer(
            monitor.handle,
            0xC0,
            0x70,
            len(raw) // 1024,
            0,
            chunk,
            min(1024, 320 * 240 * 2 - len(raw)),
            3000,
        )
        if n <= 0:
            raise RuntimeError(f"Framebuffer read failed: {n}")
        raw.extend(chunk.raw[:n])
    (output / f"{name}.rgb565").write_bytes(raw)


def remote(monitor, button):
    monitor.command(
        "input",
        dict(select=0, back=1, home=2, up=3, down=4, volume_up=5, volume_down=6)[
            button
        ],
    )
    time.sleep(0.08)


def percentile(values, q):
    return (
        sorted(values)[min(len(values) - 1, int((len(values) - 1) * q))]
        if values
        else None
    )


def read_trace(monitor, start, end):
    raw = bytearray()
    for offset in range(0, 2048 * 16, 1024):
        data = ctypes.create_string_buffer(1024)
        count = monitor.lib.libusb_control_transfer(
            monitor.handle, 0xC0, 0x72, offset // 1024, 0, data, 1024, 3000
        )
        if count != 1024:
            raise RuntimeError(f"Timing trace read: {count}")
        raw.extend(data.raw)
    if end - start > 2048:
        raise RuntimeError("Timing trace overflow")
    entries = [
        dict(sequence=s, at=t, kind=k, value=v)
        for s, t, k, v in struct.iter_unpack("<4I", raw)
        if start <= s < end
    ]
    if len(entries) != end - start:
        raise RuntimeError("Incomplete timing trace")
    return sorted(entries, key=lambda e: e["sequence"])


def profile(monitor, out, name, replay):
    before = monitor.status()
    replay()
    time.sleep(0.8)
    after = monitor.status()
    trace = read_trace(monitor, before["ui_trace_next"], after["ui_trace_next"])
    commits = [e for e in trace if e["kind"] == 2]
    intervals = [
        ((b["at"] - a["at"]) & 0xFFFFFFFF) / 6000 for a, b in zip(commits, commits[1:])
    ]
    # Idle gaps between distinct user actions are included in all_intervals;
    # continuous intervals exclude gaps over 100 ms, and neither asserts FPS.
    continuous = [v for v in intervals if v < 100]
    renders = [e["value"] / 6000 for e in trace if e["kind"] == 1]
    report = dict(
        name=name,
        submissions=len(commits),
        pixels=sorted(set(e["value"] for e in commits)),
        retargets=sum(e["kind"] == 4 for e in trace),
        render_ms=dict(
            p50=percentile(renders, 0.5),
            p95=percentile(renders, 0.95),
            max=max(renders, default=0),
        ),
        interval_ms=dict(
            p50=percentile(continuous, 0.5),
            p95=percentile(continuous, 0.95),
            max=max(continuous, default=0),
        ),
        all_intervals_ms=intervals,
        played_frames=after["live_played_frames"] - before["live_played_frames"],
        underruns=after["live_underruns"],
        failure=after["failure"],
        scan_active=after["scan_active"],
    )
    (out / f"{name}.json").write_text(
        json.dumps(
            dict(summary=report, before=before, after=after, trace=trace), indent=2
        )
        + "\n"
    )
    print(
        json.dumps(
            {key: value for key, value in report.items() if key != "all_intervals_ms"}
        ),
        flush=True,
    )
    if (
        after["failure"]
        or after["live_underruns"]
        or (name != "flow-idle" and after["stage"] != 2)
    ):
        raise RuntimeError("Hardware interaction failed")
    return report


def inputs(monitor, buttons, delay):
    for button in buttons:
        remote(monitor, button) if delay is None else monitor.command(
            "input",
            dict(select=0, back=1, home=2, up=3, down=4, volume_up=5, volume_down=6)[
                button
            ],
        )
        if delay is not None:
            time.sleep(delay)


def deploy(usbboot, output):
    image = ROOT / "zig-out/bin/gain-instrumented.bin"
    data = image.read_bytes()
    if not 0 < len(data) <= 0x200000 - 0x4000:
        raise RuntimeError("Image exceeds its reserved firmware RAM")
    prepare(usbboot, ROOT / "zig-out/bin/gain-spl.bin")

    def usb(*arguments):
        subprocess.run(
            [usbboot, "--cpu", "x1000", *map(str, arguments)],
            check=True,
            capture_output=True,
            timeout=40,
        )

    usb(
        "--addr",
        "0x80004000",
        "--length",
        len(data),
        "--download",
        image,
        "--flush-caches",
    )
    actual = bytearray()
    chunk_path = output / "readback.chunk"
    while len(actual) < len(data):
        count = min(32768, len(data) - len(actual))
        usb(
            "--addr",
            hex(0xA0004000 + len(actual)),
            "--length",
            count,
            "--upload",
            chunk_path,
        )
        chunk = chunk_path.read_bytes()
        if len(chunk) != count:
            raise RuntimeError("Short RAM verification")
        actual.extend(chunk)
    chunk_path.unlink()
    if actual != data:
        raise RuntimeError("RAM readback differs; image was not started")
    shutil.copy2(image, output / "firmware.bin")
    (output / "image.json").write_text(
        json.dumps(
            dict(
                sha256=hashlib.sha256(data).hexdigest(),
                bytes=len(data),
                verified=True,
                nand_written=False,
            ),
            indent=2,
        )
        + "\n"
    )
    usb("--flush-caches", "--start1", "0x80004000")


def check_idle_selection(monitor, output, track):
    before = monitor.status()
    monitor.command("rebuild")
    wait(
        monitor,
        lambda status: status["scan_active"]
        and status["scan_publications"] > before["scan_publications"],
        timeout=30,
    )
    started = time.monotonic()
    monitor.command("play", track)
    playing = wait(
        monitor,
        lambda status: status["stage"] == 2
        and status["scan_cancelled"] > before["scan_cancelled"]
        and 4800 <= status["live_played_frames"] < 480000,
        timeout=3,
    )
    elapsed = time.monotonic() - started
    if elapsed > 2:
        raise RuntimeError(f"Idle scan delayed selected playback by {elapsed:.3f}s")
    wait(monitor, lambda status: status["scan_active"], timeout=10)
    monitor.command("stop")
    final = wait(
        monitor,
        lambda status: status["stage"] == 0
        and status["scan_complete"]
        and not status["scan_active"]
        and not status["scan_deferred_artwork"],
        timeout=120,
    )
    (output / "idle-scan-selection.json").write_text(
        json.dumps(
            dict(selection_to_played_100ms_s=elapsed, playing=playing, final=final),
            indent=2,
        )
        + "\n"
    )
    return final


def check_album_return(monitor, output):
    inputs(monitor, ["home", "down", "select"] + ["down"] * 6, None)
    time.sleep(0.8)
    screen(monitor, output, "album-before-tracks")
    inputs(monitor, ["select"], None)
    time.sleep(0.2)
    inputs(monitor, ["back"], None)
    time.sleep(0.8)
    screen(monitor, output, "album-after-back")
    before = (output / "album-before-tracks.rgb565").read_bytes()
    after = (output / "album-after-back.rgb565").read_bytes()
    if before != after:
        raise RuntimeError("Back did not restore the settled album composition")
    (output / "album-return.json").write_text(
        json.dumps(
            dict(passed=True, framebuffer_sha256=hashlib.sha256(after).hexdigest()),
            indent=2,
        )
        + "\n"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--usbboot", default=os.environ.get("GAIN_USBBOOT", "usbboot"))
    parser.add_argument(
        "--track",
        type=int,
        required=True,
        help="Catalogue index of a track long enough for the scan",
    )
    parser.add_argument("--build-id", type=int, required=True)
    parser.add_argument(
        "--resume", action="store_true", help="Use the matching running image"
    )
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    out = args.output.resolve()
    if out == ROOT or ROOT in out.parents:
        parser.error("Store reports outside the source checkout")
    if not 0 <= args.track <= 65535 or not 0 < args.build_id < 2**32:
        parser.error("Track must be 0..65535 and build identity 1..4294967295")
    out.mkdir(parents=True, exist_ok=True)
    if not args.resume:
        if not args.skip_build:
            subprocess.run(
                ["zig", "build", "-j4", "instrumented", f"-Dbuild-id={args.build_id}"],
                cwd=ROOT,
                check=True,
            )
        try:
            old = Gain()
            try:
                old.command("rom")
            finally:
                old.close()
        except RuntimeError:
            pass
        deploy(args.usbboot, out)
    monitor = connect()
    try:
        status = monitor.status()
        if status["build_id_low"] != args.build_id or status["build_id_high"]:
            raise RuntimeError("Running image does not match the qualification build")
        if status["usb_state"] in (1, 2, 3):
            status = wait(monitor, lambda s: s["usb_state"] == 2)
            disk, _ = mounted_volume(status["sectors"])
            subprocess.run(
                ["diskutil", "eject", disk], capture_output=True, check=True, timeout=30
            )
        wait(
            monitor,
            lambda s: s["stage"] == 0
            and s["index_tracks"] > 0
            and not s["scan_active"]
            and s["scan_complete"],
            timeout=120,
        )
        results = []

        def albums():
            inputs(monitor, ["home", "down", "select"], None)
            time.sleep(0.5)

        def flow():
            inputs(monitor, ["down"] * 24 + ["up"] * 18, 0.055)

        def volume():
            inputs(monitor, ["volume_up"] * 8 + ["volume_down"] * 8, 0.12)
            time.sleep(1.7)

        albums()
        results.append(profile(monitor, out, "flow-idle", flow))
        monitor.command("play", args.track)
        wait(monitor, lambda s: s["live_played_frames"] > 144000)
        albums()
        results.append(profile(monitor, out, "flow-playing", flow))
        inputs(monitor, ["home", "select"], None)
        results.append(profile(monitor, out, "volume-playing", volume))
        monitor.command("rebuild")
        wait(monitor, lambda s: s["scan_active"] == 1)
        albums()
        results.append(profile(monitor, out, "flow-scanning", flow))
        inputs(monitor, ["home", "select"], None)
        results.append(profile(monitor, out, "volume-scanning", volume))
        wait_sampled(
            monitor,
            out,
            lambda s: s["scan_complete"] and not s["scan_active"],
            timeout=120,
        )
        monitor.command("stop")
        final = wait(
            monitor,
            lambda s: s["stage"] == 0
            and not s["scan_active"]
            and not s["scan_deferred_artwork"],
            timeout=120,
        )
        analysed = {}
        for result in results:
            name = result["name"]
            report = json.loads((out / f"{name}.json").read_text())
            analysed[name] = analyse(
                report["trace"], 1 if name.startswith("flow") else 2
            )
        (out / "active-animation-timing.json").write_text(
            json.dumps(analysed, indent=2) + "\n"
        )
        gate = qualify(analysed)
        (out / "qualification.json").write_text(json.dumps(gate, indent=2) + "\n")
        if not gate["passed"]:
            raise RuntimeError(f"UI pacing regression: {gate['failures']}")
        final = check_idle_selection(monitor, out, args.track)
        # Exercise the retained folder browser and return via Menu.
        inputs(monitor, ["home", "down", "down", "down", "select"], None)
        time.sleep(0.5)
        screen(monitor, out, "folders")
        inputs(monitor, ["home", "down", "select"], None)
        time.sleep(0.5)
        screen(monitor, out, "albums")
        check_album_return(monitor, out)
        (out / "summary.json").write_text(
            json.dumps(
                dict(
                    build=final["build_id_low"],
                    profiles=results,
                    final=final,
                    nand_written=False,
                ),
                indent=2,
            )
            + "\n"
        )
    except BaseException as error:
        details = dict(passed=False, error=str(error))
        try:
            details["last_status"] = monitor.status()
            details["device_error"] = (
                monitor.read(0x71, 64)
                .split(b"\0", 1)[0]
                .decode("ascii", errors="replace")
            )
        except RuntimeError as unavailable:
            details["readback_error"] = str(unavailable)
        (out / "failure.json").write_text(json.dumps(details, indent=2) + "\n")
        raise
    finally:
        monitor.close()


if __name__ == "__main__":
    main()

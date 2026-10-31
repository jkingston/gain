"""Native simulator qualification, including real dynamic modules and screenshots."""
import argparse
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import time

from sim import SimulatorError, start


class Bitmap:
    def __init__(self, path):
        self.data = Path(path).read_bytes()
        assert self.data[:2] == b"BM"
        self.offset = struct.unpack_from("<I", self.data, 10)[0]
        self.width, self.height = struct.unpack_from("<ii", self.data, 18)
        self.bits = struct.unpack_from("<H", self.data, 28)[0]
        compression = struct.unpack_from("<I", self.data, 30)[0]
        assert self.bits in (24, 32) and compression in (0, 3)
        self.stride = ((self.width * self.bits + 31) // 32) * 4
        self.rows = abs(self.height)

    def pixel(self, x, y):
        row = self.rows - 1 - y if self.height > 0 else y
        offset = self.offset + row * self.stride + x * (self.bits // 8)
        blue, green, red = self.data[offset:offset + 3]
        return ((red >> 3) << 11) | ((green >> 2) << 5) | (blue >> 3)

    def counters(self):
        return tuple(self.pixel(i, 0) for i in range(5))


def replace_file(source, target):
    pending = target.with_suffix(".pending")
    shutil.copyfile(source, pending)
    pending.replace(target)


def main():
    if not __debug__:
        raise RuntimeError("Simulator qualification must run without Python optimization")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sim", required=True, type=Path)
    for name in ("good", "bad-version", "reject", "oversized", "missing", "changed"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--visible", action="store_true", help="Also exercise a native window and its real display density")
    args = parser.parse_args()
    processes = []
    with tempfile.TemporaryDirectory(prefix="gain-sim-check-") as temporary:
        root = Path(temporary)
        cleanup = root / "cleanup.log"
        os.environ["GAIN_SIM_CLEANUP_LOG"] = str(cleanup)
        app = root / ("library with spaces — é" + args.good.suffix)
        replace_file(args.good, app)
        process, client = start(args.sim, app, root / "instance one", headless=not args.visible)
        processes.append(process)
        counter = 0

        def shot(native=True):
            nonlocal counter
            counter += 1
            path = root / f"capture with spaces {counter}.bmp"
            result = client.send("capture", path=str(path), native=native)
            return Bitmap(path), result["geometry"]

        try:
            original, _ = shot()
            assert (original.width, original.rows) == (320, 240)
            assert original.counters() == (0, 0, 0, 0, 0)
            keys = ["up", "down", "select", "back", "menu", "previous", "next", "volume_up", "volume_down", "power"]
            for index, key in enumerate(keys):
                client.send("input", button=key)
                bitmap, _ = shot()
                assert bitmap.counters() == (index + 1, index + 1, 0, index, 0), (key, bitmap.counters())
            client.send("input", button="select", phase="press")
            client.send("input", button="select", phase="press")  # duplicated keydown
            client.send("input", button="select", phase="repeat")
            bitmap, _ = shot()
            assert bitmap.counters() == (11, 10, 1, 2, 4)
            client.send("input", button="select", phase="release")
            client.send("input", button="select", phase="release")
            client.send("input", button="select", phase="repeat")  # no repeat after release
            client.send("input", button="power", request_id=123456789)
            client.send("input", button="power", request_id=123456789)  # retry is not a second press
            before, _ = shot()
            assert before.counters() == (12, 12, 1, 9, 0)
            client.send("reload")
            after, _ = shot()
            assert before.data == after.data, "Reload lost app state"

            for bad, expected in ((args.bad_version, "IncompatibleAppVersion"), (args.missing, "MissingAppEntry"), (root / "absent", "AppCopyFailed")):
                try:
                    client.send("load", path=str(bad))
                    raise AssertionError("Invalid app was accepted")
                except SimulatorError as error:
                    assert expected in str(error), error
                current, _ = shot()
                assert current.data == before.data
                assert len(list(client.directory.glob("module-*"))) == 1, "Rejected modules leaked"

            # Rewrite the same path, as an app rebuild does. Rejected restoration is transactional.
            replace_file(args.reject, app)
            try:
                client.send("reload")
                raise AssertionError("Rejected state was accepted")
            except SimulatorError as error:
                assert "AppRestoreRejected" in str(error)
            current, _ = shot()
            assert current.data == before.data
            assert b"C" in cleanup.read_bytes(), "Rejected initialized candidate never ran deinit"
            replace_file(args.good, app)
            client.send("reload")
            client.send("load", path=str(args.oversized))
            client.send("input", button="menu")
            oversized, _ = shot()
            try:
                client.send("reload")
                raise AssertionError("Oversized state was accepted")
            except SimulatorError as error:
                assert "AppSnapshotTooLarge" in str(error)
            current, _ = shot()
            assert current.data == oversized.data
            client.send("load", path=str(app))

            for fields in ({"width": 319, "height": 240}, {"width": 320}, {"width": 320, "height": 100000}):
                try:
                    client.send("resize", **fields)
                    raise AssertionError("Invalid geometry was accepted")
                except SimulatorError:
                    pass
            try:
                client.send("capture", path=str(root / "missing" / "capture.bmp"))
                raise AssertionError("Capture failure was accepted")
            except SimulatorError as error:
                assert "CaptureFailed" in str(error)
            client.send("state")

            native, _ = shot()
            for width, height in ((320, 240), (641, 481), (960, 720), (1120, 800)):
                client.send("resize", width=width, height=height)
                window, geometry = shot(native=False)
                assert (window.width, window.rows) == (geometry["render_width"], geometry["render_height"])
                scale = geometry["scale"]
                x0, y0 = geometry["screen_x"], geometry["screen_y"]
                # RGB stripes change on every native pixel, detecting interpolation and uneven blocks.
                for y in range(0, 240, 7):
                    for x in range(0, 320, 7):
                        color = native.pixel(x, y)
                        for dx, dy in ((0, 0), (scale - 1, 0), (0, scale - 1), (scale - 1, scale - 1)):
                            assert window.pixel(x0 + x * scale + dx, y0 + y * scale + dy) == color

            # A second instance has independent control files and state.
            second, other = start(args.sim, app, root / "instance two", headless=True)
            processes.append(second)
            client.send("input", button="next")
            path = root / "other.bmp"
            other.send("capture", path=str(path))
            assert Bitmap(path).counters() == (0, 0, 0, 0, 0)
            duplicate = subprocess.run([str(args.sim), "--app", str(app), "--headless", "--control-dir", str(client.directory)], capture_output=True, timeout=5)
            assert duplicate.returncode != 0 and b"PathAlreadyExists" in duplicate.stderr
            other.send("quit")
            second.wait(timeout=5)
            assert second.returncode == 0

            # Automatic reload detects a changed module, not just re-initialisation of cached code.
            client.send("quit")
            process.wait(timeout=5)
            watched, client = start(args.sim, app, root / "watched", headless=True, watch=True)
            processes.append(watched)
            client.send("input", button="volume_up")
            replace_file(args.changed, app)
            deadline = time.monotonic() + 5
            while True:
                image, _ = shot()
                if image.pixel(5, 0) == 0xBEEF:
                    assert image.counters() == (1, 1, 0, 7, 0)
                    break
                assert time.monotonic() < deadline, "Auto-reload never published the changed app"
                time.sleep(0.03)
            client.send("quit")
            watched.wait(timeout=5)
            assert watched.returncode == 0
            assert not list(root.rglob("module-*")), "Module copies leaked after clean shutdown"
            assert b"F" in cleanup.read_bytes(), "Active app never ran deinit on shutdown"
            assert b"B" not in cleanup.read_bytes() and b"E" not in cleanup.read_bytes(), "Uninitialized module ran deinit"
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
    print("Simulator PASS: inputs, press/release/repeat, retry IDs, ABI/load failures, transactional reload, watch, Unicode paths, instance isolation, capture recovery and exact pixel scaling")


if __name__ == "__main__":
    main()

"""RAM image verification must finish before the music qualification can start."""

import ctypes
import hashlib
from pathlib import Path
import struct
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import run_music_checks as runner


class UploadTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="gain-music-upload-")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.root = self.base / "repo"
        self.image = self.root / "zig-out/bin/gain-instrumented.bin"
        self.image.parent.mkdir(parents=True)
        self.data = bytes(range(256)) * 160
        self.image.write_bytes(self.data)
        self.output = self.base / "evidence"
        self.output.mkdir()
        self.commands = []
        self.mismatch = False

    def command(self, arguments, **_):
        args = list(map(str, arguments))
        self.commands.append(args)
        if "--upload" in args:
            address = int(args[args.index("--addr") + 1], 0) - 0xA0004000
            count = int(args[args.index("--length") + 1])
            payload = self.data[address : address + count]
            if self.mismatch:
                payload = bytes([payload[0] ^ 1]) + payload[1:]
            Path(args[args.index("--upload") + 1]).write_bytes(payload)
        return subprocess.CompletedProcess(args, 0)

    def deploy(self):
        with (
            patch.object(runner, "ROOT", self.root),
            patch.object(runner, "prepare"),
            patch.object(runner.subprocess, "run", self.command),
        ):
            runner.deploy("usbboot", self.output)

    def test_every_uploaded_byte_is_verified_before_starting(self):
        self.deploy()
        self.assertEqual(self.data, (self.output / "firmware.bin").read_bytes())
        self.assertIn("--start1", self.commands[-1])
        self.assertEqual(2, sum("--upload" in args for args in self.commands))
        self.assertIn(
            hashlib.sha256(self.data).hexdigest(),
            (self.output / "image.json").read_text(),
        )
        addresses = [
            int(args[args.index("--addr") + 1], 0)
            for args in self.commands
            if "--addr" in args
        ]
        self.assertTrue(all(0x80004000 <= value < 0xA0200000 for value in addresses))

    def test_mismatched_readback_cannot_start_the_image(self):
        self.mismatch = True
        with self.assertRaisesRegex(RuntimeError, "readback differs"):
            self.deploy()
        self.assertFalse(any("--start1" in args for args in self.commands))

    def test_oversized_image_is_rejected_before_contacting_the_device(self):
        with self.image.open("wb") as stream:
            stream.truncate(runner.FIRMWARE_LIMIT + 1)
        with self.assertRaisesRegex(RuntimeError, "reserved firmware RAM"):
            self.deploy()
        self.assertEqual([], self.commands)


class TraceTests(unittest.TestCase):
    def read(self, first, end, corrupt=False):
        ring = bytearray(struct.pack("<4I", 0, 0, 1, 0) * 2048)
        span = (end - first) & 0xFFFFFFFF
        for delta in range(min(span, 2048)):
            sequence = (first + delta) & 0xFFFFFFFF
            struct.pack_into(
                "<4I", ring, (sequence % 2048) * 16,
                sequence, delta * 6000, 9, delta,
            )
        if corrupt:
            struct.pack_into(
                "<I", ring, (first % 2048) * 16, (first + 2048) & 0xFFFFFFFF
            )
        calls = []

        def transfer(handle, kind, request, chunk, index, data, length, timeout):
            calls.append(chunk)
            ctypes.memmove(data, bytes(ring[chunk * 1024:chunk * 1024 + length]), length)
            return length

        monitor = SimpleNamespace(handle=None, lib=SimpleNamespace(libusb_control_transfer=transfer))
        return runner.read_trace(monitor, first, end), calls

    def test_startup_unused_slots_do_not_duplicate_sequence_zero(self):
        result, calls = self.read(0, 3)
        self.assertEqual([0, 1, 2], [record["sequence"] for record in result])
        self.assertEqual(32, len(calls))

    def test_sequence_wrap_preserves_order_and_membership(self):
        result, _ = self.read(0xFFFFFFFE, 2)
        self.assertEqual([0xFFFFFFFE, 0xFFFFFFFF, 0, 1], [r["sequence"] for r in result])
        self.assertEqual([0, 1, 2, 3], [r["value"] for r in result])

    def test_overwritten_record_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "Incomplete timing trace"):
            self.read(100, 104, corrupt=True)

    def test_oversized_range_is_rejected_before_usb_reads(self):
        with self.assertRaisesRegex(RuntimeError, "Timing trace overflow"):
            runner.read_trace(None, 0, 2049)


if __name__ == "__main__":
    unittest.main()

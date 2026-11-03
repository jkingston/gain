"""RAM image verification must finish before the music qualification can start."""

import hashlib
from pathlib import Path
import subprocess
import tempfile
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
            stream.truncate(0x200000)
        with self.assertRaisesRegex(RuntimeError, "reserved firmware RAM"):
            self.deploy()
        self.assertEqual([], self.commands)


if __name__ == "__main__":
    unittest.main()

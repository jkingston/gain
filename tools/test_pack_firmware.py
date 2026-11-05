"""Image integrity and kernel-only update boundary checks."""
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zlib

import pack_firmware as pack


class FirmwareImages(unittest.TestCase):
    def test_firmware_and_loader_targets_and_mutations(self):
        for kind in ("firmware", "loader"):
            image = pack.envelope(bytes(range(256)), kind)
            self.assertEqual(kind, pack.validate(image, kind))
            for length in range(len(image)):
                with self.assertRaises(ValueError):
                    pack.validate(image[:length], kind)
            for offset in range(len(image)):
                corrupt = bytearray(image)
                corrupt[offset] ^= 1
                with self.assertRaises(ValueError):
                    pack.validate(corrupt, kind)
            with self.assertRaises(ValueError):
                pack.validate(image, "loader" if kind == "firmware" else "firmware")

    def test_memory_limits(self):
        for kind, limit in (("loader", pack.LOADER_LIMIT), ("firmware", pack.FIRMWARE_LIMIT)):
            for payload in (b"", bytes(limit + 1)):
                with self.assertRaises(ValueError):
                    pack.envelope(payload, kind)

    def test_update_only_targets_kernel_and_preserves_inputs(self):
        kernel = pack.envelope(b"native loader", "loader")
        version = b"synthetic-version\n"
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "update.upt"
            def inspect(command, check):
                root = Path(command[-1])
                self.assertEqual({"uimage.bin", "version.txt", "update.txt"}, {p.name for p in root.iterdir()})
                self.assertEqual(kernel, (root / "uimage.bin").read_bytes())
                self.assertEqual(version, (root / "version.txt").read_bytes())
                manifest = (root / "update.txt").read_text()
                self.assertTrue(manifest.startswith("kernel={\n"))
                self.assertEqual(1, manifest.count("={"))
                self.assertIn("autoupdate/uimage.bin", manifest)
                self.assertEqual(str(output.resolve()), command[-2])
            with patch.object(pack.subprocess, "run", side_effect=inspect):
                pack.update_package(kernel, version, output)
            output.write_bytes(b"preserved")
            with self.assertRaises(FileExistsError):
                pack.update_package(kernel, version, output)
            self.assertEqual(b"preserved", output.read_bytes())
            with self.assertRaises(ValueError):
                pack.update_package(pack.envelope(b"player", "firmware"), version, output)

    def test_stock_kernel_requires_gzip_mips_kernel_target(self):
        payload = b"synthetic compressed kernel"
        header = bytearray(struct.pack(">7I4B32s", pack.MAGIC, 0, 0, len(payload), 0x80010000, 0x803C2400, zlib.crc32(payload), 5, 5, 2, 1, b"Linux"))
        struct.pack_into(">I", header, 4, zlib.crc32(header))
        self.assertEqual("stock", pack.validate(bytes(header) + payload, "stock"))
        with self.assertRaises(ValueError):
            pack.validate(bytes(header) + payload, "loader")


if __name__ == "__main__":
    unittest.main()

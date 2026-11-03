import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zlib

import gain_metrics as gain


class MetricsTests(unittest.TestCase):
    def test_provision_preserves_user_data_and_reuses_only_owned_allocations(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sentinel = root / 'music.m4a'
            sentinel.write_bytes(b'user music')
            with patch.dict(gain.ALLOCATIONS, {'catalog.bin': (1, 8192)}, clear=True):
                self.assertEqual(gain.provision(root), {'catalog.bin': 'created'})
                self.assertEqual(gain.provision(root), {'catalog.bin': 'existing'})
                self.assertEqual(sentinel.read_bytes(), b'user music')
                path = root / '.gain/catalog.bin'
                path.write_bytes(b'unknown')
                with self.assertRaises(RuntimeError):
                    gain.provision(root)
                self.assertEqual(path.read_bytes(), b'unknown')

    def test_unknown_partial_file_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.gain').mkdir()
            partial = root / '.gain/catalog.bin.provisioning'
            partial.write_bytes(b'interrupted allocation')
            with patch.dict(gain.ALLOCATIONS, {'catalog.bin': (1, 8192)}, clear=True):
                with self.assertRaises(FileExistsError):
                    gain.provision(root)
            self.assertEqual(partial.read_bytes(), b'interrupted allocation')

    def test_log_reader_rejects_torn_pages_and_decodes_fault_names(self):
        raw = bytearray(4096)
        struct.pack_into('<4sHHQQQIHH', raw, 0, b'GLOG', 1, 40, 9, 17, 18, 0, 1, 400)
        struct.pack_into('<H', raw, 40, 6)
        struct.pack_into('<Q', raw, 48, 120)
        struct.pack_into('<I', raw, 56, 2)
        raw[60:68] = b'CardGone'
        struct.pack_into('<I', raw, 4092, zlib.crc32(raw[:4092]))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'diagnostics.bin'
            path.write_bytes(bytes(4096) + raw)
            report = gain.pages(path)
            self.assertEqual(report['pages'][0]['records'][0]['error'], 'CardGone')
            raw[200] ^= 1
            path.write_bytes(bytes(4096) + raw)
            self.assertEqual(gain.pages(path)['invalid_pages'], 1)

    def test_report_fields_match_firmware_abi(self):
        import re
        source = (Path(__file__).resolve().parents[1] / 'src/f20_diagnostics.zig').read_text()
        fields = re.findall(r'^    (\w+): u32 = ', source.split('pub const Report = extern struct {')[1].split('};')[0], re.M)
        self.assertEqual(gain.FIELDS, fields)

    def test_status_accepts_previous_report_prefix_during_firmware_upgrade(self):
        values = [0] * len(gain.FIELDS)
        values[0], values[2] = 0x474d4554, 1
        core = gain.FIELDS.index('index_io_failures') + 1
        monitor = object.__new__(gain.Gain)
        raw = struct.pack(f'<{core}I', *values[:core])
        with patch.object(gain.Gain, 'read', return_value=raw):
            status = monitor.status()
        self.assertEqual(status['index_io_failures'], 0)
        self.assertIsNone(status['index_stack_used'])

    def test_status_rejects_wrong_identity_and_truncated_or_oversized_reports(self):
        values = [0] * len(gain.FIELDS)
        values[0], values[2] = 0x474d4554, 1
        raw = struct.pack(f'<{len(values)}I', *values)
        monitor = object.__new__(gain.Gain)
        invalid = [raw[:-5], raw + bytes(4), raw[:-1], bytes(4) + raw[4:]]
        wrong_version = bytearray(raw)
        struct.pack_into('<I', wrong_version, 8, 2)
        invalid.append(bytes(wrong_version))
        for data in invalid:
            with self.subTest(length=len(data)):
                with patch.object(gain.Gain, 'read', return_value=data):
                    with self.assertRaises(RuntimeError):
                        monitor.status()


if __name__ == '__main__':
    unittest.main()

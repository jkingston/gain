import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import Mock, patch
import zlib

import gain_metrics as gain


class MetricsTests(unittest.TestCase):
    def test_health_rejects_unknown_versions_and_partial_snapshots(self):
        monitor = object.__new__(gain.Gain)
        values = [0] * len(gain.HEALTH_FIELDS)
        values[0] = 1
        raw = struct.pack(f'<{len(values)}I', *values)
        with patch.object(gain.Gain, 'read', return_value=raw):
            self.assertEqual(monitor.health()['version'], 1)
        for invalid in (raw[:-1], raw + bytes(4), bytes(4) + raw[4:]):
            with patch.object(gain.Gain, 'read', return_value=invalid):
                with self.assertRaises(RuntimeError):
                    monitor.health()

    def test_health_accepts_the_original_complete_snapshot_without_fabricating_ui_state(self):
        monitor = object.__new__(gain.Gain)
        count = gain.HEALTH_FIELDS.index("queue_cursor") + 1
        raw = struct.pack(f'<{count}I', 1, *([0] * (count - 1)))
        with patch.object(gain.Gain, 'read', return_value=raw):
            result = monitor.health()
        self.assertEqual(result['queue_cursor'], 0)
        self.assertIsNone(result['ui_locked'])
        self.assertIsNone(result['ui_backlight_active'])
        with patch.object(gain.Gain, 'read', return_value=raw + bytes(4)):
            with self.assertRaises(RuntimeError):
                monitor.health()

    def test_health_retries_the_legacy_exact_length_after_a_stalled_extension_request(self):
        monitor = object.__new__(gain.Gain)
        count = gain.HEALTH_FIELDS.index("queue_cursor") + 1
        raw = struct.pack(f'<{count}I', 1, *([0] * (count - 1)))
        with patch.object(gain.Gain, 'read', side_effect=[RuntimeError('stalled'), RuntimeError('stalled'), RuntimeError('stalled'), RuntimeError('stalled'), raw]) as read:
            self.assertEqual(monitor.health()['version'], 1)
            self.assertEqual(read.call_args_list[4].args, (0x73, count * 4))

    def test_health_accepts_ui_snapshot_without_fabricating_theme_result(self):
        monitor = object.__new__(gain.Gain)
        count = gain.HEALTH_FIELDS.index("theme_state")
        raw = struct.pack(f'<{count}I', 1, *([0] * (count - 1)))
        with patch.object(gain.Gain, 'read', side_effect=[RuntimeError('stalled'), raw]):
            result = monitor.health()
        self.assertEqual(result['ui_backlight_active'], 0)
        self.assertIsNone(result['theme_state'])

    def test_health_accepts_pre_mute_snapshot_without_fabricating_mute_state(self):
        monitor = object.__new__(gain.Gain)
        count = gain.HEALTH_FIELDS.index("output_soft_muted")
        raw = struct.pack(f'<{count}I', 1, *([0] * (count - 1)))
        with patch.object(gain.Gain, 'read', side_effect=[RuntimeError('stalled'), raw]):
            result = monitor.health()
        self.assertEqual(result['jack_flags'], 0)
        self.assertIsNone(result['output_soft_muted'])
        self.assertIsNone(result['output_hard_muted'])

    def test_connect_closes_stale_handles_before_retrying(self):
        with (patch.object(gain.Gain, '__init__', return_value=None),
              patch.object(gain.Gain, 'status', side_effect=[RuntimeError('detached'), {}]),
              patch.object(gain.Gain, 'close') as close,
              patch.object(gain.time, 'sleep')):
            monitor = gain.Gain.connect()
            self.assertIsInstance(monitor, gain.Gain)
            close.assert_called_once()

    def test_reconnect_waits_for_detach_instead_of_reopening_old_identity(self):
        monitor = object.__new__(gain.Gain)
        replacement = Mock()
        with (patch.object(gain.Gain, 'command') as command,
              patch.object(gain.Gain, 'status', side_effect=[{}, {}, RuntimeError('detached')]) as status,
              patch.object(gain.Gain, 'close') as close,
              patch.object(gain.Gain, 'connect', return_value=replacement) as connect,
              patch.object(gain.time, 'sleep')):
            self.assertIs(monitor.reconnect(), replacement)
            command.assert_called_once_with('reconnect')
            self.assertEqual(status.call_count, 3)
            close.assert_called_once()
            connect.assert_called_once()

    def test_reconnect_timeout_closes_old_handle_without_opening_another(self):
        monitor = object.__new__(gain.Gain)
        with (patch.object(gain.Gain, 'command'),
              patch.object(gain.Gain, 'status', return_value={}),
              patch.object(gain.Gain, 'close') as close,
              patch.object(gain.Gain, 'connect') as connect):
            with self.assertRaises(TimeoutError):
                monitor.reconnect(timeout=0)
            close.assert_called_once()
            connect.assert_not_called()

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




class SavedPlaylistTests(unittest.TestCase):
    def make_playlists(self, path, source=7):
        kind, size = gain.ALLOCATIONS['playlists.bin']
        data = bytearray(size)
        data[:512] = gain.prefix(kind, size)
        for slot, identities in ((0, [11, 11, 99]), (7, [22])):
            payload = bytearray(64 + len(identities) * 8)
            struct.pack_into('<4sH', payload, 0, b'GPS1', len(identities))
            struct.pack_into('<Q', payload, 8, source)
            struct.pack_into(f'<{len(identities)}Q', payload, 64, *identities)
            header = bytearray(512)
            struct.pack_into('<4sIIII', header, 0, b'GPLS', 1, 1, len(payload), zlib.crc32(payload))
            struct.pack_into('<Q', header, 24, source)
            struct.pack_into('<I', header, 508, zlib.crc32(header[:508]))
            offset = 4096 + slot * 2 * 80 * 1024
            data[offset:offset + 512] = header
            data[offset + 512:offset + 512 + len(payload)] = payload
        path.write_bytes(data)

    def test_export_resolves_saved_ids_retains_duplicates_and_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.gain').mkdir()
            path = root / '.gain/playlists.bin'
            self.make_playlists(path)
            catalog = dict(source=7, tracks=[dict(id=11, path='Music/世界/song.flac'), dict(id=22, path='Music/second.flac')])
            with patch.object(gain, 'catalogue', return_value=catalog):
                result = gain.export_playlists(root, root / 'Playlists')
                self.assertEqual(result[0]['missing'], 1)
                self.assertEqual((root / 'Playlists/Gain Saved 1.m3u8').read_text(), '#EXTM3U\n../Music/世界/song.flac\n../Music/世界/song.flac\n')
                with self.assertRaises(FileExistsError):
                    gain.export_playlists(root, root / 'Playlists')
            self.assertEqual(gain.saved_playlists(path, 8), [])

    def test_export_rejects_injected_paths_before_creating_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.gain').mkdir()
            self.make_playlists(root / '.gain/playlists.bin')
            catalog = dict(source=7, tracks=[dict(id=11, path='Music/bad\nname.flac')])
            with patch.object(gain, 'catalogue', return_value=catalog):
                with self.assertRaises(ValueError):
                    gain.export_playlists(root, root / 'Playlists')
            self.assertFalse((root / 'Playlists').exists())


if __name__ == '__main__':
    unittest.main()

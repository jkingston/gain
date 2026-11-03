#!/usr/bin/env python3
"""Provision bounded Gain caches, control a RAM development build and read logs.

Only host-mounted Gain SD volumes can be provisioned. Existing unknown files
are never replaced. Log inspection also works on a copied diagnostics.bin.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import struct
import time
import zlib

from run_usb_checks import Monitor, mounted_volume

FIELDS = '''magic usb_state version stage failure boot_ticks index_ticks index_load_ticks index_save_ticks index_tracks index_albums index_parsed index_reused index_errors index_bytes index_heap index_metadata_ticks index_artwork_ticks index_directory_ticks art_prepared art_reused log_pages log_failures log_dropped codec_ticks idle_ticks played_frames playback_runs playback_frames underruns startup_ticks fill_ticks ui_ticks ui_gap_ticks irq_ticks battery_mv charge_ua discharge_ua usb_mv usb_ua power_valid coulomb_charge coulomb_discharge adc_rate coulomb_running charge_uah discharge_uah battery_energy_uwh sectors index_runs index_read_sectors index_written_sectors index_io_ticks index_io_failures index_stack_used'''.split()
COMMANDS = dict(quick=0x61, verify=0x62, play=0x63, stop=0x64, reconnect=0x65, rom=0x66, flush=0x67)
ALLOCATIONS = {'catalog.bin': (1, 4096 + 2 * 6 * 1024 * 1024), 'artwork.bin': (2, 4096 + 16 * 1024 * 1024), 'diagnostics.bin': (3, 4096 + 8 * 1024 * 1024)}
KINDS = {1: 'boot', 2: 'playback', 3: 'library', 4: 'power', 5: 'usb', 6: 'fault', 7: 'health', 8: 'task_times', 9: 'library_phases', 10: 'library_io', 11: 'library_changes'}

LABELS = {
    'boot': 'boot_ticks',
    'library': 'scan_ticks tracks albums parsed reused errors logical_read_bytes arena_capacity load_ticks save_ticks art_prepared art_reused',
    'library_phases': 'directory_ticks metadata_ticks artwork_ticks metadata_max artwork_max',
    'library_io': 'read_sectors written_sectors reads writes io_ticks io_failures bus_hz scratch_bytes reserved_catalog_bytes stack_used',
    'library_changes': 'added changed renamed removed errors verify',
    'playback': 'sample_rate decoded_frames periods underruns fifo_min startup_ticks fill_max_ticks ui_max_ticks ui_gap_max_ticks irq_max_ticks heap_peak exit',
    'power': 'battery_mv charge_ua discharge_ua usb_mv usb_ua valid_flags charge_counter discharge_counter adc_rate counter_running',
}


def prefix(kind, size):
    out = bytearray(512)
    struct.pack_into('<4sHHI', out, 0, b'GPRV', 1, kind, size)
    struct.pack_into('<I', out, 508, zlib.crc32(out[:508]))
    return out


def valid_prefix(data, kind, size):
    return len(data) == 512 and data == prefix(kind, size)


def provision(mount):
    folder = mount / '.gain'
    if folder.is_symlink():
        raise RuntimeError('Cache directory must not be a symbolic link')
    folder.mkdir(exist_ok=True)
    results = {}
    zeros = bytes(1024 * 1024)
    for name, (kind, size) in ALLOCATIONS.items():
        target = folder / name
        if target.is_symlink():
            raise RuntimeError(f'Refusing symbolic link {target}')
        if target.exists():
            with target.open('rb') as stream:
                valid = target.stat().st_size == size and valid_prefix(stream.read(512), kind, size)
            if not valid:
                raise RuntimeError(f'Existing file has unknown allocation: {target}')
            results[name] = 'existing'
            continue
        # Exclusive temporary name, fully written (not sparse), header last.
        temporary = folder / (name + '.provisioning')
        try:
            with temporary.open('xb') as stream:
                remaining = size
                while remaining:
                    chunk = min(remaining, len(zeros))
                    stream.write(zeros[:chunk])
                    remaining -= chunk
                stream.flush()
                os.fsync(stream.fileno())
                stream.seek(0)
                stream.write(prefix(kind, size))
                stream.flush()
                os.fsync(stream.fileno())
            # FAT does not support hard links. The exclusive temporary path and
            # final absence check preserve unknown files on this single host.
            if target.exists():
                raise RuntimeError(f'Allocation destination appeared: {target}')
            temporary.rename(target)
            results[name] = 'created'
        except Exception:
            # Keep incomplete host-created allocation for inspection; do not
            # mistake it for a valid firmware cache.
            raise
    return results


class Gain(Monitor):
    def status(self):
        raw = self.read(0x60, len(FIELDS) * 4)
        core_fields = FIELDS.index('index_io_failures') + 1
        if len(raw) % 4 or not core_fields * 4 <= len(raw) <= len(FIELDS) * 4:
            raise RuntimeError(f'Unexpected metrics size: {len(raw)}')
        count = len(raw) // 4
        result = dict.fromkeys(FIELDS)
        result.update(zip(FIELDS, struct.unpack(f'<{count}I', raw)))
        if result['magic'] != 0x474D4554 or result['version'] != 1:
            raise RuntimeError('Not a matching Gain development build')
        return result

    def command(self, action, value=0):
        if action not in COMMANDS or not 0 <= value <= 65535:
            raise ValueError('Invalid Gain command')
        if self.status()['usb_state'] not in (0, 4):
            raise RuntimeError('Eject the SD card before controlling the player')
        buffer = ctypes.create_string_buffer(4)
        n = self.lib.libusb_control_transfer(self.handle, 0xC0, COMMANDS[action], value, 0, buffer, 4, 3000)
        if n != 4 or buffer.raw != struct.pack('<I', 0x4741494E):
            raise RuntimeError(f'Command was not acknowledged: {action} ({n})')


def pages(path):
    result = []
    invalid = 0
    with path.open('rb') as stream:
        stream.seek(4096)
        while raw := stream.read(4096):
            if len(raw) != 4096 or not any(raw):
                continue
            if (raw[:4] != b'GLOG' or struct.unpack_from('<HH', raw, 4) != (1, 40)
                or zlib.crc32(raw[:4092]) != struct.unpack_from('<I', raw, 4092)[0]):
                invalid += 1
                continue
            sequence, build, session, dropped, count, repeated = struct.unpack_from('<QQQIHH', raw, 8)
            if count > 63:
                invalid += 1
                continue
            records = []
            for i in range(count):
                at = 40 + i * 64
                kind = struct.unpack_from('<H', raw, at)[0]
                ticks = struct.unpack_from('<Q', raw, at + 8)[0]
                values = list(struct.unpack_from('<12I', raw, at + 16))
                row = dict(kind=KINDS.get(kind, f'unknown-{kind}'), ticks=ticks, values=values)
                if row['kind'] in LABELS:
                    row['fields'] = dict(zip(LABELS[row['kind']].split(), values))
                if kind == 6:
                    row['error'] = struct.pack('<11I', *values[1:]).split(b'\0')[0].decode('ascii', errors='replace')
                records.append(row)
            result.append(dict(sequence=sequence, build=f'{build:016x}', session=f'{session:016x}', dropped=dropped, repeated_faults=repeated, records=records))
    result.sort(key=lambda p: p['sequence'])
    return dict(pages=result, invalid_pages=invalid)


def catalogue(path):
    """Read the portable catalogue's track prefix; CRC covers the whole bank."""
    data = path.read_bytes()
    bank_size = (len(data) - 4096) // 2
    candidates = []
    for bank in range(2):
        at = 4096 + bank * bank_size
        header = data[at:at + 512]
        if len(header) != 512 or header[:4] != b'GCAT' or zlib.crc32(header[:508]) != struct.unpack_from('<I', header, 508)[0]:
            continue
        schema, generation, length, checksum, source = struct.unpack_from('<IQIIQ', header, 4)
        if schema != 1 or length > bank_size - 512:
            continue
        payload = data[at + 512:at + 512 + length]
        if len(payload) == length and zlib.crc32(payload) == checksum:
            candidates.append((generation, source, payload))
    if not candidates:
        raise RuntimeError('No committed catalogue bank')
    generation, source, payload = max(candidates, key=lambda candidate: candidate[0])
    position = 0

    def number(fmt):
        nonlocal position
        size = struct.calcsize('<' + fmt)
        if position + size > len(payload):
            raise ValueError('Truncated catalogue')
        value, = struct.unpack_from('<' + fmt, payload, position)
        position += size
        return value

    def text():
        nonlocal position
        length = number('I')
        if length > len(payload) - position:
            raise ValueError('Truncated catalogue string')
        value = payload[position:position + length].decode('utf-8')
        position += length
        return value

    def count():
        value = number('I')
        if value > 100000:
            raise ValueError('Catalogue element limit')
        return value

    def stamp():
        return dict(size=number('Q'), modified=number('q'), device=number('Q'), inode=number('Q'))

    def metadata():
        names = 'title artist album_artist album genre date sort_artist sort_album_artist release_id release_track_id codec'.split()
        values = {name: text() for name in names}
        values.update(track=number('I'), disc=number('I'), compilation=bool(number('B')), duration_ms=number('Q'), sample_rate=number('I'), channels=number('I'), bits=number('I'))
        for name in ('track_db', 'album_db', 'track_peak', 'album_peak'):
            values[name] = number('d') if number('B') else None
        values['embedded_art'] = bool(number('B'))
        values['tag_digest'] = text()
        for name in ('title_from_file', 'album_from_context', 'artist_from_context', 'album_artist_from_context'):
            values[name] = bool(number('B'))
        return values

    if number('I') != 1 or number('Q') != source or number('Q') != generation:
        raise ValueError('Catalogue header mismatch')
    for _ in range(count()):
        text()
        number('I')
        stamp()
    tracks = []
    for index in range(count()):
        track = dict(index=index, id=number('Q'), path=text(), stamp=stamp())
        track['meta'] = metadata()
        track['album_index'] = number('I')
        track['error'] = text()
        tracks.append(track)
    albums = []
    for index in range(count()):
        album = dict(index=index, id=number('Q'), key=text(), title=text(), artist=text(), directory=text())
        album['tracks'] = [number('I') for _ in range(count())]
        art = dict(recipe=text(), source=text(), stamp=stamp(), key=text(), cache_path=text())
        for name in ('x', 'y', 'width', 'height'):
            art[name] = number('H')
        art['error'] = text()
        album['artwork'] = art
        albums.append(album)
    return dict(generation=generation, source=source, tracks=tracks, albums=albums)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    commands.add_parser('status')
    catalog = commands.add_parser('catalogue')
    catalog.add_argument('path', type=Path)
    provision_parser = commands.add_parser('provision')
    provision_parser.add_argument('--sectors', type=int, required=True)
    logs = commands.add_parser('logs')
    logs.add_argument('path', type=Path)
    for action in COMMANDS:
        command = commands.add_parser(action)
        command.add_argument('--value', type=int, default=0)
    args = parser.parse_args()
    if args.action == 'provision':
        disk, mount = mounted_volume(args.sectors)
        result = dict(disk=disk, mount=str(mount), allocations=provision(mount))
    elif args.action == 'catalogue':
        result = catalogue(args.path)
    elif args.action == 'logs':
        result = pages(args.path)
    else:
        monitor = Gain()
        try:
            if args.action != 'status':
                monitor.command(args.action, args.value)
                time.sleep(0.05)
            result = monitor.status() if args.action != 'rom' else {'returning_to_rom': True}
        finally:
            monitor.close()
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()

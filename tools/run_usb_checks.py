#!/usr/bin/env python3
"""Qualify Finder-style USB SD transfer on an F20 using disposable files.

Requires macOS, libusb and an F20 in mask-ROM mode. Never formats a disk.
The USB identity, physical port, capacity and FAT volume are checked before I/O.
"""
import argparse
import ctypes
import ctypes.util
import hashlib
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import time

from prepare_usb import prepare

ROOT = Path(__file__).resolve().parents[1]
VENDOR, PRODUCT, SERIAL = 0xA108, 0x1002, "GAIN-F20-V27"
FIELDS = "magic version stage failure epc state sectors read_bytes written_bytes remounts remount_error loops charge_control usb_power last_command last_flags file_bytes file_checksum file_error playback_polls played_frames playback_stopped bytes_before_grant".split()
TEST_DIRECTORY = ".gain-usb-check"


def checked_status(data):
    if len(data) != 4 * len(FIELDS):
        raise RuntimeError("Wrong USB qualification report length")
    result = dict(zip(FIELDS, struct.unpack(f"<{len(FIELDS)}I", data)))
    if result["magic"] != 0x55534447 or result["version"] != 3:
        raise RuntimeError("Not the expected Gain USB qualification build")
    if result["failure"] or result["remount_error"]:
        raise RuntimeError(f"F20 qualification failed: {result}")
    return result


class Monitor:
    """Read-only control plus two ACKed lifecycle commands; no interface claim."""

    def __init__(self):
        library = ctypes.util.find_library("usb-1.0")
        if not library and Path("/opt/homebrew/lib/libusb-1.0.dylib").exists():
            library = "/opt/homebrew/lib/libusb-1.0.dylib"
        if not library:
            raise RuntimeError("Install libusb before running USB qualification")
        self.lib = ctypes.CDLL(library)
        pointer = ctypes.c_void_p
        signatures = {
            "libusb_init": ([ctypes.POINTER(pointer)], ctypes.c_int),
            "libusb_exit": ([pointer], None),
            "libusb_get_device_list": ([pointer, ctypes.POINTER(ctypes.POINTER(pointer))], ctypes.c_ssize_t),
            "libusb_free_device_list": ([ctypes.POINTER(pointer), ctypes.c_int], None),
            "libusb_get_device_descriptor": ([pointer, pointer], ctypes.c_int),
            "libusb_open": ([pointer, ctypes.POINTER(pointer)], ctypes.c_int),
            "libusb_close": ([pointer], None),
            "libusb_get_string_descriptor_ascii": ([pointer, ctypes.c_uint8, pointer, ctypes.c_int], ctypes.c_int),
            "libusb_control_transfer": ([pointer, ctypes.c_uint8, ctypes.c_uint8, ctypes.c_uint16, ctypes.c_uint16, pointer, ctypes.c_uint16, ctypes.c_uint], ctypes.c_int),
        }
        for name, (arguments, result) in signatures.items():
            function = getattr(self.lib, name)
            function.argtypes, function.restype = arguments, result
        self.context, self.handle = pointer(), pointer()
        if self.lib.libusb_init(ctypes.byref(self.context)):
            raise RuntimeError("libusb initialization failed")
        devices = ctypes.POINTER(pointer)()
        count = self.lib.libusb_get_device_list(self.context, ctypes.byref(devices))
        try:
            for index in range(max(0, count)):
                descriptor = ctypes.create_string_buffer(18)
                if self.lib.libusb_get_device_descriptor(devices[index], descriptor):
                    continue
                raw = descriptor.raw
                if struct.unpack_from("<HH", raw, 8) != (VENDOR, PRODUCT):
                    continue
                handle = pointer()
                if self.lib.libusb_open(devices[index], ctypes.byref(handle)):
                    continue
                serial = ctypes.create_string_buffer(64)
                length = self.lib.libusb_get_string_descriptor_ascii(handle, raw[16], serial, 64)
                if length > 0 and serial.raw[:length].decode("ascii", errors="replace") == SERIAL:
                    self.handle = handle
                    break
                self.lib.libusb_close(handle)
        finally:
            if count >= 0:
                self.lib.libusb_free_device_list(devices, 1)
        if not self.handle:
            self.close()
            raise RuntimeError("Gain SD card unavailable; allow the accessory in macOS if prompted")

    def close(self):
        if self.handle:
            self.lib.libusb_close(self.handle)
            self.handle = ctypes.c_void_p()
        if self.context:
            self.lib.libusb_exit(self.context)
            self.context = ctypes.c_void_p()

    def read(self, request, length):
        buffer = ctypes.create_string_buffer(length)
        count = self.lib.libusb_control_transfer(self.handle, 0xC0, request, 0, 0, buffer, length, 3000)
        if count < 0:
            raise RuntimeError(f"USB control request {request:#x} failed ({count})")
        return buffer.raw[:count]

    def status(self):
        return checked_status(self.read(0x5A, len(FIELDS) * 4))

    def command(self, request):
        if request not in (0x5B, 0x5F) or self.status()["state"] not in (0, 4):
            raise RuntimeError("Lifecycle command requires player ownership after eject")
        if self.read(request, 4) != struct.pack("<I", 0x4741494E):
            raise RuntimeError("Missing command acknowledgement")


def open_monitor(seconds=20):
    deadline = time.monotonic() + seconds
    while True:
        try:
            return Monitor()
        except RuntimeError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.25)


def plist(*arguments):
    return plistlib.loads(subprocess.check_output(["/usr/sbin/diskutil", *arguments], timeout=20))


def validate_disk(info, locations, sectors):
    """Pure fail-closed guard, tested without touching any disk."""
    if (
        info.get("BusProtocol") != "USB"
        or info.get("IORegistryEntryName") != "GAIN SD CARD Media"
        or info.get("Size") != sectors * 512
        or not info.get("WholeDisk")
        or info.get("Internal") is not False
        or not any(info.get("DeviceTreePath", "").lower().endswith(location) for location in locations)
    ):
        raise RuntimeError("Disk does not match the approved F20 USB identity, port and capacity")


def locate(sectors):
    devices = plistlib.loads(subprocess.check_output(
        ["/usr/sbin/ioreg", "-p", "IOService", "-n", "Gain SD card", "-r", "-a"], timeout=10
    ))
    locations = {
        f'@{device["locationID"]:08x}' for device in devices
        if device.get("idVendor") == VENDOR and device.get("idProduct") == PRODUCT
        and device.get("USB Serial Number") == SERIAL
    }
    matches = []
    for disk in plist("list", "-plist")["AllDisksAndPartitions"]:
        if disk.get("Size") != sectors * 512:
            continue
        info = plist("info", "-plist", disk["DeviceIdentifier"])
        try:
            validate_disk(info, locations, sectors)
        except RuntimeError:
            continue
        volumes = [info] + [plist("info", "-plist", part["DeviceIdentifier"]) for part in disk.get("Partitions", [])]
        volumes = [volume for volume in volumes if volume.get("MountPoint") and volume.get("FilesystemType") == "msdos"]
        if len(volumes) == 1:
            matches.append((info["DeviceIdentifier"], Path(volumes[0]["MountPoint"])))
    if len(matches) != 1:
        raise RuntimeError("Expected exactly one mounted FAT SD volume on the identified F20")
    return matches[0]


def mounted_volume(sectors, seconds=20):
    deadline = time.monotonic() + seconds
    while True:
        try:
            return locate(sectors)
        except RuntimeError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.25)


def wait_for(function, predicate, seconds=20):
    deadline = time.monotonic() + seconds
    while True:
        value = function()
        if predicate(value):
            return value
        if time.monotonic() >= deadline:
            raise RuntimeError(f"Timed out waiting for USB transition: {value}")
        time.sleep(0.1)


def checksum(data):
    value = 2166136261
    for byte in data:
        value = ((value ^ byte) * 16777619) & 0xFFFFFFFF
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--usbboot", default=os.environ.get("GAIN_USBBOOT", "usbboot"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    output = args.output.resolve()
    if output == ROOT or ROOT in output.parents:
        parser.error("Store qualification evidence outside the source checkout")
    if not args.skip_build:
        subprocess.run(["zig", "build", "usb-check-f20", "--summary", "all"], cwd=ROOT, check=True)
    image = ROOT / "zig-out/bin/gain-usb-check.bin"
    output.mkdir(parents=True, exist_ok=True)
    (output / "image-sha256.txt").write_text(hashlib.sha256(image.read_bytes()).hexdigest() + "\n")
    prepare(args.usbboot, ROOT / "zig-out/bin/gain-spl.bin")
    subprocess.run([args.usbboot, "--cpu", "x1000", "--addr", "0x80004000", "--download", str(image), "--flush-caches", "--start1", "0x80004000"], check=True, timeout=25)
    time.sleep(2)
    monitor = open_monitor()
    evidence = {"image_sha256": hashlib.sha256(image.read_bytes()).hexdigest()}
    try:
        before = wait_for(monitor.status, lambda value: value["state"] == 2)
        evidence["before"] = before
        if not before["playback_stopped"] or not before["played_frames"] or before["bytes_before_grant"]:
            raise RuntimeError("Playback-to-USB ownership handoff was not proved")
        disk, mount = mounted_volume(before["sectors"])
        folder = mount / TEST_DIRECTORY
        folder.mkdir()  # Refuse an existing directory; never reuse user data.
        payload = bytes(range(256)) * 4096
        expected = hashlib.sha256(payload).hexdigest()
        path = folder / "TRANSFER.BIN"
        began = time.monotonic()
        with path.open("xb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        evidence["write_seconds"] = time.monotonic() - began
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise RuntimeError("Host readback mismatch")
        renamed = folder / "Müsic 架空楽団.txt"
        renamed.write_text("Gain USB qualification\n")
        renamed.rename(folder / "Renamed.txt")
        (folder / "Renamed.txt").unlink()
        subprocess.run(["/usr/sbin/diskutil", "eject", disk], check=True, timeout=30)
        after = wait_for(monitor.status, lambda value: value["state"] == 4 and value["remounts"] > before["remounts"])
        evidence["after_eject"] = after
        if after["file_error"] or after["file_bytes"] != len(payload) or after["file_checksum"] != checksum(payload):
            raise RuntimeError("Independent device FAT readback mismatch")
        time.sleep(2)
        stable = monitor.status()
        if stable["state"] != 4 or stable["loops"] == after["loops"]:
            raise RuntimeError("Ejected disk remounted automatically or player loop stopped")
        monitor.command(0x5B)
        monitor.close()
        time.sleep(2)
        monitor = open_monitor()
        wait_for(monitor.status, lambda value: value["state"] == 2)
        disk, mount = mounted_volume(before["sectors"])
        path = mount / TEST_DIRECTORY / "TRANSFER.BIN"
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise RuntimeError("Fresh host mount readback mismatch")
        path.unlink()
        path.parent.rmdir()
        subprocess.run(["/usr/sbin/diskutil", "eject", disk], check=True, timeout=30)
        final = wait_for(monitor.status, lambda value: value["state"] == 4 and value["remounts"] >= before["remounts"] + 2)
        evidence["final"] = final
        if final["file_bytes"] or not final["usb_power"] or not final["charge_control"] & 0x80:
            raise RuntimeError("Cleanup, USB power or charging-enable qualification failed")
        evidence["passed"] = True
        monitor.command(0x5F)
    finally:
        monitor.close()
        (output / "usb-check.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence, indent=2))


if __name__ == "__main__":
    main()

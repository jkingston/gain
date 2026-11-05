"""Build and validate Gain SD images and kernel-only factory update packages.

This tool only writes host output files. It never opens a device or stages an
update on a card. The factory SPL/U-Boot and recovery are never package targets.
"""
import argparse
import hashlib
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib

MAGIC = 0x27051956
HEADER_BYTES = 64
FIRMWARE_ADDRESS = 0x80004000
FIRMWARE_LIMIT = 0x80280000 - FIRMWARE_ADDRESS
LOADER_ADDRESS = 0x80100000
LOADER_LIMIT = 0x18000
FIRMWARE_NAME = b"Gain F20 V2.7"
LOADER_NAME = b"Gain native SD loader"


def envelope(payload, kind):
    if kind not in ("firmware", "loader"):
        raise ValueError("Unknown image kind")
    firmware = kind == "firmware"
    limit = FIRMWARE_LIMIT if firmware else LOADER_LIMIT
    if not 0 < len(payload) <= limit:
        raise ValueError("Payload exceeds its fixed memory reservation")
    address = FIRMWARE_ADDRESS if firmware else LOADER_ADDRESS
    name = FIRMWARE_NAME if firmware else LOADER_NAME
    # Firmware is a standalone MIPS image. The native SD loader uses the
    # factory U-Boot kernel entry convention, without a Linux runtime.
    header = bytearray(struct.pack(
        ">7I4B32s", MAGIC, 0, 0, len(payload), address, address,
        zlib.crc32(payload), 17 if firmware else 5, 5, 5 if firmware else 2,
        0, name,
    ))
    struct.pack_into(">I", header, 4, zlib.crc32(header))
    image = bytes(header) + payload
    validate(image, kind)
    return image


def validate(image, kind=None):
    if len(image) < HEADER_BYTES:
        raise ValueError("Truncated image header")
    magic, checksum, _, size, load, entry, crc, os, arch, type, compression, name = struct.unpack(
        ">7I4B32s", image[:HEADER_BYTES]
    )
    header = bytearray(image[:HEADER_BYTES])
    header[4:8] = bytes(4)
    if magic != MAGIC or zlib.crc32(header) != checksum:
        raise ValueError("Invalid image header checksum or magic")
    if size == 0 or len(image) != HEADER_BYTES + size or zlib.crc32(image[HEADER_BYTES:]) != crc:
        raise ValueError("Invalid image size or payload checksum")
    if kind == "stock":
        if (os, arch, type, compression, load) != (5, 5, 2, 1, 0x80010000) or not load <= entry < 0x82000000 or size > 0x600000 - HEADER_BYTES:
            raise ValueError("Not a stock F20 kernel image")
        return "stock"
    if arch != 5 or compression != 0 or entry != load:
        raise ValueError("Unsupported image target")
    actual = None
    if (os, type, load, name) == (17, 5, FIRMWARE_ADDRESS, FIRMWARE_NAME.ljust(32, b"\0")) and size <= FIRMWARE_LIMIT:
        actual = "firmware"
    if (os, type, load, name) == (5, 2, LOADER_ADDRESS, LOADER_NAME.ljust(32, b"\0")) and size <= LOADER_LIMIT:
        actual = "loader"
    if actual is None or (kind is not None and actual != kind):
        raise ValueError("Wrong Gain board, image kind or address")
    return actual


def update_package(kernel, version, output, *, stock=False):
    validate(kernel, "stock" if stock else "loader")
    if not version or len(version) > 4096:
        raise ValueError("Use the version.txt supplied with the F20 V2.7 stock package")
    output = Path(output).resolve()
    if output.exists():
        raise FileExistsError(output)
    # Factory recovery recognizes this ISO layout and manifest. Only the normal
    # kernel slot is named: no bootloader, rootfs, recovery or data partition.
    with tempfile.TemporaryDirectory(prefix="gain-update-") as temporary:
        root = Path(temporary)
        (root / "uimage.bin").write_bytes(kernel)
        (root / "version.txt").write_bytes(version)
        digest = hashlib.md5(kernel).hexdigest()  # Factory manifest checksum.
        (root / "update.txt").write_text(
            "kernel={\n name=kernel\n file_path=autoupdate/uimage.bin\n"
            f" md5={digest}\n}}\n", encoding="ascii"
        )
        subprocess.run([
            "xorriso", "-as", "mkisofs", "-quiet", "-V", "CDROM", "-J",
            "-o", str(output), str(root),
        ], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("firmware", "loader", "update", "restore"))
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--version-file", type=Path)
    args = parser.parse_args()
    payload = args.input.read_bytes()
    if args.kind in ("firmware", "loader"):
        args.output.write_bytes(envelope(payload, args.kind))
    else:
        if args.version_file is None:
            parser.error("update/restore requires stock V2.7 --version-file")
        update_package(payload, args.version_file.read_bytes(), args.output, stock=args.kind == "restore")


if __name__ == "__main__":
    main()

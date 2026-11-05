"""Verify the linked F20 core, globals and USB DMA reservations."""
import argparse
from pathlib import Path
import struct

REGIONS = ((0x80004000, 0x80280000), (0x802A0000, 0x802C0000), (0x00280000, 0x002A0000))


def inspect(elf):
    if elf[:7] != b"\x7fELF\x01\x01\x01":
        raise ValueError("Expected little-endian ELF32")
    header = struct.unpack_from("<16sHHIIIIIHHHHHH", elf)
    if header[2] != 8 or header[4] != REGIONS[0][0]:
        raise ValueError("Wrong F20 core architecture or entry")
    sections = [struct.unpack_from("<10I", elf, header[6] + i * header[11]) for i in range(header[12])]
    names = sections[header[13]]
    strings = elf[names[4]:names[4] + names[5]]
    result = []
    for section in sections:
        name = strings[section[0]:].split(b"\0", 1)[0].decode()
        _, kind, flags, address, _, size, *_ = section
        if not flags & 2 or size == 0:
            continue
        allowed = REGIONS[1] if name == ".bss" else REGIONS[2] if name == ".usb_dma" else REGIONS[0]
        if flags & 0x400 or name in (".init_array", ".fini_array", ".dynamic"):
            raise ValueError(f"Unexpected hosted runtime section: {name}")
        if address < allowed[0] or address + size > allowed[1]:
            raise ValueError(f"Allocated section exceeds its reservation: {name}")
        if name in (".bss", ".usb_dma") and kind != 8:
            raise ValueError(f"Expected zero-initialized reservation: {name}")
        result.append({"name": name, "address": hex(address), "bytes": size})
    if not any(item["name"] == ".bss" for item in result):
        raise ValueError("Missing globals reservation")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("elf", type=Path)
    args = parser.parse_args()
    for section in inspect(args.elf.read_bytes()):
        print(f"{section['name']}: {section['bytes']} bytes at {section['address']}")


if __name__ == "__main__":
    main()

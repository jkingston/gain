#!/usr/bin/env python3
"""Check the actual MIPS ELF and SD envelope before publishing the component."""

import argparse
import pathlib
import struct

from pack_text_engine import (
    CODE_ADDRESS,
    CODE_CAPACITY,
    WORK_ADDRESS,
    WORK_CAPACITY,
    encode,
)


def inspect(elf, component):
    if elf[:7] != b"\x7fELF\x01\x01\x01":
        raise ValueError("Expected little-endian ELF32")
    header = struct.unpack_from("<16sHHIIIIIHHHHHH", elf)
    if header[2] != 8 or header[4] != CODE_ADDRESS:
        raise ValueError("Wrong architecture/entry")
    sections = [
        struct.unpack_from("<10I", elf, header[6] + i * header[11])
        for i in range(header[12])
    ]
    names = sections[header[13]]
    strings = elf[names[4] : names[4] + names[5]]
    allocated = []
    code_end = CODE_ADDRESS
    for section in sections:
        name = strings[section[0] :].split(b"\0", 1)[0].decode()
        _, kind, flags, address, offset, size, *_ = section
        if not flags & 2 or size == 0:
            continue
        if flags & 0x400 or name in (".init_array", ".fini_array", ".dynamic"):
            raise ValueError(f"Hosted runtime dependency: {name}")
        lower, capacity = (
            (WORK_ADDRESS, WORK_CAPACITY)
            if kind == 8
            else (CODE_ADDRESS, CODE_CAPACITY)
        )
        if address < lower or address + size > lower + capacity:
            raise ValueError(f"Section outside its reservation: {name}")
        if kind != 8:
            code_end = max(code_end, address + size)
            if name in (".text", ".startup"):
                for at in range(offset, offset + size, 4):
                    instruction = struct.unpack_from("<I", elf, at)[0]
                    if instruction & 0xFC00003F == 0x0000000C:
                        raise ValueError(f"OS syscall instruction in {name}")
        allocated.append({"name": name, "address": address, "bytes": size})
    data = bytearray(code_end - CODE_ADDRESS)
    for section in sections:
        _, kind, flags, address, offset, size, *_ = section
        if flags & 2 and kind != 8 and size:
            data[address - CODE_ADDRESS : address - CODE_ADDRESS + size] = elf[
                offset : offset + size
            ]
    if component != encode(data):
        raise ValueError("SD component does not match its checked ELF")
    return allocated


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--elf", type=pathlib.Path, required=True)
    parser.add_argument("--component", type=pathlib.Path, required=True)
    args = parser.parse_args()
    sections = inspect(args.elf.read_bytes(), args.component.read_bytes())
    print("Native text component: checked addresses, code, CRC, no OS/TLS dependency")
    for section in sections:
        print(f"{section['name']}: {section['bytes']:,} bytes")


if __name__ == "__main__":
    main()

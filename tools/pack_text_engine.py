#!/usr/bin/env python3
"""Wrap a fixed-address engine with a versioned, corruption-checked header."""

import argparse
import pathlib
import struct
import zlib

ENGINE_ABI = 2
CODE_ADDRESS = 0x81010000
CODE_CAPACITY = 1024 * 1024
WORK_ADDRESS = 0x80D78000
WORK_CAPACITY = 0x88000
HEADER_BYTES = 64


def encode(data):
    if not 0 < len(data) <= CODE_CAPACITY:
        raise ValueError("Text component exceeds its fixed RAM reservation")
    return (
        struct.pack(
            "<8s7I28x",
            b"GAINTE01",
            ENGINE_ABI,
            CODE_ADDRESS,
            CODE_CAPACITY,
            WORK_ADDRESS,
            WORK_CAPACITY,
            len(data),
            zlib.crc32(data),
        )
        + data
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    args.output.write_bytes(encode(args.input.read_bytes()))


if __name__ == "__main__":
    main()

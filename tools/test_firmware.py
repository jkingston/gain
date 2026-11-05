"""The actual ELF gate must reject overlapping or incorrectly loaded globals."""
import struct
import unittest

from check_firmware import inspect


def image(bss=0x802A0000, bss_size=4, bss_kind=8, text=0x80004000, text_size=4):
    names = b"\0.text\0.bss\0.usb_dma\0.shstrtab\0"
    header = struct.pack("<16sHHIIIIIHHHHHH", b"\x7fELF\x01\x01\x01".ljust(16, b"\0"), 2, 8, 1, 0x80004000, 0, 64, 0, 52, 0, 0, 40, 5, 4)
    sections = [(0, 0, 0, 0, 0, 0), (1, 1, 2, text, 0, text_size), (7, bss_kind, 2, bss, 0, bss_size), (12, 8, 2, 0x280000, 0, 4), (21, 3, 0, 0, 264, len(names))]
    return header.ljust(64, b"\0") + b"".join(struct.pack("<10I", *section, 0, 0, 0, 0) for section in sections) + names


class FirmwareLayout(unittest.TestCase):
    def test_valid_code_globals_and_uncached_window(self):
        self.assertEqual(3, len(inspect(image())))

    def test_globals_cannot_overlap_code_dma_or_escape_the_reservation(self):
        for address in (0x801F0000, 0x80280000, 0x802C0000):
            with self.assertRaises(ValueError):
                inspect(image(bss=address))
        with self.assertRaises(ValueError):
            inspect(image(bss_size=0x20001))
        with self.assertRaises(ValueError):
            inspect(image(bss_kind=1))

    def test_code_cannot_overwrite_the_usb_window(self):
        with self.assertRaises(ValueError):
            inspect(image(text=0x8027FFFC, text_size=8))


if __name__ == "__main__":
    unittest.main()

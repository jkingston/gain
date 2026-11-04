"""Corruption and bounds tests for the production component envelope gate."""

import unittest

from pack_text_engine import CODE_CAPACITY, encode


class TextEnvelopeTests(unittest.TestCase):
    def test_header_matches_device_contract(self):
        import struct
        import zlib

        payload = b"synthetic component code"
        image = encode(payload)
        self.assertEqual(len(image), 64 + len(payload))
        self.assertEqual(image[:8], b"GAINTE01")
        self.assertEqual(struct.unpack_from("<I", image, 28)[0], len(payload))
        self.assertEqual(struct.unpack_from("<I", image, 32)[0], zlib.crc32(payload))
        self.assertEqual(image[64:], payload)

    def test_invalid_capacity_is_rejected(self):
        for payload in (b"", bytes(CODE_CAPACITY + 1)):
            with self.assertRaises(ValueError):
                encode(payload)

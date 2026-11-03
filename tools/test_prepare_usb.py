"""Recovery waits for enumeration rather than assuming a fixed handoff delay."""

from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch
from prepare_usb import wait_for_rom


class RecoveryTests(unittest.TestCase):
    @patch("prepare_usb.time.sleep")
    @patch("prepare_usb.subprocess.run")
    def test_retry_until_expected_identity(self, run, sleep):
        run.side_effect = [
            subprocess.CompletedProcess([], 1, b"", b"not ready"),
            subprocess.CompletedProcess([], 0, b"CPU info: X1000_v1\n", b""),
        ]
        wait_for_rom(Path("/tmp/usbboot"))
        self.assertEqual(2, run.call_count)
        sleep.assert_called_once_with(0.2)

    @patch("prepare_usb.time.sleep")
    @patch("prepare_usb.time.monotonic", side_effect=[0, 31])
    @patch("prepare_usb.subprocess.run")
    def test_wrong_or_missing_identity_never_authorizes_upload(self, run, clock, sleep):
        run.return_value = subprocess.CompletedProcess(
            [], 0, b"Could not open USB device", b""
        )
        with self.assertRaisesRegex(RuntimeError, "did not enumerate"):
            wait_for_rom(Path("/tmp/usbboot"))
        sleep.assert_not_called()


if __name__ == "__main__":
    unittest.main()

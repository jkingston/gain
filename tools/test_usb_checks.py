import unittest
from run_usb_checks import checked_status, checksum, validate_disk


class UsbGuards(unittest.TestCase):
    def test_only_expected_physical_sd_disk_is_accepted(self):
        info = dict(BusProtocol="USB", IORegistryEntryName="GAIN SD CARD Media", Size=8192, TotalSize=7680, WholeDisk=True, Internal=False, DeviceTreePath="IOService:/usb@02100000")
        validate_disk(info, {"@02100000"}, 16)
        for field, wrong in dict(BusProtocol="PCI", IORegistryEntryName="Other disk", Size=4096, WholeDisk=False, Internal=True, DeviceTreePath="IOService:/usb@02200000").items():
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                validate_disk(info | {field: wrong}, {"@02100000"}, 16)
        with self.assertRaises(RuntimeError):
            validate_disk(info, set(), 16)

    def test_report_version_length_and_device_failures_are_rejected(self):
        import struct
        data = [0x55534447, 3] + [0] * 21
        self.assertEqual(3, checked_status(struct.pack("<23I", *data))["version"])
        for index in (0, 1, 3, 10):
            invalid = data.copy()
            invalid[index] = 123
            with self.subTest(index=index), self.assertRaises(RuntimeError):
                checked_status(struct.pack("<23I", *invalid))
        with self.assertRaises(RuntimeError):
            checked_status(b"short")

    def test_device_checksum_reference(self):
        self.assertEqual(0x4F9F2CAB, checksum(b"hello"))

    def test_monitor_waits_for_mac_enumeration_before_qualification(self):
        from unittest.mock import patch
        from run_usb_checks import open_monitor
        expected = object()
        with patch("run_usb_checks.Monitor", side_effect=[RuntimeError("enumerating"), expected]) as constructor, patch("run_usb_checks.time.sleep") as sleep:
            self.assertIs(expected, open_monitor())
            self.assertEqual(2, constructor.call_count)
            sleep.assert_called_once_with(0.25)
        with patch("run_usb_checks.Monitor", side_effect=RuntimeError("unavailable")), patch("run_usb_checks.time.monotonic", side_effect=[0, 2]):
            with self.assertRaisesRegex(RuntimeError, "unavailable"):
                open_monitor(seconds=1)

    def test_ownership_ready_does_not_assume_finder_has_mounted_yet(self):
        from unittest.mock import patch
        from run_usb_checks import mounted_volume
        expected = ("disk42", "/Volumes/F20")
        with patch("run_usb_checks.locate", side_effect=[RuntimeError("mounting"), expected]), patch("run_usb_checks.time.sleep") as sleep:
            self.assertEqual(expected, mounted_volume(1234))
            sleep.assert_called_once_with(0.25)

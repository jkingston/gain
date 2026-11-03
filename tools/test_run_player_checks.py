"""Host regression tests for the RAM-only qualification transport policy."""
import contextlib
import io
from pathlib import Path
import struct
import tempfile
import subprocess
import unittest
from unittest.mock import patch

import run_player_checks as runner


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="gain-runner-test-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / "repo"
        (self.root / "tests/fixtures").mkdir(parents=True)
        self.fixture = self.root / "tests/fixtures/fixture.wav"
        self.fixture.write_bytes(b"synthetic")
        (self.root / "tests/codec_fixtures.zig").write_text('.{ .name = "fixture", .bytes = @embedFile("fixtures/fixture.wav"), .rate = 48000, .frames = 48000 },\n')
        (self.root / "zig-out/bin").mkdir(parents=True)
        (self.root / "zig-out/bin/gain-player-check.bin").write_bytes(b"image")
        self.calls = []
        self.phy = 31
        self.complete = 1

    def command(self, arguments, **_):
        args = list(map(str, arguments))
        self.calls.append(args)
        if args[0] == "usbboot" and "--cpuinfo" in args:
            return subprocess.CompletedProcess(args, 0, b"X1000_v1", b"")
        if args[0].endswith("player-reference"):
            return subprocess.CompletedProcess(args, 0, "", "0\n")
        if args[0] == "usbboot" and "--upload" in args:
            path = Path(args[args.index("--upload") + 1])
            if "0xb301100c" in args:
                path.write_bytes(struct.pack("<I", self.phy))
            else:
                values = dict.fromkeys(runner.FIELDS, 0)
                values.update(signature=0x47415031, revision=1, complete=self.complete, sample_rate=48000, frames_low=48000, periods=100, ui_polls=2, iterations=1)
                path.write_bytes(struct.pack("<32I", *(values[name] for name in runner.FIELDS)))

    def run_campaign(self, *extra):
        arguments = ["runner", "--skip-build", "--usbboot", "usbboot", "--output", str(self.base / "evidence"), *extra]
        with patch.object(runner, "ROOT", self.root), patch("sys.argv", arguments), patch.object(runner.subprocess, "run", self.command), patch.object(runner.time, "sleep"), contextlib.redirect_stdout(io.StringIO()):
            runner.main()

    def test_warm_rom_never_retrains_dram_or_writes_persistent_storage(self):
        self.run_campaign()
        self.assertFalse(any("--stage1" in call for call in self.calls))
        destinations = [call[call.index("--addr") + 1] for call in self.calls if "--download" in call]
        self.assertEqual(destinations, ["0xa1800000", "0xa0700000", "0x80004000"])
        self.assertTrue(any(call[0].endswith("read-player-check") for call in self.calls))

    def test_cold_rom_trains_once_before_uploading_program(self):
        self.phy = 7
        self.run_campaign()
        training = [index for index, call in enumerate(self.calls) if "--stage1" in call]
        download = next(index for index, call in enumerate(self.calls) if "--download" in call)
        self.assertEqual(len(training), 1)
        self.assertLess(training[0], download)

    def test_unknown_phy_state_does_not_train_or_download(self):
        self.phy = 19
        with self.assertRaisesRegex(RuntimeError, "Unexpected F20 PHY"):
            self.run_campaign()
        self.assertFalse(any("--stage1" in call or "--download" in call for call in self.calls))

    def test_incomplete_report_cannot_be_accepted_by_the_budget_reader(self):
        self.complete = 0
        with self.assertRaisesRegex(RuntimeError, "Incomplete"):
            self.run_campaign()
        self.assertFalse(any(call[0].endswith("read-player-check") for call in self.calls))

    def test_oversized_fixture_is_rejected_before_any_ram_download(self):
        with self.fixture.open("wb") as file:
            file.truncate(7 * 1024 * 1024 + 1)
        with self.assertRaisesRegex(RuntimeError, "reserved RAM"):
            self.run_campaign()
        self.assertFalse(any("--download" in call for call in self.calls))

    def test_reports_cannot_be_written_into_the_production_checkout(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            self.run_campaign("--output", str(self.root / "reports"))
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()

"""Exercise the production UI app with a synthetic card or an optional SD root.

The app owns file access and its test transport clock. No SDL timing or physical
F20 performance is inferred from these host checks.
"""

from __future__ import annotations

import argparse
import ctypes as c
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time

from mock_sd import ROOT, create, tagged_flac

BUTTONS = {
    name: index
    for index, name in enumerate(
        (
            "up",
            "down",
            "select",
            "back",
            "menu",
            "previous",
            "next",
            "volume_up",
            "volume_down",
            "power",
        )
    )
}
Pixels = c.c_uint16 * (320 * 240)


class Event(c.Structure):
    _fields_ = [("input", c.c_uint32), ("phase", c.c_uint32)]


class Api(c.Structure):
    _fields_ = [
        (name, c.c_uint32) for name in ("version", "size", "width", "height", "format")
    ]
    _fields_ += [
        ("init", c.CFUNCTYPE(None, c.c_uint64)),
        ("input", c.CFUNCTYPE(None, Event, c.c_uint64)),
        ("frame", c.CFUNCTYPE(c.c_bool, c.POINTER(Pixels), c.c_uint64)),
        ("save", c.c_void_p),
        ("restore", c.c_void_p),
        ("deinit", c.CFUNCTYPE(None)),
    ]


class Status(c.Structure):
    _fields_ = [
        (name, c.c_uint32)
        for name in (
            "version",
            "screen",
            "selection",
            "first",
            "rows",
            "tracks",
            "albums",
            "artists",
            "revision",
            "scanning",
            "failure",
            "scan_failure",
            "parsed",
            "reused",
            "playing",
            "held",
        )
    ] + [("selected_id", c.c_uint64), ("playing_id", c.c_uint64)]


class TextStatus(c.Structure):
    _fields_ = [
        (name, c.c_uint32)
        for name in (
            "version",
            "revision",
            "hits",
            "misses",
            "pending",
            "failures",
            "prepared",
            "heap_peak",
        )
    ]


class PlaybackStatus(c.Structure):
    _fields_ = [(name, c.c_uint32) for name in (
        "version", "count", "cursor", "shuffle", "repeat", "menu_open", "menu_selection", "paused", "sample_rate"
    )] + [("played_frames", c.c_uint64), ("total_frames", c.c_uint64)]


class Player:
    def __init__(self, app, root):
        self.module = c.CDLL(str(app))
        self.module.gain_app_api.restype = c.POINTER(Api)
        self.module.gain_player_ui_status.argtypes = [c.POINTER(Status)]
        self.module.gain_player_playback_status.argtypes = [c.POINTER(PlaybackStatus)]
        self.module.gain_player_queue_item.argtypes = [c.c_uint32]
        self.module.gain_player_queue_item.restype = c.c_uint64
        self.module.gain_player_environment.argtypes = [c.c_uint32] * 4
        self.module.gain_player_environment.restype = c.c_bool
        self.api = self.module.gain_app_api().contents
        if (
            self.api.version,
            self.api.size,
            self.api.width,
            self.api.height,
            self.api.format,
        ) != (2, c.sizeof(Api), 320, 240, 565):
            raise RuntimeError("Incompatible simulator app")
        self.pixels = Pixels()
        self.now = 0
        self.old_root = os.environ.get("GAIN_SD_ROOT")
        os.environ["GAIN_SD_ROOT"] = str(root)
        self.api.init(0)

    def close(self):
        self.api.deinit()
        if self.old_root is None:
            os.environ.pop("GAIN_SD_ROOT", None)
        else:
            os.environ["GAIN_SD_ROOT"] = self.old_root

    def status(self):
        value = Status()
        self.module.gain_player_ui_status(c.byref(value))
        result = {name: getattr(value, name) for name, _ in Status._fields_}
        if result["version"] != 1 or result["failure"] or result["scan_failure"]:
            raise RuntimeError(f"Player UI failure: {result}")
        return result

    def playback(self):
        value = PlaybackStatus()
        self.module.gain_player_playback_status(c.byref(value))
        result = {name: getattr(value, name) for name, _ in PlaybackStatus._fields_}
        assert result["version"] == 1
        return result

    def queue(self):
        return [self.module.gain_player_queue_item(i) for i in range(self.playback()["count"])]

    def home(self):
        self.edge("menu")
        self.frame(510)
        self.edge("menu", False)
        return self.frame()

    def text_status(self):
        value = TextStatus()
        self.module.gain_player_ui_text_status(c.byref(value))
        return {name: getattr(value, name) for name, _ in TextStatus._fields_}

    def frame(self, elapsed=17):
        self.now += elapsed
        self.api.frame(c.byref(self.pixels), self.now)
        return self.status()

    def edge(self, button, pressed=True, phase=None):
        self.now += 1
        self.api.input(
            Event(
                BUTTONS[button], phase if phase is not None else (0 if pressed else 1)
            ),
            self.now,
        )

    def tap(self, *buttons):
        for button in buttons:
            self.edge(button)
            self.edge(button, False)
        return self.frame()

    def settle_scan(self):
        deadline = time.monotonic() + 30
        while True:
            result = self.frame()
            if not result["scanning"]:
                return result
            if time.monotonic() >= deadline:
                raise RuntimeError("Host SD scan timed out")
            time.sleep(0.002)


def qualify(app, root, synthetic=False):
    player = Player(app, root)
    try:
        initial = player.settle_scan()
        # Drive app-only power/USB fixtures through the actual renderer. The
        # generic simulator remains unaware of these device states.
        environment = player.module.gain_player_environment
        for millivolts in (0, 3300, 3600, 3800, 4200):
            assert environment(millivolts, 0, 0, 0)
            player.frame()
            if millivolts == 4200:
                fill = player.pixels[25 * 320 + 288]
                assert fill != player.pixels[19 * 320 + 279]
                assert all(
                    player.pixels[y * 320 + x] == fill
                    for y in range(20, 30)
                    for x in range(280, 300)
                )
        before_usb = player.status()
        for phase in (1, 2, 3):
            assert environment(3800, 1, phase, 1)
            player.frame()
            assert not player.api.frame(c.byref(player.pixels), player.now + 1)
            player.tap("next", "select")
            after_usb = player.status()
            assert (after_usb["screen"], after_usb["selection"]) == (
                before_usb["screen"], before_usb["selection"]
            )
        assert environment(4140, 0, 0, 0)
        player.frame()
        assert not environment(6000, 0, 0, 0)
        assert not environment(4000, 2, 0, 0)
        if synthetic:
            assert (initial["tracks"], initial["albums"], initial["artists"]) == (
                192,
                4,
                4,
            ), initial
            # The generated card includes fictional Arabic, CJK and Korean
            # names. Prepare them through the app worker, then prove that
            # ordinary stable frames reuse labels without invoking the engine.
            player.tap("select", "next", "select")
            deadline = time.monotonic() + 10
            while True:
                player.frame()
                text = player.text_status()
                if text["prepared"] > 0 and not text["pending"]:
                    break
                if time.monotonic() > deadline:
                    raise RuntimeError(f"Text worker timed out: {text}")
                time.sleep(0.002)
            if text["failures"] or text["heap_peak"] > (960 + 232) * 1024:
                raise RuntimeError(f"Text worker failed: {text}")
            for _ in range(120):
                player.frame()
            assert player.text_status()["prepared"] == text["prepared"]
            player.home()
            artist = player.tap("select", "next", "select", "select", "select")
            assert artist["rows"] == 48, artist
            player.tap("next", "next", "next")
            chosen = player.status()["selected_id"]
            playing = player.tap("select")
            assert playing["playing"] and playing["playing_id"] == chosen, playing
            player.tap("select")
            # Manual update uses the same scanner and reuses unchanged native tags.
            player.home()
            player.tap("next", "select", "next", "select", "select")
            updated = player.settle_scan()
            assert updated["reused"] == 192 and updated["parsed"] == 0, updated
            changed = sorted(root.rglob("*.flac"))[0]
            changed.write_bytes(
                tagged_flac(
                    changed.read_bytes(),
                    {
                        "TITLE": "Changed synthetic title",
                        "ARTIST": changed.parent.parent.name,
                        "ALBUMARTIST": changed.parent.parent.name,
                        "ALBUM": changed.parent.name,
                        "TRACKNUMBER": 1,
                        "DISCNUMBER": 1,
                    },
                )
            )
            player.tap("select")
            retagged = player.settle_scan()
            assert retagged["reused"] == 191 and retagged["parsed"] == 1, retagged
            changed.unlink()
            player.tap("select")
            removed = player.settle_scan()
            assert removed["tracks"] == 191 and removed["reused"] == 191, removed
            player.home()
            player.tap("select", "next", "next", "select")
            start = player.status()["selection"]
            player.edge("next")
            assert player.frame(318)["selection"] == start + 1
            assert player.frame(2)["selection"] == start + 2
            fast = player.frame(1800)
            assert fast["selection"] > start + 3, fast
            player.edge("next", False)
            stopped = player.frame()["selection"]
            assert player.frame(5000)["selection"] == stopped
            assert player.tap("previous")["selection"] == stopped - 1
        # Collection actions, playback modes and queue selection use the real
        # app callbacks. No private library filenames or app-specific host UI.
        player.home()
        player.tap("select", "select")  # Music -> Albums
        player.tap("menu", "select")  # Play All in the selected album
        assert player.status()["playing"]
        original = player.queue()
        assert original and len(original) == len(set(original))
        # A long transport press changes position once, on release, with the
        # current track and captured queue intact. The app clock is deterministic.
        player.tap("select")  # Pause so the expected position has no wall-time drift.
        current_id = player.status()["playing_id"]
        position = player.playback()["played_frames"]
        player.edge("next")
        player.frame(450)
        assert player.status()["playing_id"] == current_id
        assert player.playback()["played_frames"] == position
        player.edge("next", False)
        player.frame()
        assert player.playback()["played_frames"] > position
        assert player.playback()["paused"] == 1
        assert player.queue() == original
        # Hold Back provides queue access without consuming a short Back.
        player.edge("back")
        player.frame(510)
        player.edge("back", False)
        player.frame()
        assert player.status()["screen"] == 2
        assert player.queue() == original
        assert player.tap("back")["screen"] == 3
        # Lock blocks controls, keeps the paused transport, and paints black.
        player.tap("power")
        assert all(pixel == 0 for pixel in player.pixels)
        player.tap("select", "next", "volume_up")
        assert player.status()["playing_id"] == current_id
        assert player.playback()["paused"] == 1
        player.tap("power")
        assert any(pixel != 0 for pixel in player.pixels)
        player.edge("previous")
        player.frame(450)
        player.edge("previous", False)
        player.frame()
        player.tap("select")  # Resume for the existing queue/mode checks.

        player.tap("select")  # Pause before changing modes.
        position = player.playback()["played_frames"]
        current = player.status()["playing_id"]
        player.tap("menu", "next", "select")
        assert player.playback()["shuffle"] == 1
        assert sorted(player.queue()) == sorted(original)
        assert player.status()["playing_id"] == current
        assert player.playback()["played_frames"] == position
        player.tap("select")  # Disable shuffle, restoring the captured order.
        assert player.queue() == original
        player.tap("next", "select", "select")  # Repeat All -> One
        assert player.playback()["repeat"] == 2
        player.tap("back", "select")  # Close actions, resume.
        total = player.playback()["total_frames"]
        assert total > 0
        rate = player.playback()["sample_rate"]
        player.frame(100 + total * 1000 // rate)
        assert player.playback()["played_frames"] < total
        assert player.status()["playing_id"] == current
        player.tap("next")  # Manual Next still advances with Repeat One.
        if len(original) > 1:
            assert player.status()["playing_id"] != current
        player.tap("menu", "select")  # Queue
        player.tap("next", "select")
        assert player.queue() == original
        player.home()
        player.tap("select", "next", "next", "next", "select")  # Folders
        # Each generated directory is traversed by raw filesystem names. Files
        # use the same player and queue rather than a second playback screen.
        if synthetic:
            for _ in range(3):
                player.tap("select")
            player.tap("menu", "select")
            assert player.status()["playing"]
            assert player.playback()["count"] == 47  # one deleted synthetic file
        player.home()
        player.tap("select", "next", "next", "next", "next", "select")
        assert player.playback()["shuffle"] == 1
        assert len(player.queue()) == initial["tracks"] - (1 if synthetic else 0)
        assert len(set(player.queue())) == len(player.queue())
        return {
            "passed": True,
            "tracks": initial["tracks"],
            "albums": initial["albums"],
            "artists": initial["artists"],
            "synthetic": synthetic,
            "host_only": True,
        }
    finally:
        player.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument(
        "--sd-root", type=Path, help="Optional external root; no files are changed"
    )
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    if args.sd_root:
        result = qualify(app, args.sd_root.resolve(strict=True))
    else:
        old_fonts = os.environ.get("GAIN_FONT_PACK")
        os.environ["GAIN_FONT_PACK"] = str(ROOT / "tests/fonts.bin")
        with tempfile.TemporaryDirectory(prefix="gain-ui-card-") as directory:
            root = Path(directory) / "sd"
            create(root, albums=4, tracks_per_album=48)
            result = qualify(app, root, synthetic=True)
            # Reload/deinit must join a scan even before its first publication.
            interrupted = Player(app, root)
            interrupted.frame()
            interrupted.close()
            sources = [
                ROOT / "tests/fixtures/codecs" / name
                for name in ("flac-16.flac", "aac44.m4a", "stereo-cbr.mp3")
            ]
            before = [hashlib.sha256(path.read_bytes()).digest() for path in sources]
            mounted = Path(directory) / "mounted-sd"
            create(mounted, albums=0, mounts=sources, caches=False)
            checked = qualify(app, mounted)
            assert checked["tracks"] == len(sources), checked
            assert before == [
                hashlib.sha256(path.read_bytes()).digest() for path in sources
            ]
            result["mounted_files"] = checked["tracks"]
        if old_fonts is None:
            os.environ.pop("GAIN_FONT_PACK", None)
        else:
            os.environ["GAIN_FONT_PACK"] = old_fonts
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()

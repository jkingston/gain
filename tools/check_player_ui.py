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


class PreferencesStatus(c.Structure):
    _fields_ = [(name, c.c_uint32) for name in (
        "version", "theme", "appearance", "attenuation", "replay_gain", "timeout", "asleep", "locked", "available", "failed", "theme_revision", "custom_available", "covers_ready", "cover_failures"
    )]


class Player:
    def __init__(self, app, root, persist=False):
        self.module = c.CDLL(str(app))
        self.module.gain_app_api.restype = c.POINTER(Api)
        self.module.gain_player_ui_status.argtypes = [c.POINTER(Status)]
        self.module.gain_player_playback_status.argtypes = [c.POINTER(PlaybackStatus)]
        self.module.gain_player_queue_item.argtypes = [c.c_uint32]
        self.module.gain_player_queue_item.restype = c.c_uint64
        self.module.gain_player_preferences_status.argtypes = [c.POINTER(PreferencesStatus)]
        self.module.gain_player_environment.argtypes = [c.c_uint32] * 4
        self.module.gain_player_environment.restype = c.c_bool
        self.module.gain_player_jacks.argtypes = [c.c_uint32, c.c_uint32]
        self.module.gain_player_jacks.restype = c.c_bool
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
        self.old_read_only = os.environ.get("GAIN_UI_READ_ONLY")
        if persist:
            os.environ.pop("GAIN_UI_READ_ONLY", None)
        else:
            os.environ["GAIN_UI_READ_ONLY"] = "1"
        self.old_root = os.environ.get("GAIN_SD_ROOT")
        os.environ["GAIN_SD_ROOT"] = str(root)
        self.api.init(0)

    def close(self):
        self.api.deinit()
        if self.old_read_only is None:
            os.environ.pop("GAIN_UI_READ_ONLY", None)
        else:
            os.environ["GAIN_UI_READ_ONLY"] = self.old_read_only
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

    def preferences(self):
        value = PreferencesStatus()
        self.module.gain_player_preferences_status(c.byref(value))
        assert value.version == 1 and not value.failed
        return {name: getattr(value, name) for name, _ in PreferencesStatus._fields_}

    def queue(self):
        return [self.module.gain_player_queue_item(i) for i in range(self.playback()["count"])]

    def home(self):
        self.edge("menu")
        self.frame(510)
        self.edge("menu", False)
        return self.frame()

    def choose_home(self, destination):
        # Keep interaction fixtures in one place when the current menu changes.
        # Assertions below exercise behaviour, rather than freezing menu copy.
        positions = {
            "albums": 0, "artists": 1, "songs": 2, "shuffle": 3,
            "playlists": 4, "favourites": 5, "recent": 6,
            "settings": 7, "playing": 8,
        }
        self.home()
        return self.tap(*(["next"] * positions[destination] + ["select"]))

    def menu_action(self, position):
        if self.playback()["menu_open"]:
            self.tap("back")
        return self.tap("menu", *(["next"] * position), "select")

    def queue_screen(self):
        if self.status()["screen"] != 3:
            self.choose_home("playing")
        if not self.playback()["paused"]:
            self.tap("select")
        self.edge("back")
        self.frame(510)
        self.edge("back", False)
        result = self.frame()
        assert result["screen"] == 2
        return result

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
            player.choose_home("artists")
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
            player.choose_home("artists")
            artist = player.tap("select", "select")
            assert artist["rows"] == 48, artist
            player.tap("next", "next", "next")
            chosen = player.status()["selected_id"]
            playing = player.tap("select")
            assert playing["playing"] and playing["playing_id"] == chosen, playing
            player.tap("select")
            # Manual update uses the same scanner and reuses unchanged native tags.
            player.home()
            player.choose_home("settings")
            player.tap("next", "select", "select")
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
            player.choose_home("songs")
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
        player.choose_home("albums")
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
        player.choose_home("shuffle")
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


def qualify_preferences_and_themes(app, root):
    """Writable qualification is restricted to this generated temporary card."""
    player = Player(app, root, persist=True)
    try:
        player.settle_scan()
        assert player.preferences()["available"]
        player.tap("select", "menu", "select", "select")  # Play, then pause.
        queue = player.queue()
        deadline = time.monotonic() + 5
        while player.preferences()["covers_ready"] == 0:
            player.frame()
            if time.monotonic() > deadline:
                raise RuntimeError("Synthetic artwork was not prepared")
            time.sleep(0.004)
        assert player.preferences()["cover_failures"] == 0
        current = player.status()["playing_id"]
        player.home()
        player.choose_home("settings")
        player.tap("next", "next", "select")
        for family in range(1):
            player.tap(*(["previous"] * 7 + ["next"] * family + ["select"]))
            assert player.preferences()["theme"] == family
            assert player.queue() == queue and player.status()["playing_id"] == current
            player.tap(*(["previous"] * 7 + ["next"] * 1 + ["select"]))
            assert player.preferences()["appearance"] == (family + 1) % 2
        player.tap("back", "next", "select")  # Display timeout.
        player.tap("previous", "previous", "previous", "select")
        assert player.preferences()["timeout"] == 0
        player.frame(1100)  # One coalesced save after the last setting change.
        expected = player.preferences()
    finally:
        player.close()
    journal = (root / ".gain/settings.bin").read_bytes()
    reader = Player(app, root)  # Ordinary qualification stays read-only.
    try:
        reader.settle_scan()
        reader.tap("volume_down")
    finally:
        reader.close()
    assert (root / ".gain/settings.bin").read_bytes() == journal
    player = Player(app, root, persist=True)
    try:
        player.settle_scan()
        actual = player.preferences()
        assert all(actual[key] == expected[key] for key in ("theme", "appearance", "attenuation", "replay_gain", "timeout"))
        player.frame(15000)
        assert player.preferences()["asleep"] and not player.preferences()["locked"]
        player.tap("next")
        assert not player.preferences()["asleep"] and player.status()["selection"] == 1
        player.frame(15000)
        player.tap("power")
        assert not player.preferences()["asleep"] and not player.preferences()["locked"]
        player.tap("power")
        assert player.preferences()["locked"] and all(pixel == 0 for pixel in player.pixels)
        player.tap("power")
        assert not player.preferences()["locked"]
        custom = json.loads((ROOT / "src/themes/gain-light.json").read_text())
        custom["name"] = "Custom test"
        path = root / ".gain/theme.json"
        path.write_text(json.dumps(custom))
        player.frame(501)
        assert player.preferences()["custom_available"]
        player.home()
        player.choose_home("settings")
        player.tap("next", "next", "select")
        player.tap(*(["previous"] * 7 + ["next"] * 2 + ["select"]))
        assert player.preferences()["theme"] == 5
        player.home()
        player.choose_home("albums")
        player.tap("next")
        selected = player.status()["selected_id"]
        revision = player.preferences()["theme_revision"]
        custom["palette"]["paper"] = "#101719"
        path.write_text(json.dumps(custom))
        player.frame(501)
        assert player.preferences()["theme_revision"] > revision
        assert player.status()["selected_id"] == selected
        revision = player.preferences()["theme_revision"]
        path.write_text("{}")
        player.frame(501)
        assert player.preferences()["theme_revision"] == revision
        assert player.status()["selected_id"] == selected
        return {"passed": True, "families": 1, "appearance_variants": 2, "persistent_settings": True,
                "timeout_and_lock": True, "runtime_custom_reload": True, "invalid_theme_retains_plan": True}
    finally:
        player.close()


def qualify_listening(app, root):
    """Actual app integration with a writable generated card, never a real root."""
    player = Player(app, root, persist=True)
    try:
        player.settle_scan()
        player.choose_home("albums")
        player.tap("select", "next", "next", "select", "select")
        initial = player.queue()
        assert len(initial) >= 6 and player.playback()["cursor"] == 2
        assert player.playback()["paused"]
        current = player.status()["playing_id"]

        # A duplicate of the album's first song is inserted next and appended.
        # Their identities must stay separate from the original occurrence.
        player.choose_home("albums")
        player.tap("select")
        first = player.status()["selected_id"]
        player.menu_action(2)  # Play Next on the selected album track.
        expected = initial[:3] + [first] + initial[3:]
        assert player.queue() == expected
        player.menu_action(3)  # Add to Queue.
        expected.append(first)
        assert player.queue() == expected
        assert player.status()["playing_id"] == current
        player.queue_screen()
        player.tap("next", "select", "select")
        assert player.playback()["cursor"] == 3
        assert player.status()["playing_id"] == first
        assert player.queue() == expected

        # Move/remove operate on an upcoming occurrence, without replacing or
        # restarting the active duplicate. The selected row follows its token.
        player.queue_screen()
        player.tap("next", "next")
        moved = expected.pop(5)
        expected.insert(4, moved)
        player.menu_action(0)
        assert player.queue() == expected
        assert player.status()["selection"] == 4
        player.menu_action(1)
        expected.pop(4)
        assert player.queue() == expected
        assert player.playback()["cursor"] == 3
        assert player.status()["playing_id"] == first
        player.tap(*(["next"] * len(expected)))
        player.menu_action(1)
        expected.pop()
        assert player.queue() == expected
        assert expected.count(first) == 2

        # A manual skip must start after occurrence 3, not after the first copy
        # of that song at occurrence 0. Then restore that duplicate for reboot.
        player.choose_home("playing")
        player.tap("next", "select")
        assert player.playback()["cursor"] == 4
        assert player.status()["playing_id"] == expected[4]
        player.queue_screen()
        player.tap("previous", "select", "select")
        assert player.playback()["cursor"] == 3
        assert player.status()["playing_id"] == first

        player.choose_home("playing")
        player.menu_action(1)  # Shuffle, keeping the audible occurrence.
        assert player.playback()["shuffle"] == 1
        player.tap("next", "select", "back")  # Repeat All, close actions.
        assert player.playback()["repeat"] == 1
        player.tap("select")
        player.frame(100)
        player.tap("select")
        checkpoint = player.playback()
        assert 0 < checkpoint["played_frames"] < checkpoint["total_frames"]
        queue = player.queue()
        assert player.status()["playing_id"] == first

        # Automatic USB ownership checkpoints and pauses. Returning from USB
        # must preserve the listening session, including a duplicated song.
        environment = player.module.gain_player_environment
        assert environment(4140, 0, 2, 1)
        player.frame(100)
        player.tap("next", "select")
        assert player.queue() == queue and player.playback()["cursor"] == 3
        assert environment(4140, 0, 0, 1)
        player.frame()
        assert player.playback()["paused"]
        assert player.playback()["played_frames"] == checkpoint["played_frames"]
    finally:
        player.close()

    player = Player(app, root, persist=True)
    try:
        player.settle_scan()
        restored = player.playback()
        assert player.queue() == queue
        assert (restored["cursor"], restored["shuffle"], restored["repeat"]) == (3, 1, 1)
        assert restored["paused"]
        assert restored["played_frames"] == checkpoint["played_frames"]
        assert player.status()["playing_id"] == first
        player.choose_home("playing")
        player.tap("select")
        assert not player.playback()["paused"]
        assert player.playback()["played_frames"] > restored["played_frames"]
        player.tap("select")
    finally:
        player.close()

    # Change the file stamps without changing metadata or stable track IDs. A
    # saved position belongs to the prior encoding and must reset safely.
    for path in root.rglob("*.flac"):
        stamp = path.stat()
        os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns + 10_000_000_000))
    player = Player(app, root)
    try:
        player.settle_scan()
        assert player.queue() == queue
        assert player.playback()["cursor"] == 3 and player.playback()["paused"]
        assert player.playback()["played_frames"] == 0
    finally:
        player.close()

    for path in root.rglob("*.flac"):
        path.unlink()
    player = Player(app, root)
    try:
        player.settle_scan()
        assert player.queue() == queue and not player.status()["playing"]
        for _ in range(60):
            player.frame()
        assert player.queue() == queue and not player.status()["playing"]
    finally:
        player.close()
    return {"passed": True, "duplicate_occurrences": True, "atomic_queue_edits": True,
            "paused_resume": True, "usb_checkpoint": True, "changed_file_resets_position": True,
            "missing_tracks_retained": True, "host_only": True}


def qualify_power(app, root):
    """Advance a deterministic app clock; no battery-hour claims are inferred."""
    player = Player(app, root, persist=True)
    try:
        player.settle_scan()
        player.choose_home("albums")
        player.tap("menu", "select")
        current = player.status()["playing_id"]
        jack = player.module.gain_player_jacks
        assert jack(1, 0)
        player.frame(1)
        player.frame(40)
        assert not player.playback()["paused"]
        assert jack(0, 0)
        player.frame(10)
        assert jack(1, 0)
        player.frame(10)
        assert not player.playback()["paused"]
        assert jack(0, 0)
        player.frame(1)
        player.frame(39)
        assert not player.playback()["paused"]
        player.frame(1)
        assert player.playback()["paused"]
        assert player.status()["playing_id"] == current
        assert jack(1, 0)
        player.frame(1)
        player.frame(40)
        assert player.playback()["paused"]  # No insertion-triggered playback.
        assert not jack(2, 0)
        assert jack(1, 1)
        player.frame(1)
        player.frame(40)
        player.tap("select")
        assert jack(0, 1)
        player.frame(1)
        player.frame(40)
        assert not player.playback()["paused"]  # Line-out remains active.
        player.tap("select")
        queue = player.queue()

        # Keep the display awake so black pixels prove actual shutdown rather
        # than the separate, deliberately independent display timeout.
        player.choose_home("settings")
        player.tap("next", "next", "next", "select", "next", "next", "select", "back")
        assert player.preferences()["timeout"] == 3
        player.tap("next", "next", "select", "select", "select")  # Auto-off: Off.
        player.tap("previous", "select")  # Sleep: 15 minutes.
        player.frame(15 * 60 * 1000 - 1)
        assert any(pixel != 0 for pixel in player.pixels)
        player.frame(1)
        assert all(pixel == 0 for pixel in player.pixels)
        attenuation = player.preferences()["attenuation"]
        player.tap("next", "volume_up", "select")
        assert player.preferences()["attenuation"] == attenuation
        assert all(pixel == 0 for pixel in player.pixels)
        player.tap("power")
        player.settle_scan()
        assert player.queue() == queue and player.playback()["paused"]
        player.frame(16 * 60 * 1000)
        assert any(pixel != 0 for pixel in player.pixels)  # Sleep was not restored.

        # USB cancels a sleep deadline and never powers the host volume off.
        player.choose_home("settings")
        player.tap(*(["next"] * 4), "select")
        environment = player.module.gain_player_environment
        assert environment(4140, 0, 2, 1)
        player.frame(16 * 60 * 1000)
        assert any(pixel != 0 for pixel in player.pixels)
        assert environment(4140, 0, 0, 1)
        player.frame(16 * 60 * 1000)
        assert any(pixel != 0 for pixel in player.pixels)
        assert player.queue() == queue and player.playback()["paused"]

        # Paused-idle shutdown restarts its clock after user activity and uses
        # the same checkpoint/restart path, independently of the sleep timer.
        player.choose_home("settings")
        player.tap(*(["next"] * 5), "select")  # Off -> five minutes.
        player.frame(5 * 60 * 1000 - 1)
        assert any(pixel != 0 for pixel in player.pixels)
        player.frame(1)
        assert all(pixel == 0 for pixel in player.pixels)
        player.tap("power")
        player.settle_scan()
        assert player.queue() == queue and player.playback()["paused"]
    finally:
        player.close()
    return {"passed": True, "headphone_debounce": True, "no_auto_resume": True,
            "line_out_unaffected": True, "sleep_shutdown": True, "sleep_not_persistent": True,
            "usb_cancels_sleep": True, "paused_idle_shutdown": True, "host_only": True}


def qualify_discovery(app, root):
    """Playlist occurrences and discovery state through real scanner/UI paths."""
    paths = sorted((root / "Music").rglob("*.flac"))
    entries = ["../" + path.relative_to(root).as_posix() for path in paths[:3]]
    playlist = root / "Playlists" / "Occurrence Mix.m3u8"
    playlist.write_text("\ufeff#EXTM3U\r\n" + "\r\n".join((entries[0], entries[1], entries[0], "../missing.flac", entries[2], "https://example.invalid/music")) + "\r\n", encoding="utf-8")
    player = Player(app, root, persist=True)
    try:
        player.settle_scan()
        player.choose_home("recent")
        assert player.status()["rows"] == 0  # Quiet initial-library baseline.
        player.choose_home("playlists")
        imported = player.status()["rows"]
        assert imported == 2
        player.tap("select")
        assert player.status()["rows"] == 5  # Missing stays visible; URL omitted.
        first = player.status()["selected_id"]
        second = player.tap("next")["selected_id"]
        assert player.tap("next")["selected_id"] == first
        player.tap("next", "select")  # Selecting the unavailable row is harmless.
        assert not player.status()["playing"] and player.playback()["count"] == 0
        third = player.tap("next")["selected_id"]
        player.tap("previous", "previous", "select", "select")
        queue = [first, second, first, third]
        assert player.queue() == queue and player.playback()["cursor"] == 2
        assert player.playback()["paused"]

        player.menu_action(5)  # Favourite the playing duplicate's song identity.
        player.choose_home("favourites")
        player.tap("next", "select")
        assert player.status()["rows"] == 1 and player.status()["selected_id"] == first
        player.menu_action(4)  # Removing a selected favourite empties this view.
        assert player.status()["rows"] == 0 and player.queue() == queue
        player.choose_home("playing")
        player.menu_action(5)
        player.choose_home("albums")
        player.menu_action(4)  # Typed album favourite is independent of songs.
        player.choose_home("favourites")
        player.tap("select")
        assert player.status()["rows"] == 1
        favourite_album = player.status()["selected_id"]
        assert favourite_album != 0
        assert player.queue() == queue and player.playback()["cursor"] == 2

        player.choose_home("playing")
        player.menu_action(6)  # Save the realized queue without inventing files.
        assert player.status()["screen"] == 14
        player.tap("select")
        player.choose_home("playlists")
        assert player.status()["rows"] == imported + 1
        player.tap(*(["next"] * imported), "select")
        player.tap("select")  # Loading is completed by the app's storage owner.
        assert player.queue() == queue and player.playback()["cursor"] == 0
        assert player.playback()["paused"]
    finally:
        player.close()

    player = Player(app, root, persist=True)
    try:
        player.settle_scan()
        player.choose_home("favourites")
        player.tap("next", "select")
        assert player.status()["rows"] == 1 and player.status()["selected_id"] == first
        player.choose_home("favourites")
        player.tap("select")
        assert player.status()["rows"] == 1 and player.status()["selected_id"] == favourite_album
        player.choose_home("playlists")
        assert player.status()["rows"] == imported + 1
        player.tap(*(["next"] * imported), "select")
        player.tap("select")  # Loading is completed by the app's storage owner.
        assert player.queue() == queue

        def update():
            player.choose_home("settings")
            player.tap("next", "select", "select")
            player.settle_scan()
            player.choose_home("recent")
            return player.status()

        def add_album(name):
            directory = root / "Music" / "Test Newcomer" / name
            directory.mkdir(parents=True)
            path = directory / "01 - Added Track.flac"
            path.write_bytes(tagged_flac(paths[0].read_bytes(), {
                "TITLE": "Added Track", "ARTIST": "Test Newcomer",
                "ALBUMARTIST": "Test Newcomer", "ALBUM": name,
                "TRACKNUMBER": 1, "DISCNUMBER": 1,
            }))
            return directory

        added = add_album("Added Album")
        assert update()["rows"] == 1
        older = player.status()["selected_id"]
        assert older != 0
        add_album("Another Added Album")
        assert update()["rows"] == 2
        newest = player.status()["selected_id"]
        assert newest != older
        assert player.tap("next")["selected_id"] == older
        added.rename(added.with_name("Moved Album"))
        # Retag a complete baseline album. Its discovery age and favourites
        # follow stable track anchors rather than treating a rename as new music.
        baseline = paths[0].parent
        for number, path in enumerate(sorted(baseline.glob("*.flac")), 1):
            path.write_bytes(tagged_flac(path.read_bytes(), {
                "TITLE": f"Retagged Track {number}", "ARTIST": baseline.parent.name,
                "ALBUMARTIST": baseline.parent.name, "ALBUM": "Retagged Baseline",
                "TRACKNUMBER": number, "DISCNUMBER": 1,
            }))
        assert update()["rows"] == 2
        assert player.status()["selected_id"] == newest
        assert player.queue() == queue
        player.choose_home("favourites")
        player.tap("next", "select")
        assert player.status()["rows"] == 1 and player.status()["selected_id"] == first
        player.choose_home("favourites")
        player.tap("select")
        assert player.status()["rows"] == 1
    finally:
        player.close()
    return {"passed": True, "imported_playlist_occurrences": True, "missing_playlist_rows": True,
            "saved_queue_roundtrip": True, "typed_favourites_persist": True,
            "recent_discovery_order": True, "retags_and_moves_preserve_age": True,
            "queue_unchanged_by_discovery": True, "host_only": True}


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
            result["preferences_and_themes"] = qualify_preferences_and_themes(app, root)
            listening_root = Path(directory) / "listening-sd"
            create(listening_root, albums=3, tracks_per_album=8)
            result["listening"] = qualify_listening(app, listening_root)
            power_root = Path(directory) / "power-sd"
            create(power_root, albums=3, tracks_per_album=8)
            result["power"] = qualify_power(app, power_root)
            discovery_root = Path(directory) / "discovery-sd"
            create(discovery_root, albums=3, tracks_per_album=8)
            result["discovery"] = qualify_discovery(app, discovery_root)
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

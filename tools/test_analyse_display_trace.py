"""Deterministic trace interpretations, including pauses and counter wrap."""

import unittest
from analyse_display_trace import BUDGETS, analyse, cover_readiness, qualify


def event(kind, at, value):
    return dict(kind=kind, at=at & 0xFFFFFFFF, value=value)


class TimingTests(unittest.TestCase):
    def test_cover_readiness_distinguishes_loading_from_known_missing_and_idle(self):
        trace = [
            event(5, 0, 1 << 31),
            event(8, 1, 7 | (1 << 7) | (1 << 21)),
            event(8, 2, 7 | (7 << 7) | (1 << 21) | (1 << 22)),
            event(8, 3, 7 | (3 << 7) | (4 << 14) | (1 << 21)),
            event(5, 4, 0),
            event(8, 5, 7 | (1 << 21)),
        ]
        result = cover_readiness(trace)
        self.assertEqual(2, result["center_samples"])
        self.assertEqual(1, result["center_ready"])
        self.assertEqual(0.5, result["center_ready_fraction"])
        self.assertEqual(8, result["visible_samples"])
        self.assertEqual(6, result["visible_ready"])

    def test_older_traces_do_not_invent_cover_readiness(self):
        result = cover_readiness([event(5, 0, 1 << 31), event(2, 1, 76800)])
        self.assertEqual(0, result["center_samples"])
        self.assertIsNone(result["center_ready_fraction"])
        self.assertIsNone(result["visible_ready_fraction"])

    def test_release_gate_requires_all_profiles_and_real_motion_samples(self):
        self.assertFalse(qualify({})["passed"])
        profiles = {
            name: dict(active_intervals_ms=[], active_interval_ms={})
            for name in BUDGETS
        }
        self.assertFalse(qualify(profiles)["passed"])

    def test_release_gate_preserves_single_stall_failures(self):
        profiles = {}
        for name in BUDGETS:
            entries = []
            for n in range(32):
                entries.extend(
                    [event(5, n * 90000, 3 << 30), event(2, n * 90000, 76800)]
                )
            profiles[name] = analyse(entries, 1 if name.startswith("flow") else 2)
        self.assertTrue(qualify(profiles)["passed"])
        profiles["flow-playing"]["active_interval_ms"]["max"] = 50
        self.assertFalse(qualify(profiles)["passed"])

    def test_ongoing_animation_keeps_long_stalls_visible(self):
        trace = []
        for at in [0, 102000, 402000]:
            trace.extend([event(5, at - 100, 1 << 31), event(2, at, 76800)])
        result = analyse(trace, 1)
        self.assertEqual([17, 50], result["active_intervals_ms"])
        self.assertEqual(50, result["active_interval_ms"]["max"])

    def test_explicit_idle_excludes_pause_without_a_magic_gap_threshold(self):
        trace = [
            event(5, 0, 1 << 31),
            event(2, 0, 76800),
            event(6, 6000, 0),
            event(6, 3000000, 1),
            event(5, 3000000, 1 << 31),
            event(2, 3000000, 76800),
        ]
        result = analyse(trace, 1)
        self.assertEqual([], result["active_intervals_ms"])
        self.assertEqual([500], result["idle_or_unclassified_intervals_ms"])

    def test_volume_flag_and_timer_wrap(self):
        origin = 0xFFFFFFF0
        trace = [
            event(5, origin - 1, 1 << 30),
            event(2, origin, 13440),
            event(5, origin + 87479, 1 << 30),
            event(2, origin + 87480, 13440),
        ]
        self.assertEqual([14.58], analyse(trace, 2)["active_intervals_ms"])
        self.assertEqual([], analyse(trace, 1)["active_intervals_ms"])

    def test_pending_render_does_not_relabel_previous_dma(self):
        trace = [
            event(5, 0, 1 << 31),
            event(5, 20, 0),
            event(2, 30, 76800),
            event(2, 60, 76800),
        ]
        result = analyse(trace, 1)
        self.assertEqual([], result["active_intervals_ms"])
        self.assertEqual([0.005], result["idle_or_unclassified_intervals_ms"])


if __name__ == "__main__":
    unittest.main()

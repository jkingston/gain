"""Separate ongoing animation timing from deliberate idle gaps in RAM traces."""

from __future__ import annotations

import argparse
from collections import deque
import json
from pathlib import Path


def percentile(values, quantile):
    return sorted(values)[int((len(values) - 1) * quantile)] if values else None


def cover_readiness(entries):
    """Read inspected moving scenes; exclude completed negative cache entries.

    These are render samples, not atomic panel captures or elapsed-time shares.
    Older traces without kind8 yield no samples rather than zero readiness.
    """
    moving = False
    center_samples = center_ready = visible_samples = visible_ready = 0
    for entry in entries:
        if entry["kind"] == 5:
            moving = bool(entry["value"] & (1 << 31))
        elif entry["kind"] == 8 and moving:
            value = entry["value"]
            present = value & 127
            ready = (value >> 7) & 127
            missing = (value >> 14) & 127
            visible_samples += (present & ~missing).bit_count()
            visible_ready += (present & ready & ~missing).bit_count()
            # The centre is the final model in paint order, including edges.
            if present and value & (1 << 21):
                center = 1 << (present.bit_length() - 1)
                if not missing & center:
                    center_samples += 1
                    center_ready += bool(value & (1 << 22))
    return dict(
        center_samples=center_samples,
        center_ready=center_ready,
        center_ready_fraction=center_ready / center_samples if center_samples else None,
        visible_samples=visible_samples,
        visible_ready=visible_ready,
        visible_ready_fraction=visible_ready / visible_samples if visible_samples else None,
    )


def analyse(entries, motion_mask):
    pending = deque()
    previous_at = None
    previous_animated = False
    idle_seen = False
    intervals = []
    idle_intervals = []
    models = []
    for entry in entries:
        if entry["kind"] == 5:
            value = entry["value"]
            flags = (value >> 31) | ((value >> 29) & 2)
            pending.append(bool(flags & motion_mask))
            models.append(dict(selection=(value >> 11) & 0xFFFF, count=value & 2047))
        elif entry["kind"] == 6 and not entry["value"] & motion_mask:
            idle_seen = True
        elif entry["kind"] == 2:
            animated = pending.popleft() if pending else False
            if previous_at is not None:
                gap = ((entry["at"] - previous_at) & 0xFFFFFFFF) / 6000
                if animated and previous_animated and not idle_seen:
                    intervals.append(gap)
                else:
                    idle_intervals.append(gap)
            previous_at = entry["at"]
            previous_animated = animated
            idle_seen = False
    return dict(
        active_intervals_ms=intervals,
        active_interval_ms=dict(
            p50=percentile(intervals, 0.5),
            p95=percentile(intervals, 0.95),
            max=max(intervals, default=None),
        ),
        idle_or_unclassified_intervals_ms=idle_intervals,
        models=models,
        covers=cover_readiness(entries),
    )


# Submission pacing goals for continuous animation on the qualified F20.
# Artwork reads may add bounded idle-browser latency; audio has priority.
BUDGETS = {
    "flow-idle": (19, 25, 30),
    "flow-playing": (18.5, 20, 25),
    "flow-scanning": (18.5, 20, 25),
    "volume-playing": (16, 16.5, 20),
    "volume-scanning": (16, 16.5, 20),
}


def qualify(profiles):
    failures = []
    for name, limits in BUDGETS.items():
        profile = profiles.get(name)
        if profile is None or len(profile["active_intervals_ms"]) < 30:
            failures.append(f"{name}: insufficient active animation samples")
            continue
        observed = profile["active_interval_ms"]
        for metric, limit in zip(("p50", "p95", "max"), limits):
            if observed[metric] is None or observed[metric] > limit:
                failures.append(f"{name}: {metric} exceeds {limit}ms")
    return dict(passed=not failures, failures=failures, budgets_ms=BUDGETS)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    result = {}
    for path in sorted(args.directory.glob("flow-*.json")) + sorted(
        args.directory.glob("volume-*.json")
    ):
        profile = json.loads(path.read_text())
        result[path.stem] = analyse(
            profile["trace"], 1 if path.stem.startswith("flow-") else 2
        )
    (args.directory / "active-animation-timing.json").write_text(
        json.dumps(result, indent=2) + "\n"
    )
    print(
        json.dumps({key: value["active_interval_ms"] for key, value in result.items()})
    )


if __name__ == "__main__":
    main()

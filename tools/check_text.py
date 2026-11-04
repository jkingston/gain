#!/usr/bin/env python3
"""Exercise the actual player text engine with a supplied SD font pack.

Writes portable PGM masks and timings to an explicit output directory. The
pack may be the small generic fixture or the complete installed language pack.
"""

import argparse
import ctypes as c
import json
import pathlib
import statistics
import time
import unicodedata

ROOT = pathlib.Path(__file__).resolve().parents[1]


class Request(c.Structure):
    _fields_ = [
        ("length", c.c_uint16),
        ("width", c.c_uint16),
        ("role", c.c_uint8),
        ("locale", c.c_uint8),
        ("ellipsis", c.c_uint8),
        ("reserved", c.c_uint8),
        ("text", c.c_uint8 * 4096),
    ]


class Label(c.Structure):
    _fields_ = [
        ("width", c.c_uint16),
        ("height", c.c_uint16),
        ("missing", c.c_uint16),
        ("truncated", c.c_uint8),
        ("rtl", c.c_uint8),
        ("pixels", c.c_uint8 * (320 * 48)),
    ]


Read = c.CFUNCTYPE(c.c_uint32, c.c_void_p, c.c_uint32, c.POINTER(c.c_uint8), c.c_uint32)
Poll = c.CFUNCTYPE(c.c_bool, c.c_void_p)


class Source(c.Structure):
    _fields_ = [
        ("context", c.c_void_p),
        ("bytes", c.c_uint32),
        ("read", Read),
        ("poll", Poll),
    ]


class Statistics(c.Structure):
    _fields_ = [
        (name, c.c_uint32)
        for name in (
            "heap_live",
            "heap_peak",
            "heap_failures",
            "page_reads",
            "page_hits",
            "labels",
            "glyphs",
            "allocation_failure_bytes",
        )
    ]


class Workspace(c.Structure):
    _fields_ = [
        ("primary", c.c_void_p),
        ("primary_bytes", c.c_uint32),
        ("auxiliary", c.c_void_p),
        ("auxiliary_bytes", c.c_uint32),
    ]


class Api(c.Structure):
    _fields_ = [
        ("version", c.c_uint32),
        (
            "initialize",
            c.CFUNCTYPE(c.c_uint32, c.POINTER(Source), c.POINTER(Workspace)),
        ),
        ("prepare", c.CFUNCTYPE(c.c_uint32, c.POINTER(Request), c.POINTER(Label))),
        ("shutdown", c.CFUNCTYPE(None)),
        ("statistics", c.CFUNCTYPE(None, c.POINTER(Statistics))),
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, required=True)
    parser.add_argument("--pack", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument(
        "--all-families",
        action="store_true",
        help="Sweep primary-coverage fonts and all regional Han choices",
    )
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    library = c.CDLL(str(args.app.resolve()))
    library.gain_text_api.restype = c.POINTER(Api)
    api = library.gain_text_api().contents
    assert api.version == 2
    metrics = {"read_bytes": 0, "reads": 0, "polls": 0}
    pack = args.pack.open("rb")

    @Read
    def read(_, at, output, count):
        pack.seek(at)
        data = pack.read(count)
        c.memmove(output, data, len(data))
        metrics["reads"] += 1
        metrics["read_bytes"] += len(data)
        return len(data)

    @Poll
    def poll(_):
        metrics["polls"] += 1
        return False

    source = Source(None, args.pack.stat().st_size, read, poll)
    allocation = c.create_string_buffer(960 * 1024 + 16)
    heap = (c.addressof(allocation) + 15) & ~15
    auxiliary = c.create_string_buffer(232 * 1024 + 16)
    auxiliary_heap = (c.addressof(auxiliary) + 15) & ~15
    workspace = Workspace(heap, 960 * 1024, auxiliary_heap, 232 * 1024)
    source.context = heap
    result = api.initialize(c.byref(source), c.byref(workspace))
    assert result == 0, ("initialize", result)
    samples = json.loads((ROOT / "tests/text_samples.json").read_text())
    if args.all_families:
        samples += [
            {
                "language": f"regional Han {locale}",
                "text": "中国音乐 • 樂團",
                "locale": locale,
            }
            for locale in range(1, 5)
        ]
        metadata = json.loads(args.pack.with_suffix(".json").read_text())
        owners = {}
        for first, last, family in metadata["ranges"]:
            if family in owners:
                continue
            for cp in range(first, min(last + 1, first + 256)):
                if unicodedata.category(chr(cp))[0] in "LNSP":
                    owners[family] = chr(cp)
                    break
        samples += [
            {
                "language": "coverage: " + metadata["families"][family]["name"],
                "text": value,
            }
            for family, value in owners.items()
        ]
    rows = []
    try:
        for i, sample in enumerate(samples):
            encoded = sample["text"].encode("utf-8")
            for role in range(5):
                request = Request(
                    len(encoded), 288, role, sample.get("locale", 0), 1, 0
                )
                request.text[: len(encoded)] = encoded
                label = Label()
                before = time.perf_counter_ns()
                result = api.prepare(c.byref(request), c.byref(label))
                elapsed = time.perf_counter_ns() - before
                if result != 0 or label.missing != 0:
                    failed_stats = Statistics()
                    api.statistics(c.byref(failed_stats))
                    print(
                        "text failure",
                        sample["language"],
                        role,
                        {
                            name: getattr(failed_stats, name)
                            for name, _ in Statistics._fields_
                        },
                    )
                assert result == 0 and label.missing == 0, (
                    sample["language"],
                    role,
                    result,
                    label.missing,
                )
                assert label.width <= 288 and label.height <= 48
                rows.append(
                    {
                        "language": sample["language"],
                        "role": role,
                        "us": elapsed / 1000,
                        "width": label.width,
                        "height": label.height,
                    }
                )
                if role == 4:
                    pixels = b"".join(
                        bytes(label.pixels[y * 320 : y * 320 + label.width])
                        for y in range(label.height)
                    )
                    (args.output / f"{i:02d}.pgm").write_bytes(
                        f"P5\n{label.width} {label.height}\n255\n".encode() + pixels
                    )
    finally:
        api.shutdown()
        pack.close()
    allocation_stats = Statistics()
    api.statistics(c.byref(allocation_stats))
    assert allocation_stats.heap_failures == 0
    report = {
        "allocation": {
            name: getattr(allocation_stats, name) for name, _ in Statistics._fields_
        },
        "samples": rows,
        "metrics": metrics,
        "median_us": statistics.median(row["us"] for row in rows),
        "max_us": max(row["us"] for row in rows),
    }
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(
        f"{len(rows)} shaped labels pass; median {report['median_us']:.0f} µs, max {report['max_us']:.0f} µs (host only)"
    )


if __name__ == "__main__":
    main()

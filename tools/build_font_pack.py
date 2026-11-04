#!/usr/bin/env python3
"""Build an immutable SD font pack from pinned, unmodified upstream sources.

Requires fonttools==4.61.1. The cache/output are explicit caller-owned paths;
no machine-specific library or system fonts are consulted. Static instances
remove variable-font work from device startup. --test-subset creates small,
generic shaping fixtures; it must never be used as the installed language pack.
"""

import argparse
import concurrent.futures
import hashlib
import io
import json
import pathlib
import struct
import urllib.parse
import urllib.request

from fontTools import __version__ as fonttools_version
from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "assets/fonts/languages.json"
SAMPLES = ROOT / "tests/text_samples.json"
HEADER_BYTES = 64
FACE_BYTES = 24
RANGE_BYTES = 12


def digest(data):
    return hashlib.sha256(data).hexdigest()


def fetch(record, cache, download):
    path = cache / pathlib.PurePosixPath(record["path"]).name
    if not record["url"]:
        data = (ROOT / "assets/fonts" / record["path"]).read_bytes()
        if digest(data) != record["sha256"]:
            raise ValueError("Bundled source checksum mismatch")
        return data
    if path.exists() and digest(path.read_bytes()) != record["sha256"]:
        if download:
            path.unlink()
    if not path.exists():
        if not download:
            raise ValueError(f"Missing {path}; use --download to fetch pinned sources")
        data = urllib.request.urlopen(record["url"], timeout=120).read()
        if digest(data) != record["sha256"]:
            raise ValueError(f"Source checksum mismatch: {record['path']}")
        path.write_bytes(data)
    data = path.read_bytes()
    if digest(data) != record["sha256"]:
        raise ValueError(f"Source checksum mismatch: {path}")
    return data


def prepare(job):
    record, cache, download, points = job
    source = fetch(record, cache, download)
    faces = []
    coverage = None
    # The existing Latin styles keep their three weights; fallback families use
    # one optical instance, shared by all roles and rasterised at each size.
    for weight in (
        [450, 500, 650] if record["family"] in ("Inter", "Newsreader") else [500]
    ):
        key = digest(source + b"gain-static-font-v3" + str((weight, points)).encode())
        destination = cache / "instances" / f"{key}.ttf"
        if destination.exists():
            data = destination.read_bytes()
            font = TTFont(io.BytesIO(data), recalcTimestamp=False)
        else:
            font = TTFont(io.BytesIO(source), recalcTimestamp=False)
            if "fvar" in font:
                axes = {
                    axis.axisTag: max(
                        axis.minValue,
                        min(
                            axis.maxValue,
                            weight
                            if axis.axisTag == "wght"
                            else (
                                27
                                if record["family"] == "Newsreader"
                                else 19
                                if weight == 650
                                else 16
                                if weight == 500
                                else 14
                            )
                            if axis.axisTag == "opsz"
                            else axis.defaultValue,
                        ),
                    )
                    for axis in font["fvar"].axes
                }
                font = instantiateVariableFont(font, axes, inplace=True)
            if points is not None:
                options = subset.Options()
                options.layout_features = ["*"]
                options.notdef_glyph = True
                options.notdef_outline = True
                options.recalc_timestamp = False
                sub = subset.Subsetter(options=options)
                sub.populate(unicodes=points)
                sub.subset(font)
            # Instances/subsets are derivatives: use new internal family names
            # while retaining the upstream copyright and license name records.
            family = "Gain Font " + key[:12]
            for name in list(font["name"].names):
                if name.nameID in (1, 2, 3, 4, 6, 16, 17):
                    text = (
                        "Regular"
                        if name.nameID in (2, 17)
                        else family.replace(" ", "")
                        if name.nameID == 6
                        else family
                    )
                    font["name"].setName(
                        text, name.nameID, name.platformID, name.platEncID, name.langID
                    )
            stream = io.BytesIO()
            font.save(stream, reorderTables=True)
            data = stream.getvalue()
            destination.write_bytes(data)
        if coverage is None:
            coverage = set(font.getBestCmap())
        faces.append(data)
        font.close()
    if len(faces) == 1:
        faces *= 3
    return record["family"], faces, coverage


def ranges(mapping):
    output = []
    for cp, family in sorted(mapping.items()):
        if output and output[-1][1] + 1 == cp and output[-1][2] == family:
            output[-1] = (output[-1][0], cp, family)
        else:
            output.append((cp, cp, family))
    return output


def build(records, destination, cache, download=False, test_subset=False, jobs=2):
    if fonttools_version != "4.61.1":
        raise ValueError(f"Expected fonttools 4.61.1, got {fonttools_version}")
    cache.mkdir(parents=True, exist_ok=True)
    (cache / "instances").mkdir(exist_ok=True)
    samples = json.loads(SAMPLES.read_text())
    points = (
        sorted(
            {ord(c) for sample in samples for c in sample["text"]}
            | set(range(32, 127))
            | {0x2026, 0xFFFD}
        )
        if test_subset
        else None
    )
    with concurrent.futures.ProcessPoolExecutor(max_workers=jobs) as executor:
        prepared = list(
            executor.map(
                prepare, [(record, cache, download, points) for record in records]
            )
        )
    if len(prepared) > 256:
        raise ValueError("Too many font families")
    mapping = {}
    for index, (_, _, covered) in enumerate(prepared):
        if index == 1:  # Newsreader is a style, never a coverage fallback.
            continue
        for cp in covered:
            mapping.setdefault(cp, index)
    covered_ranges = ranges(mapping)
    if len(covered_ranges) > 16384:
        raise ValueError("Font coverage index exceeds the device reservation")
    face_offset = HEADER_BYTES
    range_offset = face_offset + len(prepared) * FACE_BYTES
    font_offset = (range_offset + len(covered_ranges) * RANGE_BYTES + 4095) & ~4095
    directory = bytearray()
    blobs = bytearray()
    interned = {}
    for _, faces, _ in prepared:
        for data in faces:
            sha = digest(data)
            if sha not in interned:
                interned[sha] = (font_offset + len(blobs), len(data))
                blobs.extend(data)
                blobs.extend(bytes((-len(blobs)) % 4))
            directory.extend(struct.pack("<II", *interned[sha]))
    names = [name for name, _, _ in prepared]
    cjk = [
        names.index(name) if name in names else 0xFFFF
        for name in ("NotoSansJP", "NotoSansSC", "NotoSansTC", "NotoSansKR")
    ]
    header = struct.pack(
        "<8s7I4H20x",
        b"GAINFT01",
        1,
        len(prepared),
        len(covered_ranges),
        face_offset,
        range_offset,
        font_offset,
        font_offset + len(blobs),
        *cjk,
    )
    output = bytearray(header + directory)
    for first, last, family in covered_ranges:
        output.extend(struct.pack("<IIH2x", first, last, family))
    output.extend(bytes(font_offset - len(output)))
    output.extend(blobs)
    if len(output) > 128 * 1024 * 1024:
        raise ValueError("Font pack exceeds the device seek-index capacity")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".tmp")
    temporary.write_bytes(output)
    temporary.replace(destination)
    report = {
        "version": 1,
        "test_subset": test_subset,
        "sha256": digest(output),
        "bytes": len(output),
        "codepoints": len(mapping),
        "families": [
            {"name": name, "codepoints": len(covered)} for name, _, covered in prepared
        ],
        "ranges": covered_ranges,
    }
    destination.with_suffix(".json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    )
    notices = []
    for record in records:
        license_path = ROOT / "assets/fonts" / record["license_file"]
        data = license_path.read_bytes()
        if "license_sha256" in record and digest(data) != record["license_sha256"]:
            raise ValueError(f"License checksum mismatch: {license_path}")
        notices.append(record["family"] + "\n" + data.decode("utf-8"))
    for name, path in (
        ("FreeType", "vendor/freetype/docs/FTL.TXT"),
        ("HarfBuzz", "vendor/harfbuzz/COPYING"),
        ("SheenBidi", "vendor/sheen/LICENSE"),
        ("utf8proc / Unicode data", "vendor/utf8proc/LICENSE.md"),
        ("musl setjmp", "assets/fonts/licenses/musl.txt"),
    ):
        notices.append(name + "\n" + (ROOT / path).read_text())
    destination.with_name("LICENSES.txt").write_text("\n\n".join(notices))
    print(
        f"{destination}: {len(prepared)} families, {len(mapping)} codepoints, {len(output):,} bytes",
        flush=True,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--test-subset", action="store_true")
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    if not 1 <= args.jobs <= 16:
        parser.error("--jobs must be between 1 and 16")
    records = json.loads(MANIFEST.read_text())["fonts"]
    build(records, args.output, args.cache, args.download, args.test_subset, args.jobs)


if __name__ == "__main__":
    main()

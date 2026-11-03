"""Create a complete synthetic SD directory, optionally mounting real files.

Generated cards live outside the repository. Encoded audio comes from Gain's
synthetic decoder fixtures; no personal collection is searched or copied.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import struct

from gain_metrics import provision

ROOT = Path(__file__).resolve().parents[1]
ARTISTS = ("Test Ensemble", "架空楽団", "مجموعة تجريبية", "시험 악단")


def tagged_flac(encoded, tags):
    """Replace FLAC comments without decoding or modifying the audio frames."""
    if encoded[:4] != b"fLaC":
        raise ValueError("Expected a synthetic FLAC fixture")
    blocks = []
    at = 4
    while True:
        if at + 4 > len(encoded):
            raise ValueError("Truncated FLAC metadata")
        header = encoded[at]
        length = int.from_bytes(encoded[at + 1 : at + 4], "big")
        at += 4
        if at + length > len(encoded):
            raise ValueError("Truncated FLAC block")
        if header & 127 != 4:
            blocks.append(
                bytes([header & 127])
                + length.to_bytes(3, "big")
                + encoded[at : at + length]
            )
        at += length
        if header & 128:
            break
    vendor = b"Gain synthetic SD fixture"
    comments = [f"{key}={value}".encode("utf-8") for key, value in tags.items()]
    body = struct.pack("<I", len(vendor)) + vendor + struct.pack("<I", len(comments))
    body += b"".join(struct.pack("<I", len(comment)) + comment for comment in comments)
    if len(body) >= 1 << 24:
        raise ValueError("FLAC comment block too large")
    return (
        b"fLaC"
        + b"".join(blocks)
        + b"\x84"
        + len(body).to_bytes(3, "big")
        + body
        + encoded[at:]
    )


def create(output, *, albums=16, tracks_per_album=24, mounts=(), caches=True):
    output = Path(output).resolve()
    if output.is_relative_to(ROOT):
        raise ValueError("Generated SD cards must be outside the gain repository")
    if (
        not 0 <= albums <= 1024
        or not 1 <= tracks_per_album <= 128
        or albums * tracks_per_album > 8192
    ):
        raise ValueError("Mock library exceeds the production view limits")
    output.mkdir(parents=True, exist_ok=False)
    music = output / "Music"
    music.mkdir()
    playlists = output / "Playlists"
    playlists.mkdir()
    fixture = (ROOT / "tests/fixtures/codecs/flac-16.flac").read_bytes()
    paths = []
    for album in range(albums):
        artist = ARTISTS[album % len(ARTISTS)]
        title = f"Synthetic Album {album + 1:03d}"
        directory = music / artist / title
        directory.mkdir(parents=True)
        shutil.copyfile(
            ROOT / "src/testdata/art-quadrants.jpg", directory / "cover.jpg"
        )
        for track in range(tracks_per_album):
            number = album * tracks_per_album + track + 1
            path = directory / f"{track + 1:02d} - Synthetic Track {number:04d}.flac"
            encoded = tagged_flac(
                fixture,
                {
                    "TITLE": f"Synthetic Track {number:04d}",
                    "ARTIST": artist,
                    "ALBUMARTIST": artist,
                    "ALBUM": title,
                    "TRACKNUMBER": track % 12 + 1,
                    "DISCNUMBER": track // 12 + 1,
                    "DATE": 2020 + album % 6,
                },
            )
            path.write_bytes(encoded)
            paths.append(path.relative_to(output).as_posix())
    for source in mounts:
        source = Path(source).resolve(strict=True)
        (music / source.name).symlink_to(source, target_is_directory=source.is_dir())
    playlist = "#EXTM3U\n" + "".join(f"../{path}\n" for path in paths[:12])
    (playlists / "Synthetic Mix.m3u8").write_text(playlist, encoding="utf-8")
    if caches:
        provision(output)
    return {"tracks": len(paths), "albums": albums, "mounted_sources": len(mounts)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "output", type=Path, help="New SD directory outside the gain repo"
    )
    parser.add_argument("--albums", type=int, default=16)
    parser.add_argument("--tracks-per-album", type=int, default=24)
    parser.add_argument(
        "--mount",
        type=Path,
        action="append",
        default=[],
        help="Mount a real file or folder read-only in the player adapter",
    )
    parser.add_argument(
        "--no-caches",
        action="store_true",
        help="Skip preallocated firmware cache files",
    )
    args = parser.parse_args()
    result = create(
        args.output,
        albums=args.albums,
        tracks_per_album=args.tracks_per_album,
        mounts=args.mount,
        caches=not args.no_caches,
    )
    print(
        f"Created {result['tracks']} synthetic tracks in {result['albums']} albums; {result['mounted_sources']} mounted sources"
    )


if __name__ == "__main__":
    main()

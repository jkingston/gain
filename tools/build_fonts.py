"""Regenerate losslessly cropped glyph masks from the pinned OFL font sources.

Needs Pillow. Ordinary firmware builds use the committed masks and need no font
renderer. Glyph advances and full layout boxes are retained when padding is cut.
"""

import argparse
import hashlib
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CODES = [
    *range(32, 127),
    *range(160, 256),
    263,
    353,
    8211,
    8212,
    8216,
    8217,
    8220,
    8221,
    8230,
]


def generate(output):
    from PIL import Image, ImageDraw, ImageFont

    sources = ROOT / "assets/fonts"
    manifest = json.loads((sources / "manifest.json").read_text())
    source = (ROOT / "src/font_data.zig").read_text()
    prefix = source[: source.index("const body =")]
    suffix = source[source.index("pub fn glyph(") :]
    original = bytearray()
    packed = bytearray()
    lines = []
    for role, (family, size, weight) in manifest["roles"].items():
        path = sources / f"{family}.ttf"
        if (
            hashlib.sha256(path.read_bytes()).hexdigest()
            != manifest["source_fonts"][family]
        ):
            raise RuntimeError(f"Wrong source font: {family}")
        face = ImageFont.truetype(str(path), size)
        face.set_variation_by_axes(
            [
                weight
                if axis["name"] == b"Weight"
                else size
                if axis["name"] == b"Optical size"
                else axis["default"]
                for axis in face.get_variation_axes()
            ]
        )
        lines.append(f"const {role} = [_]Glyph{{")
        for code in CODES:
            character = chr(code)
            advance = math.ceil(face.getlength(character))
            width = max(advance, face.getbbox(character)[2]) + 1
            height = size + 7
            fallback = manifest["fallback_bitmaps"].get(role)
            if fallback and code == fallback["code"]:
                # The original atlas used this small Noto fallback glyph.
                # Keep its pinned bitmap without bundling the full CJK font.
                width, height, advance = (
                    fallback[key] for key in ("width", "height", "advance")
                )
                image = Image.new("L", (width, height))
                left, top, right, bottom = fallback["box"]
                ink = Image.frombytes(
                    "L", (right - left, bottom - top), bytes.fromhex(fallback["mask"])
                )
                image.paste(ink, (left, top))
            else:
                image = Image.new("L", (width, height))
                ImageDraw.Draw(image).text((0, 0), character, font=face, fill=255)
            original.extend(image.tobytes())
            left, top, right, bottom = image.getbbox() or (0, 0, 0, 0)
            offset = len(packed)
            packed.extend(image.crop((left, top, right, bottom)).tobytes())
            fields = dict(
                code=code,
                offset=offset,
                width=width,
                height=height,
                advance=advance,
                ink_x=left,
                ink_y=top,
                ink_width=right - left,
                ink_height=bottom - top,
            )
            lines.append(
                "    .{ "
                + ", ".join(f".{key} = {value}" for key, value in fields.items())
                + " },"
            )
        lines.extend(["};", ""])
    for name, data in [("original", original), ("packed", packed)]:
        if hashlib.sha256(data).hexdigest() != manifest[f"{name}_mask_sha256"]:
            raise RuntimeError(
                f"{name} masks differ from the pinned rasterization; check Pillow/FreeType versions"
            )
    output.mkdir(parents=True, exist_ok=True)
    (output / "font_data.bin").write_bytes(packed)
    (output / "font_data.zig").write_text(prefix + "\n".join(lines) + "\n" + suffix)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "src")
    generate(parser.parse_args().output)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Turn the screenshot test's website captures into the site's images.

``StoreScreenshotsUITests`` writes ``web-<name>-<appearance>.png`` next to the store set: the MCP
page's window with transparent corners and close-ups of parts of other pages, all at 2x. This
writes, for each name and appearance, WebP at 1x and 2x of the width the site shows it at (the
1040 px content column at most), a 1x PNG of the light one for browsers without WebP, and ``_data/screenshots.yml`` with each
image's 1x size, which ``_includes/screenshot.html`` reads for its ``width`` and ``height``::

    garage_python/.venv/bin/python tools/screenshots/web_images.py <captures> docs

Needs Pillow built with WebP (the ``garage_python`` venv's is).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from PIL import Image, features

COLUMN = 1040
"""The site's content column (``--max-width`` in ``assets/style.css``), in CSS pixels."""

WEBP_QUALITY = 82
CAPTURE = re.compile(r"^web-(?P<name>[a-z0-9-]+)-(?P<appearance>light|dark)\.png$")


def sizes(width: int, height: int) -> tuple[tuple[int, int], tuple[int, int]]:
    """The 1x and 2x sizes for a 2x capture of ``width`` x ``height``: its own 1x, no wider than
    the column."""
    one_x = min(width // 2, COLUMN)
    return (one_x, round(height * one_x / width)), (
        one_x * 2,
        round(height * one_x * 2 / width),
    )


def convert(source: Path, out_dir: Path, stem: str, fallback: bool) -> tuple[int, int]:
    """Writes ``<stem>-1x.webp``, ``<stem>-2x.webp`` and, with ``fallback``, ``<stem>-1x.png``;
    returns the 1x size."""
    with Image.open(source) as image:
        image.load()
        mode = "RGBA" if "A" in image.getbands() else "RGB"
        image = image.convert(mode)
        one_x, two_x = sizes(*image.size)
        for suffix, size in (("1x", one_x), ("2x", two_x)):
            scaled = (
                image
                if image.size == size
                else image.resize(size, Image.Resampling.LANCZOS)
            )
            scaled.save(
                out_dir / f"{stem}-{suffix}.webp",
                "WEBP",
                quality=WEBP_QUALITY,
                method=6,
            )
            if suffix == "1x" and fallback:
                scaled.save(out_dir / f"{stem}-1x.png", "PNG", optimize=True)
    return one_x


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "captures", type=Path, help="folder holding the test's web-*.png files"
    )
    parser.add_argument("site", type=Path, help="the Jekyll site (docs/)")
    args = parser.parse_args(argv)

    if not features.check("webp"):
        print("Pillow has no WebP support", file=sys.stderr)
        return 1
    out_dir = args.site / "assets" / "screenshots"
    out_dir.mkdir(parents=True, exist_ok=True)

    found: dict[str, dict[str, tuple[int, int]]] = {}
    for source in sorted(args.captures.glob("web-*.png")):
        match = CAPTURE.match(source.name)
        if not match:
            continue
        name, appearance = match["name"], match["appearance"]
        found.setdefault(name, {})[appearance] = convert(
            source, out_dir, f"{name}-{appearance}", fallback=appearance == "light"
        )
        print(f"{source.name} -> {out_dir / name}-{appearance}-{{1x,2x}}.webp")
    if not found:
        print(f"no web-*.png in {args.captures}", file=sys.stderr)
        return 1

    lines = [
        "# Written by tools/screenshots/web_images.py: each screenshot's 1x size, for its width and height."
    ]
    for name, appearances in sorted(found.items()):
        if set(appearances) != {"light", "dark"}:
            print(f"{name} lacks a light or dark capture", file=sys.stderr)
            return 1
        if appearances["light"] != appearances["dark"]:
            print(
                f"{name}: light is {appearances['light']}, dark is {appearances['dark']}",
                file=sys.stderr,
            )
        width, height = appearances["light"]
        lines += [f"{name}:", f"  width: {width}", f"  height: {height}"]
    data = args.site / "_data" / "screenshots.yml"
    data.parent.mkdir(parents=True, exist_ok=True)
    data.write_text("\n".join(lines) + "\n")
    print(f"wrote {data}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

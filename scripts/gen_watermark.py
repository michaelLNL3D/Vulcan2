#!/usr/bin/env python3
"""Generate a subtle, widely-spaced LNL maker's-mark watermark tile.

Produces a monochrome, low-opacity silhouette of the triangle mark on a
large transparent tile, so when repeated it reads as faint texture in the
dark canvas gutters rather than busy noise.
"""
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / ".theme" / "sidebar-logo.png"
OUT = ROOT / ".theme" / "lnl-watermark.png"

TILE = 260        # spacing between marks (px)
MARK = 96         # rendered mark size (px)
TINT = (200, 202, 210)  # cool light-grey silhouette
OPACITY = 0.24    # subtle but legible on near-black


def main() -> None:
    mark = Image.open(SRC).convert("RGBA")
    alpha = mark.split()[3]
    solid = Image.new("RGBA", mark.size, TINT + (255,))
    blank = Image.new("RGBA", mark.size, TINT + (0,))
    sil = Image.composite(solid, blank, alpha)
    sil.putalpha(sil.split()[3].point(lambda p: int(p * OPACITY)))
    sil = sil.resize((MARK, MARK), Image.LANCZOS)

    tile = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    off = (TILE - MARK) // 2
    tile.paste(sil, (off, off), sil)
    tile.save(OUT)
    print(f"wrote {OUT.name} ({TILE}x{TILE} tile, {MARK}px mark @ {int(OPACITY*100)}%)")


if __name__ == "__main__":
    main()

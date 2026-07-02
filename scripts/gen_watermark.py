#!/usr/bin/env python3
"""Generate a subtle, diagonally-arrayed LNL maker's-mark watermark tile.

Half-drop layout: two faint marks per tile, placed on the tile's diagonal
(quarter and three-quarter points). When repeated, alternating rows offset
by half a step so the marks align along 45-degree diagonals instead of a
rectangular grid. Monochrome + low opacity so it reads as texture, not noise.
"""
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / ".theme" / "sidebar-logo.png"
OUT = ROOT / ".theme" / "lnl-watermark.png"

TILE = 360        # tile size (px) — spacing between marks
MARK = 92         # rendered mark size (px)
TINT = (200, 202, 210)  # cool light-grey silhouette
OPACITY = 0.24    # subtle but legible on near-black


def faint_mark() -> Image.Image:
    mark = Image.open(SRC).convert("RGBA")
    alpha = mark.split()[3]
    solid = Image.new("RGBA", mark.size, TINT + (255,))
    blank = Image.new("RGBA", mark.size, TINT + (0,))
    sil = Image.composite(solid, blank, alpha)
    sil.putalpha(sil.split()[3].point(lambda p: int(p * OPACITY)))
    return sil.resize((MARK, MARK), Image.LANCZOS)


def main() -> None:
    sil = faint_mark()
    tile = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    half = MARK // 2
    # two marks on the diagonal -> staggered (diamond) lattice when tiled
    for cx, cy in ((TILE * 0.25, TILE * 0.25), (TILE * 0.75, TILE * 0.75)):
        tile.paste(sil, (int(cx) - half, int(cy) - half), sil)
    tile.save(OUT)
    print(f"wrote {OUT.name} (diagonal {TILE}x{TILE} tile, 2x {MARK}px marks @ {int(OPACITY*100)}%)")


if __name__ == "__main__":
    main()

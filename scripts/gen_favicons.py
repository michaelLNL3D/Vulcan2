#!/usr/bin/env python3
"""Generate Mainsail favicons from the LNL3D triangle mark.

Pads the (non-square) mark onto a transparent square canvas, then
downscales to the two sizes Mainsail loads by exact filename.
"""
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / ".theme" / "sidebar-logo.png"
OUT = ROOT / ".theme"


def main() -> None:
    mark = Image.open(SRC).convert("RGBA")
    side = max(mark.size)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(mark, ((side - mark.width) // 2, (side - mark.height) // 2), mark)
    for size in (32, 16):
        icon = canvas.resize((size, size), Image.LANCZOS)
        icon.save(OUT / f"favicon-{size}x{size}.png")
        print(f"wrote favicon-{size}x{size}.png")


if __name__ == "__main__":
    main()

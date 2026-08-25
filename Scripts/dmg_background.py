#!/usr/bin/env python3
"""Draws the disk image window background: two icon wells and an arrow.

Text-only in the repo on purpose. The window is 660x400 points and the same
picture is drawn twice, at 1x and 2x, so the arrow stays crisp on a Retina
display -- macOS picks the representation, it does not scale one up.

Usage: dmg_background.py <output-dir>   ->  background.png, background@2x.png
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

WIDTH, HEIGHT = 660, 400
PAPER = (247, 245, 242)
GINGER = (232, 134, 60)
MUTED = (128, 120, 112)
ICON_Y = 176          # centre of both icons, matched in Scripts/make-dmg.sh
ARROW_FROM, ARROW_TO = 268, 392


def draw(scale: int) -> Image.Image:
    s = scale
    img = Image.new("RGB", (WIDTH * s, HEIGHT * s), PAPER)
    d = ImageDraw.Draw(img)

    # The arrow: a shaft between the two icons and a solid head at the
    # Applications end. Both ends stop clear of the icons so nothing overlaps.
    y = ICON_Y * s
    head = 13 * s
    d.line([(ARROW_FROM * s, y), ((ARROW_TO - head) * s, y)],
           fill=GINGER, width=4 * s)
    d.polygon([(ARROW_TO * s, y),
               ((ARROW_TO - head) * s, y - int(8.5 * s)),
               ((ARROW_TO - head) * s, y + int(8.5 * s))],
              fill=GINGER)

    caption = "Drag WhatsMyUsage into Applications"
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 15 * s)
    except OSError:
        font = ImageFont.load_default()
    box = d.textbbox((0, 0), caption, font=font)
    d.text(((img.width - (box[2] - box[0])) / 2, 300 * s), caption,
           fill=MUTED, font=font)
    return img


def main() -> None:
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    draw(1).save(out / "background.png")
    draw(2).save(out / "background@2x.png")


if __name__ == "__main__":
    main()

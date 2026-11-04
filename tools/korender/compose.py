#!/usr/bin/env python3
"""Puts tools/korender's reader renders into device frames, side by side,
for the README: KOReader's default page next to Sereno's Normal page on each
device, and the Text & page panel.

    python3 tools/korender/compose.py <korender_out_dir> <images_dir> <fonts_dir>
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

src, dst, fonts = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(dst, exist_ok=True)

DEVICES = [
    ("kindle-basic", '6" Kindle', 167),
    ("paperwhite", 'Kindle Paperwhite, 6.8"', 300),
    ("scribe", 'Kindle Scribe, 10.2"', 300),
]
PAGE_H = 900  # every page is scaled to this height, to be readable on GitHub
BEZEL = 34
BG = (246, 245, 242)
INK = (25, 25, 25)
GREY = (110, 110, 110)


def font(name, size):
    for d in (fonts, os.path.join(fonts, "noto")):
        p = os.path.join(d, name)
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


bold, regular, small = font("NotoSans-Bold.ttf", 30), font("NotoSans-Regular.ttf", 24), font("NotoSans-Regular.ttf", 21)


def framed(path, title, subtitle):
    page = Image.open(path).convert("RGB")
    w = round(page.width * PAGE_H / page.height)
    page = page.resize((w, PAGE_H), Image.LANCZOS)
    fw, fh = w + 2 * BEZEL, PAGE_H + 2 * BEZEL + 26
    tile = Image.new("RGB", (fw, fh + 96), BG)
    d = ImageDraw.Draw(tile)
    d.text((fw // 2, 8), title, font=bold, fill=INK, anchor="mt")
    d.text((fw // 2, 50), subtitle, font=small, fill=GREY, anchor="mt")
    d.rounded_rectangle((0, 96, fw - 1, 96 + fh - 1), radius=34, fill=(28, 28, 28))
    tile.paste(page, (BEZEL, 96 + BEZEL))
    return tile


def row(tiles, gap=50):
    w = sum(t.width for t in tiles) + gap * (len(tiles) - 1)
    h = max(t.height for t in tiles)
    out = Image.new("RGB", (w, h), BG)
    x = 0
    for t in tiles:
        out.paste(t, (x, 0))
        x += t.width + gap
    return out


def stack(rows, labels, gap=70, pad=50):
    w = max(r.width for r in rows) + 2 * pad
    h = sum(r.height + 60 for r in rows) + gap * (len(rows) - 1) + 2 * pad
    out = Image.new("RGB", (w, h), BG)
    d = ImageDraw.Draw(out)
    y = pad
    for r, label in zip(rows, labels):
        d.text((pad, y), label, font=bold, fill=INK)
        out.paste(r, ((w - r.width) // 2, y + 60))
        y += r.height + 60 + gap
    return out


def stats(device, case):
    # the render log line is not kept, so describe the layout from the file name
    return {"koreader": "font 22 · margins 10 (KOReader's defaults)", "sereno": "Normal", "panel": "Text panel"}[case]


def info(device, case):
    p = os.path.join(src, f"reader-{device}-{case}.txt")
    if os.path.exists(p):
        return open(p).read().strip()
    return stats(device, case)


rows, labels = [], []
for dev, name, _dpi in DEVICES:
    a, b = (os.path.join(src, f"reader-{dev}-{c}.png") for c in ("koreader", "sereno"))
    if os.path.exists(a) and os.path.exists(b):
        rows.append(row([framed(a, "KOReader default", info(dev, "koreader")), framed(b, "Sereno", info(dev, "sereno"))]))
        labels.append(name)
if rows:
    # two pairs per line: 6" and Paperwhite, then the Scribe
    out = stack(rows, labels)
    out.save(os.path.join(dst, "reader-margins.png"), optimize=True)

panels = [framed(os.path.join(src, f"reader-{dev}-panel.png"), name, info(dev, "panel"))
          for dev, name, _dpi in DEVICES if os.path.exists(os.path.join(src, f"reader-{dev}-panel.png"))]
if panels:
    out = Image.new("RGB", (sum(p.width for p in panels) + 50 * (len(panels) + 1), max(p.height for p in panels) + 100), BG)
    x = 50
    for p in panels:
        out.paste(p, (x, 50))
        x += p.width + 50
    out.save(os.path.join(dst, "reader-panel.png"), optimize=True)

presets = [("compact", "Compact"), ("normal", "Normal"), ("roomy", "Roomy")]
tiles = [framed(os.path.join(src, f"reader-paperwhite-preset-{pid}.png"), name, info("paperwhite", f"preset-{pid}"))
         for pid, name in presets if os.path.exists(os.path.join(src, f"reader-paperwhite-preset-{pid}.png"))]
if tiles:
    r = row(tiles)
    out = Image.new("RGB", (r.width + 100, r.height + 100), BG)
    out.paste(r, (50, 50))
    out.save(os.path.join(dst, "reader-layouts.png"), optimize=True)

pw = os.path.join(src, "reader-paperwhite-sereno.png")
if os.path.exists(pw):
    framed(pw, "Sereno on a Kindle Paperwhite", info("paperwhite", "sereno")).save(
        os.path.join(dst, "reader-paperwhite.png"), optimize=True)
# the whole shell on each device: home, library, quick controls, the reader's bars
for dev, name, _dpi in DEVICES:
    shots = [(f"{dev}.png", "Home"), (f"{dev}-library.png", "Library"), (f"{dev}-controls.png", "Quick controls"),
             (f"reader-{dev}-bars.png", "In a book")]
    tiles = [framed(os.path.join(src, f), label, name) for f, label in shots if os.path.exists(os.path.join(src, f))]
    if len(tiles) == len(shots):
        r = row(tiles)
        out = Image.new("RGB", (r.width + 100, r.height + 100), BG)
        out.paste(r, (50, 50))
        out.save(os.path.join(dst, f"shell-{dev}.png"), optimize=True)

# reading statistics and import
for dev, name, _dpi in DEVICES:
    shots = [(f"{dev}-stats.png", "Stats"), (f"{dev}-import.png", "Import")]
    tiles = [framed(os.path.join(src, f), label, name) for f, label in shots if os.path.exists(os.path.join(src, f))]
    if len(tiles) == len(shots):
        r = row(tiles)
        out = Image.new("RGB", (r.width + 100, r.height + 100), BG)
        out.paste(r, (50, 50))
        out.save(os.path.join(dst, f"stats-{dev}.png"), optimize=True)

# settings and the sleep screen
for dev, name, _dpi in DEVICES:
    shots = [(f"{dev}-settings.png", "Settings"), (f"{dev}-sleep.png", "Sleep screen")]
    tiles = [framed(os.path.join(src, f), label, name) for f, label in shots if os.path.exists(os.path.join(src, f))]
    if len(tiles) == len(shots):
        r = row(tiles)
        out = Image.new("RGB", (r.width + 100, r.height + 100), BG)
        out.paste(r, (50, 50))
        out.save(os.path.join(dst, f"settings-{dev}.png"), optimize=True)

# the Text panel's tabs on the Paperwhite: Themes, Font, the font list, Layout
shots = [("reader-paperwhite-panel-themes.png", "Themes"), ("reader-paperwhite-panel.png", "Font"),
         ("reader-paperwhite-panel-font-list.png", "Font family"), ("reader-paperwhite-panel-layout.png", "Layout")]
tiles = [framed(os.path.join(src, f), label, "Kindle Paperwhite") for f, label in shots if os.path.exists(os.path.join(src, f))]
if len(tiles) == len(shots):
    r = row(tiles)
    out = Image.new("RGB", (r.width + 100, r.height + 100), BG)
    out.paste(r, (50, 50))
    out.save(os.path.join(dst, "reader-panel-tabs.png"), optimize=True)

print("composed into", dst)

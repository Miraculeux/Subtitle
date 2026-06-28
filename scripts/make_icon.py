#!/usr/bin/env python3
"""Generates the macOS AppIcon set for the Subtitle app.

Draws a 1024x1024 master image (rounded "squircle" with a gradient,
a centered audio waveform, and two subtitle bars) and exports every
size required by an .appiconset, plus a Contents.json.
"""
import json
import math
import os
from PIL import Image, ImageDraw

OUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Sources", "Assets.xcassets", "AppIcon.appiconset",
)
BASE = 1024


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def rounded_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def make_master():
    img = Image.new("RGBA", (BASE, BASE), (0, 0, 0, 0))

    # Vertical gradient background (indigo -> violet).
    top = (88, 86, 214)      # systemIndigo-ish
    bottom = (148, 85, 211)  # violet
    grad = Image.new("RGBA", (BASE, BASE), (0, 0, 0, 255))
    gd = grad.load()
    for y in range(BASE):
        c = lerp(top, bottom, y / (BASE - 1))
        for x in range(BASE):
            gd[x, y] = (c[0], c[1], c[2], 255)

    # Squircle with margin so it reads as a native macOS icon.
    margin = int(BASE * 0.085)
    inner = BASE - 2 * margin
    radius = int(inner * 0.235)
    mask = rounded_mask(inner, radius)
    panel = grad.crop((0, 0, inner, inner))
    img.paste(panel, (margin, margin), mask)

    draw = ImageDraw.Draw(img)

    # Centered audio waveform (rounded vertical bars).
    cx = BASE // 2
    cy = int(BASE * 0.44)
    bar_w = int(inner * 0.052)
    gap = int(bar_w * 0.85)
    heights = [0.26, 0.5, 0.78, 1.0, 0.62, 0.86, 0.4, 0.2]
    n = len(heights)
    total_w = n * bar_w + (n - 1) * gap
    x = cx - total_w // 2
    max_h = int(inner * 0.42)
    white = (255, 255, 255, 255)
    for h in heights:
        bh = int(max_h * h)
        draw.rounded_rectangle(
            [x, cy - bh // 2, x + bar_w, cy + bh // 2],
            radius=bar_w // 2,
            fill=white,
        )
        x += bar_w + gap

    # Two subtitle bars near the bottom ("CC" feel).
    sub_y = int(BASE * 0.74)
    sub_h = int(inner * 0.072)
    left = cx - int(inner * 0.34)
    right = cx + int(inner * 0.34)
    translucent = (255, 255, 255, 235)
    dim = (255, 255, 255, 150)
    draw.rounded_rectangle([left, sub_y, right, sub_y + sub_h], radius=sub_h // 2, fill=translucent)
    sub_y2 = sub_y + int(sub_h * 1.8)
    draw.rounded_rectangle([left, sub_y2, cx + int(inner * 0.12), sub_y2 + sub_h], radius=sub_h // 2, fill=dim)

    return img


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    master = make_master()

    # (size_pt, scale)
    specs = [
        (16, 1), (16, 2),
        (32, 1), (32, 2),
        (128, 1), (128, 2),
        (256, 1), (256, 2),
        (512, 1), (512, 2),
    ]

    images = []
    for pt, scale in specs:
        px = pt * scale
        filename = f"icon_{pt}x{pt}@{scale}x.png"
        resized = master.resize((px, px), Image.LANCZOS)
        resized.save(os.path.join(OUT_DIR, filename))
        images.append({
            "size": f"{pt}x{pt}",
            "idiom": "mac",
            "filename": filename,
            "scale": f"{scale}x",
        })

    contents = {"images": images, "info": {"version": 1, "author": "xcode"}}
    with open(os.path.join(OUT_DIR, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)

    print(f"Wrote {len(images)} icons + Contents.json to {OUT_DIR}")


if __name__ == "__main__":
    main()

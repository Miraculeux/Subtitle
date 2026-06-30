#!/usr/bin/env python3
"""Generates the macOS AppIcon set for the Subtitle app.

Draws a 1024x1024 master image (rounded "squircle" with a gradient,
a centered audio waveform, and two subtitle bars) and exports every
size required by an .appiconset, plus a Contents.json.
"""
import json
import math
import os
from PIL import Image, ImageDraw, ImageFilter

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

    # Classic macOS app-icon geometry: a rounded squircle on a transparent
    # canvas with the standard ~8.6% margin, plus a soft drop shadow. This is
    # what well-behaved macOS icons use and it renders correctly (no system
    # tile/border) on macOS Tahoe.
    margin = int(BASE * 0.086)
    inner = BASE - 2 * margin
    radius = int(inner * 0.225)

    # Drop shadow: a blurred dark rounded rect, offset slightly downward.
    shadow = Image.new("RGBA", (BASE, BASE), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    offset = int(BASE * 0.012)
    sd.rounded_rectangle(
        [margin, margin + offset, margin + inner, margin + inner + offset],
        radius=radius, fill=(0, 0, 0, 120),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(BASE * 0.02))
    img = Image.alpha_composite(img, shadow)

    # Gradient squircle on top.
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
    master = make_master()
    build_icns(master)


def build_icns(master):
    """Builds a full-size AppIcon.icns (up to 1024) via iconutil.

    macOS Tahoe renders a standalone .icns (CFBundleIconFile) edge-to-edge,
    whereas an asset-catalog app icon gets wrapped in a system platter. So the
    app ships this .icns rather than an asset-catalog AppIcon.
    """
    import subprocess
    import tempfile

    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    icns_path = os.path.join(project_root, "Sources", "AppIcon.icns")

    pairs = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        for filename, px in pairs:
            master.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, filename))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns_path], check=True)
    print(f"Wrote AppIcon.icns to {icns_path}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Author the shared surah-name banner FRAME (no text baked in).

Why this exists: the only ready-made ornate banners we could find were either
auto-traced bitmaps (a 673 KB / 1098-path SVG whose Arabic text rendered
garbled) or stock images with murky licensing. So we author one clean,
self-made, transparent-margin raster instead. It is reused for ALL 114 surah
openings — the surah name + Basmala are drawn on top at runtime with real font
glyphs (crisp, never baked into the image).

Output: assets/decor/surah_banner_frame.webp
  - RGBA, transparent margins (so it floats on the cream page background)
  - A central cream cartouche where the surah-name glyph is overlaid in Flutter
  - No Arabic text, no calligraphy — purely the navy/teal/gold ornamental frame

Deterministic: re-running reproduces the identical asset. Requires Pillow.
Run:  python3 tools/art/make_surah_banner.py
"""

from __future__ import annotations

import math
import os

from PIL import Image, ImageDraw

# --- palette (matches the app's "Liquid Glass" tokens + the reference mushaf) -
NAVY = (10, 36, 92, 255)        # field
NAVY_DK = (7, 25, 64, 255)      # shadow line
TEAL = (38, 122, 142, 255)      # inner band
TEAL_DK = (26, 90, 106, 255)
GOLD = (201, 161, 74, 255)      # rules + ornaments
GOLD_LT = (224, 193, 120, 255)  # highlight
CREAM = (244, 233, 200, 255)    # cartouche fill (name sits here)
RED = (122, 46, 46, 255)        # tiny accent gems

# Supersample for crisp anti-aliased curves, then downscale.
SS = 4
W, H = 1200, 300            # final logical size
CW, CH = W * SS, H * SS     # canvas (supersampled)


def rr(d, box, radius, **kw):
    d.rounded_rectangle(box, radius=radius, **kw)


def star(d, cx, cy, r_out, r_in, points=8, fill=None, outline=None, width=1):
    pts = []
    for i in range(points * 2):
        ang = math.pi * i / points - math.pi / 2
        r = r_out if i % 2 == 0 else r_in
        pts.append((cx + r * math.cos(ang), cy + r * math.sin(ang)))
    d.polygon(pts, fill=fill, outline=outline, width=width)


def petal(d, cx, cy, rx, ry, ang_deg, fill):
    """A small leaf/petal: an ellipse rotated by drawing onto a temp layer."""
    pad = int(max(rx, ry) * 2) + 4
    lay = Image.new("RGBA", (pad * 2, pad * 2), (0, 0, 0, 0))
    ld = ImageDraw.Draw(lay)
    ld.ellipse([pad - rx, pad - ry, pad + rx, pad + ry], fill=fill)
    lay = lay.rotate(ang_deg, resample=Image.BICUBIC, center=(pad, pad))
    d._image.alpha_composite(lay, (int(cx - pad), int(cy - pad)))


def floret(img, cx, cy, r):
    """An 8-petal gold rosette with a red center gem — the corner/side motif."""
    d = ImageDraw.Draw(img)
    d._image = img
    for k in range(8):
        ang = 45 * k
        px = cx + (r * 0.55) * math.cos(math.radians(ang))
        py = cy + (r * 0.55) * math.sin(math.radians(ang))
        petal(d, px, py, r * 0.5, r * 0.22, -ang, GOLD)
    d.ellipse([cx - r * 0.28, cy - r * 0.28, cx + r * 0.28, cy + r * 0.28],
              fill=GOLD_LT)
    d.ellipse([cx - r * 0.14, cy - r * 0.14, cx + r * 0.14, cy + r * 0.14],
              fill=RED)


def cartouche(d, box, fill, outline, width):
    """Pointed-arch lozenge (mihrab silhouette) for the surah name."""
    x0, y0, x1, y1 = box
    h = y1 - y0
    tip = h * 0.5
    pts = [
        (x0, (y0 + y1) / 2),
        (x0 + tip, y0),
        (x1 - tip, y0),
        (x1, (y0 + y1) / 2),
        (x1 - tip, y1),
        (x0 + tip, y1),
    ]
    d.polygon(pts, fill=fill, outline=outline, width=width)


def build() -> Image.Image:
    img = Image.new("RGBA", (CW, CH), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    s = SS
    m = 10 * s  # outer margin (transparent)

    # Outer gold frame (double rule) + navy field.
    rr(d, [m, m, CW - m, CH - m], 26 * s, fill=GOLD)
    rr(d, [m + 6 * s, m + 6 * s, CW - m - 6 * s, CH - m - 6 * s], 22 * s,
       fill=NAVY)
    # Teal inner band with a thin gold keyline.
    inset = m + 16 * s
    rr(d, [inset, inset, CW - inset, CH - inset], 16 * s, fill=TEAL_DK)
    rr(d, [inset + 3 * s, inset + 3 * s, CW - inset - 3 * s, CH - inset - 3 * s],
       14 * s, outline=GOLD, width=2 * s)

    # Central cream cartouche (the surah name is overlaid here at runtime).
    cx0 = CW * 0.30
    cx1 = CW * 0.70
    cy0 = CH * 0.30
    cy1 = CH * 0.70
    cartouche(d, [cx0 - 8 * s, cy0 - 6 * s, cx1 + 8 * s, cy1 + 6 * s],
              GOLD, None, 0)
    cartouche(d, [cx0, cy0, cx1, cy1], CREAM, GOLD_LT, 2 * s)

    # Side rosettes flanking the cartouche.
    floret(img, int(CW * 0.205), int(CH * 0.5), 30 * s)
    floret(img, int(CW * 0.795), int(CH * 0.5), 30 * s)

    # Corner rosettes.
    for fx in (CW * 0.085, CW * 0.915):
        for fy in (CH * 0.27, CH * 0.73):
            floret(img, int(fx), int(fy), 17 * s)

    # Small gold stars sprinkled along the navy band for texture.
    d2 = ImageDraw.Draw(img)
    for sx in (0.13, 0.87):
        star(d2, CW * sx, CH * 0.5, 9 * s, 4 * s, 6, fill=GOLD_LT)

    return img.resize((W, H), Image.LANCZOS)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.normpath(os.path.join(here, "..", "..", "assets", "decor",
                                        "surah_banner_frame.webp"))
    os.makedirs(os.path.dirname(out), exist_ok=True)
    img = build()
    img.save(out, "WEBP", lossless=True, quality=95, method=6)
    kb = os.path.getsize(out) / 1024
    print(f"wrote {out} ({W}x{H}, {kb:.1f} KB)")


if __name__ == "__main__":
    main()

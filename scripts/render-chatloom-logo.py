#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Generate the ChatLoom logo SVGs and every raster icon in the repository.

The mark is two speech-bubble loops woven through each other (over at the
top crossing, under at the bottom one) in Notion dark v2 colours. Rasters are
rendered with ffmpeg's librsvg decoder; WebP is not used by the repo.

Usage: python3 scripts/render-chatloom-logo.py [--svg-only]
Re-running is idempotent. Replace the geometry/colours below to redesign.
"""

from __future__ import annotations

import argparse
import math
import os
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Notion dark v2 tokens (lib/ui/notion/notion_tokens.dart).
BG = '#191919'  # background
SURFACE = '#252525'  # surface
LIGHT = '#E8E7E5'  # text / accent
BLUE = '#379AD3'  # info
WHITE = '#FFFFFF'

# Glyph geometry in its own unit space.
R = 196.0  # loop radius
CA = (418.0, 486.0)  # left loop centre
CB = (606.0, 538.0)  # right loop centre
TAIL = 74.0  # how far the bubble tail reaches beyond the stroke centre
# Bubble gap (degrees, y-down) where the tail leaves the loop.
GAP_A = (118.0, 152.0, 141.0)  # start, end, tip angle (bottom-left)
GAP_B = (28.0, 62.0, 39.0)  # mirrored (bottom-right)


def pt(c, ang, rad):
    a = math.radians(ang)
    return (c[0] + rad * math.cos(a), c[1] + rad * math.sin(a))


def bubble_path(c, gap):
    start, end, tip = gap
    p0 = pt(c, end, R)
    p1 = pt(c, start + 360.0, R)
    t = pt(c, tip, R + TAIL)
    return (
        f'M{p0[0]:.2f},{p0[1]:.2f} '
        f'A{R:.2f},{R:.2f} 0 1 1 {p1[0]:.2f},{p1[1]:.2f} '
        f'L{t[0]:.2f},{t[1]:.2f} Z'
    )


def crossings():
    (x0, y0), (x1, y1) = CA, CB
    d = math.hypot(x1 - x0, y1 - y0)
    a = d / 2
    h = math.sqrt(R * R - a * a)
    mx, my = x0 + (x1 - x0) / 2, y0 + (y1 - y0) / 2
    ux, uy = (x1 - x0) / d, (y1 - y0) / d
    p = (mx - uy * h, my + ux * h)
    q = (mx + uy * h, my - ux * h)
    top, bottom = sorted([p, q], key=lambda v: v[1])
    return top, bottom


def glyph_extent(stroke):
    """Bounding box and centre-radius of the glyph including stroke."""
    pts = []
    for c, gap in ((CA, GAP_A), (CB, GAP_B)):
        for ang in range(0, 360, 2):
            pts.append(pt(c, ang, R + stroke / 2))
        pts.append(pt(c, gap[2], R + TAIL + stroke / 2))
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    box = (min(xs), min(ys), max(xs), max(ys))
    cx, cy = (box[0] + box[2]) / 2, (box[1] + box[3]) / 2
    rad = max(math.hypot(x - cx, y - cy) for x, y in pts)
    return box, (cx, cy), rad


def glyph(
    canvas,
    *,
    fit,
    mode='radius',
    stroke=76.0,
    gap=26.0,
    color_a=LIGHT,
    color_b=BLUE,
    uid='g',
):
    """Return SVG defs+group drawing the woven glyph centred in `canvas`.

    fit: fraction of the canvas used by the glyph's bounding circle (mode
    'radius') or bounding box width (mode 'box').
    """
    box, (cx, cy), rad = glyph_extent(stroke)
    if mode == 'radius':
        s = canvas * fit / (2 * rad)
    else:
        s = canvas * fit / max(box[2] - box[0], box[3] - box[1])
    tx = canvas / 2 - cx * s
    ty = canvas / 2 - cy * s
    pa = bubble_path(CA, GAP_A)
    pb = bubble_path(CB, GAP_B)
    _, bottom = crossings()
    halo = stroke + 2 * gap
    keep = stroke * 1.9
    common = f'fill="none" stroke-linejoin="round" stroke-linecap="round"'
    return f'''
  <defs>
    <clipPath id="{uid}-bottom"><circle cx="{bottom[0]:.2f}" cy="{bottom[1]:.2f}" r="{keep:.2f}"/></clipPath>
    <mask id="{uid}-mb" maskUnits="userSpaceOnUse" x="-2000" y="-2000" width="5000" height="5000">
      <rect x="-2000" y="-2000" width="5000" height="5000" fill="#fff"/>
      <path d="{pa}" {common} stroke="#000" stroke-width="{halo:.2f}"/>
      <circle cx="{bottom[0]:.2f}" cy="{bottom[1]:.2f}" r="{keep:.2f}" fill="#fff"/>
    </mask>
    <mask id="{uid}-ma" maskUnits="userSpaceOnUse" x="-2000" y="-2000" width="5000" height="5000">
      <rect x="-2000" y="-2000" width="5000" height="5000" fill="#fff"/>
      <path d="{pb}" {common} stroke="#000" stroke-width="{halo:.2f}" clip-path="url(#{uid}-bottom)"/>
    </mask>
  </defs>
  <g transform="translate({tx:.3f} {ty:.3f}) scale({s:.5f})">
    <path d="{pb}" {common} stroke="{color_b}" stroke-width="{stroke:.2f}" mask="url(#{uid}-mb)"/>
    <path d="{pa}" {common} stroke="{color_a}" stroke-width="{stroke:.2f}" mask="url(#{uid}-ma)"/>
  </g>'''


def svg(size, body, w=None, h=None):
    w = w or size
    h = h or size
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
        f'viewBox="0 0 {w} {h}">{body}\n</svg>\n'
    )


def rounded_bg(canvas, inset=0.0, radius=0.2237, color=BG):
    side = canvas - 2 * inset
    return (
        f'\n  <rect x="{inset}" y="{inset}" width="{side}" height="{side}" '
        f'rx="{side * radius:.2f}" fill="{color}"/>'
    )


def square_bg(canvas, color=BG):
    return f'\n  <rect width="{canvas}" height="{canvas}" fill="{color}"/>'


C = 1024

VARIANTS = {
    # Full app icon: rounded dark tile with the coloured mark.
    'logo': svg(C, rounded_bg(C) + glyph(C, fit=0.80)),
    # Full-bleed tile for platforms that mask the icon themselves (iOS).
    'logo_square': svg(C, square_bg(C) + glyph(C, fit=0.66)),
    # Maskable web icon: mark within the 80% safe zone.
    'logo_maskable': svg(C, square_bg(C) + glyph(C, fit=0.58)),
    # macOS: 824 px tile on a 1024 canvas (Apple icon grid).
    'logo_macos': svg(C, rounded_bg(C, inset=100, radius=0.2247) + glyph(C, fit=0.56)),
    # Mark only, transparent.
    'logo_standalone': svg(C, glyph(C, fit=0.92)),
    # Adaptive icon layers (the mipmap XML adds a 16% inset).
    'logo_foreground': svg(C, glyph(C, fit=0.86)),
    'logo_background': svg(C, square_bg(C)),
    'logo_mono': svg(C, glyph(C, fit=0.86, color_a=WHITE, color_b=WHITE)),
    # Status-bar notification icon: white alpha shape, thicker strokes.
    'logo_notification': svg(
        C,
        glyph(C, fit=0.98, stroke=96, gap=34, color_a=WHITE, color_b=WHITE),
    ),
    # Android splash centre image (drawn on the dark launch background).
    'logo_splash': svg(C, glyph(C, fit=0.62)),
}


def wordmark(w, h, *, icon=True, pad=0.0, bg=None, text_color=LIGHT):
    body = ''
    if bg:
        body += f'\n  <rect width="{w}" height="{h}" fill="{bg}"/>'
    x = pad
    if icon:
        icon_size = h - 2 * pad
        body += f'\n  <g transform="translate({pad} {pad})">' + svg_inner(
            icon_size
        ) + '\n  </g>'
        x = pad + icon_size + h * 0.12
    # Roboto Bold "ChatLoom" is ~4.6 em wide with a ~0.71 em cap height.
    font = h * 0.42 if icon else min((w - x) / 4.65, h / 0.80)
    baseline = h / 2 + font * 0.355
    body += (
        f'\n  <text x="{x:.1f}" y="{baseline:.1f}" font-family="Roboto" '
        f'font-weight="700" font-size="{font:.1f}" letter-spacing="{-font * 0.01:.2f}" '
        f'fill="{text_color}">Chat<tspan fill="{BLUE}">Loom</tspan></text>'
    )
    return svg(None, body, w=w, h=h)


def svg_inner(size):
    # The banner already sits on the dark tile colour, so draw the mark only.
    scale = size / C
    return (
        f'<g transform="scale({scale:.5f})">'
        + glyph(C, fit=0.98, uid='wm')
        + '</g>'
    )


def png_size(path):
    with open(path, 'rb') as f:
        head = f.read(24)
    if head[:8] != b'\x89PNG\r\n\x1a\n':
        return None
    return struct.unpack('>II', head[16:24])


def render(svg_text, out, w, h=None, env=None):
    h = h or w
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile('w', suffix='.svg', delete=False) as f:
        f.write(svg_text)
        src = f.name
    try:
        # Render at 4x then downscale for crisper anti-aliasing at tiny sizes.
        k = 1  # librsvg anti-aliases well at the target size
        cmd = [
            'ffmpeg', '-v', 'error', '-y',
            '-width', str(w * k), '-height', str(h * k), '-keep_ar', '0',
            '-i', src,
        ]
        if k > 1:
            cmd += ['-vf', f'scale={w}:{h}:flags=area']
        cmd += ['-pix_fmt', 'rgba', '-frames:v', '1', str(out)]
        subprocess.run(cmd, check=True, env=env)
    finally:
        os.unlink(src)


def solid_png(out, color, size=1):
    svg_text = svg(size, square_bg(size, color))
    render(svg_text, out, size)


def write_ico(out, pngs):
    entries = []
    data = b''
    offset = 6 + 16 * len(pngs)
    for p in pngs:
        blob = Path(p).read_bytes()
        w, h = png_size(p)
        entries.append(
            struct.pack(
                '<BBBBHHII',
                w % 256, h % 256, 0, 0, 1, 32, len(blob), offset + len(data),
            )
        )
        data += blob
    out.write_bytes(struct.pack('<HHH', 0, 1, len(pngs)) + b''.join(entries) + data)


def font_env(tmp):
    conf = Path(tmp) / 'fonts.conf'
    conf.write_text(
        '<?xml version="1.0"?><!DOCTYPE fontconfig SYSTEM "fonts.dtd">'
        f'<fontconfig><dir>{ROOT / "assets/notion/fonts"}</dir>'
        '<include ignore_missing="yes">/etc/fonts/fonts.conf</include>'
        f'<cachedir>{tmp}/fc-cache</cachedir></fontconfig>'
    )
    env = dict(os.environ)
    env['FONTCONFIG_FILE'] = str(conf)
    return env


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--svg-only', action='store_true')
    args = ap.parse_args()

    vec = ROOT / 'assets/logo/vector'
    vec.mkdir(parents=True, exist_ok=True)
    for name, text in VARIANTS.items():
        (vec / f'{name}.svg').write_text(text)
    (vec / 'logo_font.svg').write_text(wordmark(1455, 272, icon=False))
    (vec / 'banner.svg').write_text(wordmark(1500, 501, pad=110, bg=BG))
    if args.svg_only:
        return 0

    tmp = tempfile.mkdtemp(prefix='chatloom-logo-')
    env = font_env(tmp)
    v = VARIANTS
    jobs = []  # (svg, path, w, h)

    def add(name, path, w, h=None):
        jobs.append((v[name] if name in v else name, ROOT / path, w, h))

    # In-app assets.
    for name in ('logo', 'logo_standalone', 'logo_mono', 'logo_foreground', 'logo_background'):
        add(name, f'assets/logo/img/{name}.png', 2000)
    add('logo', 'assets/logo/mini/logo_mini.png', 500)
    add('logo_mono', 'assets/logo/mini/logo_mono_mini.png', 500)
    jobs.append((wordmark(1455, 272, icon=False), ROOT / 'assets/logo/img/logo_font.png', 1455, 272))
    jobs.append((wordmark(624, 117, icon=False), ROOT / 'assets/logo/mini/logo_font_mini.png', 624, 117))
    jobs.append((wordmark(1500, 501, pad=110, bg=BG), ROOT / 'assets/logo/img/banner.png', 1500, 501))
    jobs.append((wordmark(1000, 334, pad=73, bg=BG), ROOT / 'assets/logo/mini/banner.png', 1000, 334))

    # Android.
    res = 'android/app/src/main/res'
    dens = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}
    for d, k in dens.items():
        add('logo', f'{res}/mipmap-{d}/ic_launcher.png', round(48 * k))
        add('logo_foreground', f'{res}/drawable-{d}/ic_launcher_foreground.png', round(108 * k))
        add('logo_background', f'{res}/drawable-{d}/ic_launcher_background.png', round(108 * k))
        add('logo_mono', f'{res}/drawable-{d}/ic_launcher_monochrome.png', round(108 * k))
        add('logo_notification', f'{res}/drawable-{d}/notifications_icon.png', round(24 * k))
        add('logo_splash', f'{res}/drawable-{d}/splash.png', round(177 * k))

    # iOS.
    ios = 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
    for p in sorted((ROOT / ios).glob('Icon-App-*.png')):
        stem = p.stem[len('Icon-App-'):]
        pts, scale = stem.split('@')
        w = round(float(pts.split('x')[0]) * int(scale[:-1]))
        add('logo_square', f'{ios}/{p.name}', w)

    # macOS (Contents.json names plus the unused legacy *-mac.png copies).
    mac = 'macos/Runner/Assets.xcassets/AppIcon.appiconset'
    for n in (16, 32, 64, 128, 256, 512, 1024):
        add('logo_macos', f'{mac}/app_icon_{n}.png', n)
        if (ROOT / mac / f'{n}-mac.png').exists():
            add('logo_macos', f'{mac}/{n}-mac.png', n)

    # Web.
    add('logo', 'web/favicon.png', 16)
    for n in (16, 32, 48, 192, 512):
        add('logo', f'web/icons/Icon-{n}.png', n)
    for n in (192, 512):
        add('logo_maskable', f'web/icons/Icon-maskable-{n}.png', n)

    # Linux snap / desktop.
    add('logo', 'snap/gui/fluffychat.png', 500)

    for text, out, w, h in jobs:
        render(text, out, w, h, env=env)

    # Launch backgrounds: dark in both themes (the splash mark is light).
    for d in ('drawable', 'drawable-v21', 'drawable-night', 'drawable-night-v21'):
        solid_png(ROOT / res / d / 'background.png', BG)

    # Windows .ico with PNG-compressed entries.
    ico_parts = []
    for n in (16, 24, 32, 48, 64, 128, 256):
        p = Path(tmp) / f'ico-{n}.png'
        render(v['logo'], p, n)
        ico_parts.append(p)
    write_ico(ROOT / 'windows/runner/resources/app_icon.ico', ico_parts)

    for _, out, w, h in jobs:
        got = png_size(out)
        if got != (w, h or w):
            print(f'size mismatch {out}: {got}', file=sys.stderr)
            return 1
    print(f'rendered {len(jobs) + 4 + 1} files')
    return 0


if __name__ == '__main__':
    sys.exit(main())

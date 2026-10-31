#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Render every ChatLoom icon and logo raster from the SVGs in docs/brand/.

Sources (vector, edit these or scripts/brand/build-sources.py):
  docs/brand/chatloom-mark.svg       glass mark
  docs/brand/chatloom-mark-flat.svg  single-colour silhouette
  docs/brand/chatloom-social.svg     GitHub social preview

Writes the app icon master docs/brand/chatloom-app-icon.svg and the rasters:
in-app logo (assets/logo/), Android launcher (adaptive foreground,
background and monochrome layers plus legacy mipmaps), notification icon,
pre-12 and Android 12 splash, macOS AppIcon, web icons and the brand PNGs.

Rendering uses rsvg-convert, ffmpeg's librsvg decoder or the cairosvg Python
module, whichever is found first; everything else is the standard library.
Re-running is idempotent.

Usage: python3 scripts/brand/generate-icons.py [--check]
  --check  render into a temporary directory and report files that differ
           (by size) instead of writing them.
"""

from __future__ import annotations

import argparse
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BRAND = ROOT / 'docs/brand'
RES = 'android/app/src/main/res'
MAC = 'macos/Runner/Assets.xcassets/AppIcon.appiconset'

# Visual bounds of the mark inside its 1024 box (see build-sources.py) and
# the radius of its bounding circle around the box centre (the tail tip of
# the front bubble is the farthest point).
MARK_BOX = (140.0, 144.0, 884.0, 880.0)
MARK_REACH = 476.0

# Tile behind the mark: Notion surfaces darkened into a glass slab, the
# default accent glowing through it, a hairline like the dock's.
TILE_TOP = '#2B2B2B'
TILE_BOTTOM = '#151515'
GLOW = '#0A7CFF'
PAGE = '#191919'
WHITE = '#FFFFFF'

DENSITIES = {'mdpi': 1.0, 'hdpi': 1.5, 'xhdpi': 2.0, 'xxhdpi': 3.0, 'xxxhdpi': 4.0}


# ------------------------------------------------------------------ svg utils
def read_svg(name):
    text = (BRAND / name).read_text()
    m = re.search(r'<svg\b[^>]*\bviewBox="([^"]+)"[^>]*>(.*)</svg>', text, re.S)
    if not m:
        raise SystemExit(f'{name}: no <svg viewBox> root')
    view = [float(v) for v in m.group(1).split()]
    body = re.sub(r'<title>.*?</title>', '', m.group(2), flags=re.S)
    return view, body


def prefixed(body, prefix):
    """Make ids unique so several copies can share one document."""
    for i in sorted(set(re.findall(r'\bid="([^"]+)"', body)), key=len, reverse=True):
        body = body.replace(f'id="{i}"', f'id="{prefix}{i}"')
        body = body.replace(f'url(#{i})', f'url(#{prefix}{i})')
        body = body.replace(f'href="#{i}"', f'href="#{prefix}{i}"')
    return body


def recolor(body, color):
    return re.sub(r'fill="#[0-9A-Fa-f]{6}"', f'fill="{color}"', body)


def place(name, cx, cy, scale, prefix, color=None):
    """The source's 1024 box scaled by `scale` with MARK_BOX centred on (cx, cy)."""
    _, body = read_svg(name)
    body = prefixed(body, prefix)
    if color:
        body = recolor(body, color)
    mx = (MARK_BOX[0] + MARK_BOX[2]) / 2
    my = (MARK_BOX[1] + MARK_BOX[3]) / 2
    return (
        f'<g transform="translate({cx - mx * scale:.3f} {cy - my * scale:.3f}) '
        f'scale({scale:.6f})">{body}</g>'
    )


def doc(w, h, body):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w:g}" height="{h:g}" '
        f'viewBox="0 0 {w:g} {h:g}">\n{body}\n</svg>\n'
    )


def mark_width_scale(canvas_fraction, canvas):
    """Scale so the mark's visual width is `canvas_fraction` of `canvas`."""
    return canvas * canvas_fraction / (MARK_BOX[2] - MARK_BOX[0])


def mark_reach_scale(radius):
    """Scale so every point of the mark lies within `radius` of the centre."""
    return radius / MARK_REACH


# ------------------------------------------------------------------- tiles
def tile_defs(p):
    return f'''<defs>
  <linearGradient id="{p}fill" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="{TILE_TOP}"/><stop offset="1" stop-color="{TILE_BOTTOM}"/>
  </linearGradient>
  <radialGradient id="{p}glow" cx="0.5" cy="0.56" r="0.5">
    <stop offset="0" stop-color="{GLOW}" stop-opacity="0.30"/>
    <stop offset="1" stop-color="{GLOW}" stop-opacity="0"/>
  </radialGradient>
  <linearGradient id="{p}rim" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.22"/>
    <stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0.06"/>
    <stop offset="1" stop-color="#FFFFFF" stop-opacity="0.10"/>
  </linearGradient>
  <filter id="{p}shadow" x="-10%" y="-10%" width="120%" height="125%" color-interpolation-filters="sRGB">
    <feGaussianBlur stdDeviation="12"/>
  </filter>
</defs>'''


def tile(size, inset=0.0, radius=0.2237, shadow=False, p='t-'):
    """A rounded glass slab of `size` with `inset` margin; returns svg body."""
    side = size - 2 * inset
    rx = side * radius
    hair = max(size / 512, 0.75)
    shape = f'x="{inset:g}" y="{inset:g}" width="{side:g}" height="{side:g}" rx="{rx:.2f}"'
    # A soft drop shadow below the slab (macOS icon grid), never on the slab.
    sh = (
        f'\n<rect {shape} fill="#000000" fill-opacity="0.35" '
        f'transform="translate(0 12)" filter="url(#{p}shadow)"/>'
        if shadow else ''
    )
    return (
        tile_defs(p)
        + sh
        + f'\n<rect {shape} fill="url(#{p}fill)"/>'
        + f'\n<rect {shape} fill="url(#{p}glow)"/>'
        + f'\n<rect x="{inset + hair / 2:.2f}" y="{inset + hair / 2:.2f}" '
        f'width="{side - hair:.2f}" height="{side - hair:.2f}" rx="{rx - hair / 2:.2f}" '
        f'fill="none" stroke="url(#{p}rim)" stroke-width="{hair:.2f}"/>'
    )


def full_bleed(size, p='b-'):
    """The tile's fill and glow without a shape (the launcher masks it)."""
    return (
        tile_defs(p)
        + f'\n<rect width="{size:g}" height="{size:g}" fill="url(#{p}fill)"/>'
        + f'\n<rect width="{size:g}" height="{size:g}" fill="url(#{p}glow)"/>'
    )


# ------------------------------------------------------------------ variants
C = 1024.0


def app_icon():
    """Master app icon: glass slab, full canvas (legacy launcher, web)."""
    s = mark_width_scale(0.60, C)
    return doc(C, C, tile(C, inset=C * 0.04) + '\n' + place('chatloom-mark.svg', C / 2, C / 2, s, 'm-'))


def macos_icon():
    """macOS Big Sur grid: 824 slab at 100, soft shadow, mark at 60 % of the slab."""
    s = mark_width_scale(0.60, 824)
    body = tile(C, inset=100, radius=0.2250, shadow=True)
    return doc(C, C, body + '\n' + place('chatloom-mark.svg', C / 2, C / 2 - 4, s, 'm-'))


# Adaptive icons are 108 dp; launchers show at least the central 72 dp
# (a circle mask may cut everything outside a 72 dp circle).
ADAPTIVE = 108.0


def adaptive_scale():
    # The tail tip may touch the 66 dp safe circle; the bubbles stay well inside.
    return mark_reach_scale(32.0)


def adaptive_foreground():
    return doc(ADAPTIVE, ADAPTIVE, place('chatloom-mark.svg', 54, 54, adaptive_scale(), 'm-'))


def adaptive_background():
    return doc(ADAPTIVE, ADAPTIVE, full_bleed(ADAPTIVE))


def adaptive_monochrome():
    return doc(ADAPTIVE, ADAPTIVE, place('chatloom-mark-flat.svg', 54, 54, adaptive_scale(), 'f-', WHITE))


def notification():
    """Status bar icon: white silhouette in a 24 dp box with a 1 dp margin."""
    s = mark_width_scale(22 / 24, 24)
    return doc(24, 24, place('chatloom-mark-flat.svg', 12, 12, s, 'f-', WHITE))


# Both splash images draw the mark at the same size (about 119 dp wide), so
# Android 12+ hands over from the system splash to the launch window without
# a jump.
SPLASH_REACH = 76.0


def splash_legacy():
    """Pre-12 launch image, drawn centred on the dark window background."""
    return doc(160, 160, place('chatloom-mark.svg', 80, 80, mark_reach_scale(SPLASH_REACH), 'm-'))


def splash_android12():
    """Android 12 splash icon: 240 dp, content inside the 160 dp circle."""
    return doc(240, 240, place('chatloom-mark.svg', 120, 120, mark_reach_scale(SPLASH_REACH), 'm-'))


def web_maskable():
    """Maskable PWA icon: full-bleed slab, mark inside the 80 % safe circle."""
    return doc(C, C, full_bleed(C) + '\n' + place('chatloom-mark.svg', C / 2, C / 2, mark_reach_scale(C * 0.36), 'm-'))


def in_app(name, color=None):
    """Mark with a small margin on a square canvas (Image.asset in the app)."""
    s = mark_width_scale(0.88, C)
    return doc(C, C, place(name, C / 2, C / 2, s, 'a-', color))


def favicon():
    s = mark_width_scale(1.0, C)
    return doc(C, C, place('chatloom-mark-flat.svg', C / 2, C / 2, s, 'f-'))


def source(name):
    return (BRAND / name).read_text()


# -------------------------------------------------------------------- render
def find_renderer():
    if shutil.which('rsvg-convert'):
        return 'rsvg'
    if shutil.which('ffmpeg'):
        out = subprocess.run(['ffmpeg', '-hide_banner', '-decoders'], capture_output=True, text=True).stdout
        if 'librsvg' in out:
            return 'ffmpeg'
    try:
        import cairosvg  # noqa: F401
        return 'cairosvg'
    except ImportError:
        pass
    raise SystemExit('No SVG renderer: install librsvg (rsvg-convert), ffmpeg with librsvg or `pip install cairosvg`.')


def render(renderer, svg_text, out, w, h=None):
    h = h or w
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile('w', suffix='.svg', delete=False) as f:
        f.write(svg_text)
        src = Path(f.name)
    try:
        if renderer == 'rsvg':
            subprocess.run(['rsvg-convert', '-w', str(w), '-h', str(h), '-o', str(out), str(src)], check=True)
        elif renderer == 'ffmpeg':
            subprocess.run(
                ['ffmpeg', '-v', 'error', '-y', '-width', str(w), '-height', str(h), '-keep_ar', '0',
                 '-i', str(src), '-pix_fmt', 'rgba', '-frames:v', '1', str(out)],
                check=True,
            )
        else:
            import cairosvg
            cairosvg.svg2png(url=str(src), write_to=str(out), output_width=w, output_height=h)
    finally:
        src.unlink()


def png_size(path):
    with open(path, 'rb') as f:
        head = f.read(24)
    if head[:8] != b'\x89PNG\r\n\x1a\n':
        return None
    return struct.unpack('>II', head[16:24])


def jobs():
    """(svg text, repository path, width, height) for every raster."""
    out = []

    def add(svg_text, path, w, h=None):
        out.append((svg_text, path, round(w), round(h or w)))

    mark, flat = source('chatloom-mark.svg'), source('chatloom-mark-flat.svg')
    icon = app_icon()

    # Brand pack.
    add(mark, 'docs/brand/chatloom-mark-1024.png', 1024)
    add(source('chatloom-social.svg'), 'docs/brand/chatloom-social-1280x640.png', 1280, 640)

    # In-app logo: glass mark and a white silhouette the app tints.
    add(in_app('chatloom-mark.svg'), 'assets/logo/chatloom-mark.png', 512)
    add(in_app('chatloom-mark-flat.svg', WHITE), 'assets/logo/chatloom-mark-flat.png', 512)

    # Android.
    fg, bg, mono = adaptive_foreground(), adaptive_background(), adaptive_monochrome()
    note, splash, splash12 = notification(), splash_legacy(), splash_android12()
    for d, k in DENSITIES.items():
        add(icon, f'{RES}/mipmap-{d}/ic_launcher.png', 48 * k)
        add(fg, f'{RES}/drawable-{d}/ic_launcher_foreground.png', 108 * k)
        add(bg, f'{RES}/drawable-{d}/ic_launcher_background.png', 108 * k)
        add(mono, f'{RES}/drawable-{d}/ic_launcher_monochrome.png', 108 * k)
        add(note, f'{RES}/drawable-{d}/notifications_icon.png', 24 * k)
        add(splash, f'{RES}/drawable-{d}/splash.png', 160 * k)
        add(splash12, f'{RES}/drawable-{d}/splash_icon.png', 240 * k)
    page = doc(1, 1, f'<rect width="1" height="1" fill="{PAGE}"/>')
    for d in ('drawable', 'drawable-v21', 'drawable-night', 'drawable-night-v21'):
        add(page, f'{RES}/{d}/background.png', 1)

    # macOS (Contents.json names).
    mac = macos_icon()
    for n in (16, 32, 64, 128, 256, 512, 1024):
        add(mac, f'{MAC}/app_icon_{n}.png', n)

    # Web.
    fav = favicon()
    add(fav, 'web/favicon.png', 16)
    for n in (16, 32, 48):
        add(fav, f'web/icons/Icon-{n}.png', n)
    for n in (192, 512):
        add(icon, f'web/icons/Icon-{n}.png', n)
        add(web_maskable(), f'web/icons/Icon-maskable-{n}.png', n)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--check', action='store_true', help='render to a temporary directory and compare sizes')
    args = ap.parse_args()
    renderer = find_renderer()
    target = Path(tempfile.mkdtemp(prefix='chatloom-icons-')) if args.check else ROOT

    if not args.check:
        (BRAND / 'chatloom-app-icon.svg').write_text(app_icon())

    todo = jobs()
    for svg_text, rel, w, h in todo:
        render(renderer, svg_text, target / rel, w, h)

    bad = 0
    for _, rel, w, h in todo:
        got = png_size(target / rel)
        if got != (w, h):
            print(f'size mismatch {rel}: {got} != {(w, h)}', file=sys.stderr)
            bad += 1
        elif args.check and not (ROOT / rel).exists():
            print(f'missing in repository: {rel}', file=sys.stderr)
            bad += 1
    if args.check:
        shutil.rmtree(target)
    print(f'{"checked" if args.check else "rendered"} {len(todo)} files with {renderer}')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())

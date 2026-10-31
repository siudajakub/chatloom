#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Rebuild the ChatLoom brand source SVGs in docs/brand/.

The mark is two round speech bubbles of glass: a cyan one behind, a
Messenger-blue one in front at 88 % opacity, and a bright lens where they
overlap (two networks woven into one conversation). This script writes the
vector sources; scripts/brand/generate-icons.py turns them into every
raster in the repository.

Only needed when the geometry, colours or wordmark change. It converts text
and the flat silhouette to plain paths, so it needs three packages that the
icon generator does not:

    python3 -m venv /tmp/brand-venv
    /tmp/brand-venv/bin/pip install fonttools uharfbuzz skia-pathops
    /tmp/brand-venv/bin/python scripts/brand/build-sources.py

Outputs (docs/brand/): chatloom-mark.svg, chatloom-mark-flat.svg,
chatloom-wordmark.svg, chatloom-lockup-dark.svg, chatloom-lockup-light.svg,
chatloom-social.svg.
"""

from __future__ import annotations

import math
from pathlib import Path

import pathops
import uharfbuzz as hb
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.svgLib.path import parse_path
from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'docs/brand'
FONTS = ROOT / 'assets/notion/fonts'

# Colours (docs/brand/BRAND.md lists their token sources).
BLUE = '#0A7CFF'  # NotionAccent.blue seed, the default accent
BLUE_LIGHT = '#5AA9FF'  # blue, top of the glass gradient
CYAN = '#06B6D4'  # NotionAccent.cyan seed, the cooler secondary
CYAN_LIGHT = '#67E8F9'  # cyan, top of the glass gradient
PAGE_DARK = '#191919'  # NotionColors.dark.background
TEXT_DARK = '#E8E7E5'  # NotionColors.dark.text
TEXT_DARK_2 = '#AAAAA5'  # NotionColors.dark.textSecondary
TEXT_LIGHT = '#242424'  # NotionColors.light.text

# Mark geometry in a 1024 box (y down, degrees clockwise from +x).
R = 280.0
FRONT_C = (420.0, 600.0)  # blue bubble, tail bottom-left
BACK_C = (604.0, 424.0)  # cyan bubble, tail bottom-right (mirrored)
TAIL_TIP = 130.0  # tail direction of the front bubble
TAIL_REACH = 1.24  # tip distance from the centre, in radii
TAIL_ROOT = 98.0  # where the inner edge of the tail leaves the circle
TAIL_BEND = 0.45  # concavity of the inner edge
TAIL_ROUND = 0.08  # rounding of the tip
FLAT_GAP = 34.0  # gap around the front bubble in the flat silhouette
MARK_BOX = (140.0, 144.0, 884.0, 880.0)  # visual bounds of the mark


def _pt(c, ang, r):
    a = math.radians(ang)
    return (c[0] + r * math.cos(a), c[1] + r * math.sin(a))


def _lerp(a, b, u):
    return (a[0] + (b[0] - a[0]) * u, a[1] + (b[1] - a[1]) * u)


def _f(p):
    return f'{p[0]:.1f},{p[1]:.1f}'


def bubble(c, mirror=False):
    """A round bubble whose tail is the tangent from its tip to the circle."""
    tip = _pt(c, TAIL_TIP, R * TAIL_REACH)
    a_out = TAIL_TIP + math.degrees(math.acos(1.0 / TAIL_REACH))
    p_out = _pt(c, a_out, R)
    p_in = _pt(c, TAIL_ROOT, R)
    ar = math.radians(TAIL_ROOT)
    q = (p_in[0] - math.sin(ar) * TAIL_BEND * R, p_in[1] + math.cos(ar) * TAIL_BEND * R)
    u = 1.0 - TAIL_ROUND
    q1 = _lerp(p_in, q, u)
    t_in = _lerp(q1, _lerp(q, tip, u), u)
    t_out = _lerp(tip, p_out, TAIL_ROUND * 0.9)
    pts = dict(p_out=p_out, p_in=p_in, q1=q1, t_in=t_in, tip=tip, t_out=t_out)
    if mirror:
        pts = {k: (2 * c[0] - v[0], v[1]) for k, v in pts.items()}
    sweep = 0 if mirror else 1
    return (
        f'M{_f(pts["p_out"])} A{R:.0f},{R:.0f} 0 1 {sweep} {_f(pts["p_in"])} '
        f'Q{_f(pts["q1"])} {_f(pts["t_in"])} Q{_f(pts["tip"])} {_f(pts["t_out"])} Z'
    )


FRONT = bubble(FRONT_C)
BACK = bubble(BACK_C, mirror=True)


def svg_doc(w, h, body, title='ChatLoom', view=None):
    view = view or f'0 0 {w:g} {h:g}'
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w:g}" height="{h:g}" '
        f'viewBox="{view}">\n  <title>{title}</title>\n{body}</svg>\n'
    )


def mark_defs(p='cl'):
    return f'''  <defs>
    <linearGradient id="{p}-back" x1="0.2" y1="0" x2="0.8" y2="1">
      <stop offset="0" stop-color="{CYAN_LIGHT}"/>
      <stop offset="1" stop-color="{CYAN}"/>
    </linearGradient>
    <linearGradient id="{p}-front" x1="0.2" y1="0" x2="0.8" y2="1">
      <stop offset="0" stop-color="{BLUE_LIGHT}"/>
      <stop offset="1" stop-color="{BLUE}"/>
    </linearGradient>
    <linearGradient id="{p}-lens" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#E6FBFF" stop-opacity="0.72"/>
      <stop offset="1" stop-color="#9CD2FF" stop-opacity="0.28"/>
    </linearGradient>
    <linearGradient id="{p}-sheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.55"/>
      <stop offset="0.45" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <clipPath id="{p}-back-clip"><path d="{BACK}"/></clipPath>
    <clipPath id="{p}-front-clip"><path d="{FRONT}"/></clipPath>
  </defs>
'''


def mark_body(p='cl', indent='  '):
    i = indent
    return f'''{i}<!-- Back pane: cyan glass with a top sheen and a hairline edge. -->
{i}<path d="{BACK}" fill="url(#{p}-back)"/>
{i}<g clip-path="url(#{p}-back-clip)" fill="none">
{i}  <path d="{BACK}" stroke="url(#{p}-sheen)" stroke-width="32"/>
{i}  <path d="{BACK}" stroke="#FFFFFF" stroke-opacity="0.24" stroke-width="5"/>
{i}</g>
{i}<!-- Front pane: blue glass at 88 % so the back pane shows through. -->
{i}<g opacity="0.88">
{i}  <path d="{FRONT}" fill="url(#{p}-front)"/>
{i}  <g clip-path="url(#{p}-front-clip)" fill="none">
{i}    <path d="{FRONT}" stroke="url(#{p}-sheen)" stroke-width="32"/>
{i}    <path d="{FRONT}" stroke="#FFFFFF" stroke-opacity="0.24" stroke-width="5"/>
{i}  </g>
{i}</g>
{i}<!-- Lens: where the two conversations overlap. -->
{i}<path d="{FRONT}" fill="url(#{p}-lens)" clip-path="url(#{p}-back-clip)"/>
'''


def _path(d):
    p = pathops.Path()
    parse_path(d, p.getPen())
    return p


def _union(a, b):
    return pathops.op(a, b, pathops.PathOp.UNION)


def _svg_d(path, precision=1):
    path.convertConicsToQuads()
    pen = SVGPathPen(None, ntos=lambda v: f'{round(v, precision):g}')
    path.draw(pen)
    return pen.getCommands()


def flat_mark_d():
    """Single-path silhouette: both bubbles, a gap around the front one."""
    front = _path(FRONT)
    halo = _path(FRONT)
    halo.stroke(FLAT_GAP * 2, pathops.LineCap.ROUND_CAP, pathops.LineJoin.ROUND_JOIN, 4)
    halo = _union(halo, front)
    back = pathops.op(_path(BACK), halo, pathops.PathOp.DIFFERENCE)
    return _svg_d(_union(back, _path(FRONT)))


class Font:
    def __init__(self, name):
        path = FONTS / name
        self.tt = TTFont(path)
        self.glyphs = self.tt.getGlyphSet()
        self.order = self.tt.getGlyphOrder()
        self.upem = self.tt['head'].unitsPerEm
        self.cap = self.tt['OS/2'].sCapHeight
        self.hb_font = hb.Font(hb.Face(path.read_bytes()))

    def outline(self, text, size, tracking=0.0):
        """Path data of `text` at `size` px, baseline at y=0; returns (d, width)."""
        buf = hb.Buffer()
        buf.add_str(text)
        buf.guess_segment_properties()
        hb.shape(self.hb_font, buf, {'kern': True, 'liga': True})
        k = size / self.upem
        x = 0.0
        out = pathops.Path()
        for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
            name = self.order[info.codepoint]
            glyph = pathops.Path()
            pen = TransformPen(glyph.getPen(), (k, 0, 0, -k, x + pos.x_offset * k, -pos.y_offset * k))
            self.glyphs[name].draw(pen)
            out = _union(out, glyph) if out.area else glyph
            x += pos.x_advance * k + tracking * size
        width = x - tracking * size
        self.last_bounds = out.bounds  # (xmin, ymin, xmax, ymax), y down
        return _svg_d(out, 2), width


BOLD = Font('Roboto-Bold.ttf')
REGULAR = Font('Roboto-Regular.ttf')
WORD = 'ChatLoom'
WORD_TRACKING = -0.012  # em, a touch tighter than the font's default


def wordmark(cap_height, color, x=0.0, baseline=None):
    size = cap_height * BOLD.upem / BOLD.cap
    d, width = BOLD.outline(WORD, size, WORD_TRACKING)
    baseline = cap_height if baseline is None else baseline
    g = f'<path transform="translate({x:.2f} {baseline:.2f})" fill="{color}" d="{d}"/>'
    return g, width


def lockup(text_color, prefix):
    """Horizontal lockup: mark, then the wordmark with cap height 0.42 x mark."""
    x0, y0, x1, y1 = MARK_BOX
    mark_h = 240.0
    s = mark_h / (y1 - y0)
    mark_w = (x1 - x0) * s
    cap = mark_h * 0.42
    gap = mark_h * 0.26
    centre = mark_h * 0.5
    text, text_w = wordmark(cap, text_color, x=mark_w + gap, baseline=centre + cap / 2)
    w = mark_w + gap + text_w
    pad = 8
    body = (
        mark_defs(prefix)
        + f'  <g transform="translate({-x0 * s:.3f} {-y0 * s:.3f}) scale({s:.6f})">\n'
        + mark_body(prefix, '    ')
        + '  </g>\n'
        + f'  {text}\n'
    )
    return svg_doc(
        round(w + 2 * pad), round(mark_h + 2 * pad), body,
        view=f'{-pad} {-pad} {w + 2 * pad:.1f} {mark_h + 2 * pad:.1f}',
    )


def social():
    """GitHub social preview (1280 x 640): lockup and tagline on the page."""
    W, H = 1280, 640
    x0, y0, x1, y1 = MARK_BOX
    mark_h = 168.0
    s = mark_h / (y1 - y0)
    mark_w = (x1 - x0) * s
    cap = mark_h * 0.42
    gap = mark_h * 0.26
    size = cap * BOLD.upem / BOLD.cap
    _, text_w = BOLD.outline(WORD, size, WORD_TRACKING)
    total = mark_w + gap + text_w
    left = (W - total) / 2
    top = 214.0
    text, _ = wordmark(cap, TEXT_DARK, x=left + mark_w + gap, baseline=top + mark_h / 2 + cap / 2)
    tag_size = 30.0
    tag_d, tag_w = REGULAR.outline('All your chats in one calm, private inbox.', tag_size)
    tag_y = top + mark_h + 92
    body = f'''  <defs>
    <radialGradient id="s-glow-blue" cx="0.30" cy="0.30" r="0.55">
      <stop offset="0" stop-color="{BLUE}" stop-opacity="0.30"/>
      <stop offset="1" stop-color="{BLUE}" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="s-glow-cyan" cx="0.74" cy="0.78" r="0.50">
      <stop offset="0" stop-color="{CYAN}" stop-opacity="0.22"/>
      <stop offset="1" stop-color="{CYAN}" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="s-card-rim" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.16"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0.04"/>
    </linearGradient>
  </defs>
  <rect width="{W}" height="{H}" fill="{PAGE_DARK}"/>
  <rect width="{W}" height="{H}" fill="url(#s-glow-blue)"/>
  <rect width="{W}" height="{H}" fill="url(#s-glow-cyan)"/>
  <!-- A pane of the dock's glass behind the lockup: surface at 58 %, hairline. -->
  <rect x="96" y="120" width="1088" height="400" rx="56" fill="#252525" fill-opacity="0.58"/>
  <rect x="96.5" y="120.5" width="1087" height="399" rx="55.5" fill="none" stroke="url(#s-card-rim)"/>
{mark_defs('s')}  <g transform="translate({left - x0 * s:.3f} {top - y0 * s:.3f}) scale({s:.6f})">
{mark_body('s', '    ')}  </g>
  {text}
  <path transform="translate({(W - tag_w) / 2:.2f} {tag_y:.2f})" fill="{TEXT_DARK_2}" d="{tag_d}"/>
'''
    return svg_doc(W, H, body, title='ChatLoom: all your chats in one calm, private inbox')


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'chatloom-mark.svg').write_text(svg_doc(1024, 1024, mark_defs() + mark_body()))
    flat = f'  <path fill="{BLUE}" d="{flat_mark_d()}"/>\n'
    (OUT / 'chatloom-mark-flat.svg').write_text(svg_doc(1024, 1024, flat))
    cap = 100.0
    text, w = wordmark(cap, TEXT_LIGHT, baseline=0)
    _, top, _, bottom = BOLD.last_bounds
    pad = 2.0
    h = bottom - top + 2 * pad
    (OUT / 'chatloom-wordmark.svg').write_text(svg_doc(
        round(w + 2 * pad), round(h), f'  {text}\n',
        view=f'{-pad:g} {top - pad:.1f} {w + 2 * pad:.1f} {h:.1f}'))
    (OUT / 'chatloom-lockup-dark.svg').write_text(lockup(TEXT_DARK, 'ld'))
    (OUT / 'chatloom-lockup-light.svg').write_text(lockup(TEXT_LIGHT, 'll'))
    (OUT / 'chatloom-social.svg').write_text(social())
    print(f'wrote brand sources to {OUT.relative_to(ROOT)}')


if __name__ == '__main__':
    main()

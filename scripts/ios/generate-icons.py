#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Render iOS icons from the existing ChatLoom brand; requires resvg_py and ffmpeg."""

import argparse
import json
from pathlib import Path
import runpy
import shutil
import subprocess

import resvg_py

ROOT = Path(__file__).resolve().parents[2]
ICONS = ROOT / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    options = parser.parse_args()
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        raise SystemExit('ffmpeg is required to write RGB PNGs without an alpha channel.')
    brand = runpy.run_path(str(ROOT / 'scripts/brand/generate-icons.py'))
    canvas = brand['C']
    svg = brand['doc'](
        canvas, canvas,
        brand['full_bleed'](canvas) + '\n' + brand['place'](
            'chatloom-mark.svg', canvas / 2, canvas / 2,
            brand['mark_width_scale'](0.60, canvas), 'm-',
        ),
    )
    images = json.loads((ICONS / 'Contents.json').read_text())['images']
    mismatches = []
    for image in images:
        name = image['filename']
        if Path(name).name != name:
            raise SystemExit('Icon filename must stay inside the asset catalog.')
        width, height = (float(value) for value in image['size'].split('x'))
        scale = float(image['scale'].removesuffix('x'))
        png = resvg_py.svg_to_bytes(
            svg_string=svg, width=round(width * scale), height=round(height * scale),
        )
        # The source fills the complete canvas. Strip its redundant alpha channel
        # for the iOS marketing icon requirement without changing the artwork.
        result = subprocess.run(
            [ffmpeg, '-v', 'error', '-i', 'pipe:0', '-pix_fmt', 'rgb24',
             '-frames:v', '1', '-f', 'image2pipe', '-vcodec', 'png', 'pipe:1'],
            input=png, capture_output=True, check=True,
        ).stdout
        if result[:8] != b'\x89PNG\r\n\x1a\n' or result[25] != 2:
            raise SystemExit(f'Expected an RGB PNG: {name}')
        target = ICONS / name
        if options.check:
            if not target.exists() or target.read_bytes() != result:
                mismatches.append(name)
        else:
            target.write_bytes(result)
    if mismatches:
        raise SystemExit('Out-of-date iOS icons: ' + ', '.join(mismatches))
    print(f'{"Checked" if options.check else "Rendered"} {len(images)} iOS icons from ChatLoom SVG sources.')


if __name__ == '__main__':
    main()

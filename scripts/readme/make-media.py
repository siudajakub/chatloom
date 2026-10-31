#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Turn the README frame sequences into the animated GIFs in docs/readme/.

test/readme/readme_capture_test.dart renders the app's own widgets with
fictional data and writes, per scene, PNG frames plus <scene>.json (file and
duration of every frame; identical frames are already merged). This script
scales the frames (420 px wide), builds one palette per scene with ffmpeg and writes an
optimised GIF that stays under --max-bytes, stepping down width, colours and
frame rate until it fits. It also composes docs/readme/hero.png from three
settled frames.

Needs ffmpeg and Pillow. Example (from client/):
  python3 scripts/readme/make-media.py --frames /tmp/readme-frames
  python3 scripts/readme/make-media.py --frames /tmp/readme-frames --scenes inbox chat
"""
import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:  # pragma: no cover - a hint, not a feature
    sys.exit('Pillow is required: python3 -m pip install pillow')

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'docs/readme'

# (width, colours, keep every nth frame): tried in order until a GIF fits.
LADDER = (
    (420, 256, 1),
    (390, 256, 1),
    (360, 256, 1),
    (360, 200, 1),
    (340, 160, 1),
    (320, 128, 2),
    (300, 96, 2),
)

# Frames of the hero composition: (scene, frame index; negative from the end).
HERO = (('inbox', 'home'), ('chat', 'end'), ('appearance', 'vivid'))


def shown(path):
    """A path relative to client/ when it is inside, else as given."""
    try:
        return path.resolve().relative_to(ROOT)
    except ValueError:
        return path


def load(frames_dir, scene):
    meta = json.loads((frames_dir / f'{scene}.json').read_text())
    frames = meta['frames']
    if not frames:
        raise SystemExit(f'{scene}: no frames (was README_CAPTURE_DIR set?)')
    return meta, frames


def scaled(frames_dir, frames, width, step, work):
    """Scaled PNGs and their durations; every `step`-th frame keeps the time
    of the frames it replaces, so the timing never changes."""
    out, pending = [], 0
    for index, frame in enumerate(frames):
        pending += frame['ms']
        if index % step and index != len(frames) - 1:
            continue
        image = Image.open(frames_dir / frame['file']).convert('RGB')
        height = round(image.height * width / image.width)
        image = image.resize((width, height), Image.LANCZOS)
        path = work / f'{len(out):04d}.png'
        image.save(path)
        out.append((path, pending))
        pending = 0
    if pending and out:
        path, ms = out[-1]
        out[-1] = (path, ms + pending)
    return out


def encode(frames, colours, target):
    """One palette for the whole scene, frame rectangles dithered only where
    they change (small, stable GIFs of mostly still UI)."""
    listing = target.with_suffix('.txt')
    lines = ['ffconcat version 1.0']
    for path, ms in frames:
        # GIF delays are centiseconds; keep the scene length exact.
        lines += [f"file '{path.as_posix()}'", f'duration {max(ms, 20) / 1000:.3f}']
    # The concat demuxer ignores the last duration unless the file repeats.
    lines.append(f"file '{frames[-1][0].as_posix()}'")
    listing.write_text('\n'.join(lines) + '\n')
    graph = (
        f'split[a][b];[a]palettegen=max_colors={colours}:stats_mode=full[p];'
        '[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle'
    )
    subprocess.run(
        ['ffmpeg', '-v', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', str(listing),
         '-vf', graph, '-fps_mode', 'vfr', '-loop', '0', str(target)],
        check=True,
    )
    listing.unlink()


def make_gif(frames_dir, scene, out_dir, max_bytes):
    _, frames = load(frames_dir, scene)
    target = out_dir / f'{scene}.gif'
    with tempfile.TemporaryDirectory(prefix=f'readme-{scene}-') as temp:
        work = Path(temp)
        for width, colours, step in LADDER:
            for old in work.glob('*.png'):
                old.unlink()
            scaled_frames = scaled(frames_dir, frames, width, step, work)
            candidate = work / f'{scene}.gif'
            encode(scaled_frames, colours, candidate)
            size = candidate.stat().st_size
            if size <= max_bytes or (width, colours, step) == LADDER[-1]:
                shutil.copyfile(candidate, target)
                total = sum(ms for _, ms in scaled_frames) / 1000
                print(f'{shown(target)}: {size / 1e6:.2f} MB, {width} px, '
                      f'{colours} colours, {len(scaled_frames)} frames, {total:.1f} s')
                return target
            print(f'{scene}: {size / 1e6:.2f} MB at {width} px/{colours} colours/step {step}; smaller next')
    return target


def rounded(image, radius):
    mask = Image.new('L', (image.width * 4, image.height * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, mask.width - 1, mask.height - 1), radius * 4, fill=255)
    mask = mask.resize(image.size, Image.LANCZOS)
    result = image.convert('RGBA')
    result.putalpha(mask)
    return result


def pick(frames_dir, scene, which):
    """A named frame of a scene, chosen from the recorded timeline."""
    _, frames = load(frames_dir, scene)
    index = {
        # The longest still frame: a settled screen, not a transition.
        'settled': max(range(len(frames)), key=lambda i: frames[i]['ms']),
    }.get(which)
    if index is None:
        marks = json.loads((frames_dir / f'{scene}.json').read_text()).get('marks', {})
        index = marks.get(which, len(frames) - 1)
    return Image.open(frames_dir / frames[index]['file']).convert('RGB')


def make_hero(frames_dir, out_dir, width=300, gap=28, radius=34):
    shots = []
    for scene, which in HERO:
        frame = pick(frames_dir, scene, which)
        size = (width, round(width * frame.height / frame.width))
        shots.append(rounded(frame.resize(size, Image.LANCZOS), radius))
    height = shots[0].height
    pad = 24
    canvas = Image.new('RGBA', (len(shots) * width + (len(shots) - 1) * gap + 2 * pad, height + 2 * pad), (0, 0, 0, 0))
    shadow = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
    for i, shot in enumerate(shots):
        x = pad + i * (width + gap)
        block = Image.new('RGBA', shot.size, (0, 0, 0, 90))
        block.putalpha(shot.getchannel('A').point(lambda a: a * 90 // 255))
        shadow.alpha_composite(block, (x, pad + 8))
    shadow = shadow.filter(ImageFilter.GaussianBlur(12))
    canvas.alpha_composite(shadow)
    for i, shot in enumerate(shots):
        canvas.alpha_composite(shot, (pad + i * (width + gap), pad))
    target = out_dir / 'hero.png'
    canvas.save(target, optimize=True)
    print(f'{shown(target)}: {target.stat().st_size / 1e6:.2f} MB')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--frames', type=Path, required=True, help='README_CAPTURE_DIR of the capture test')
    parser.add_argument('--out', type=Path, default=OUT)
    parser.add_argument('--scenes', nargs='*', help='Only these scenes (default: every <scene>.json)')
    parser.add_argument('--max-bytes', type=int, default=3_000_000)
    parser.add_argument('--no-hero', action='store_true')
    args = parser.parse_args()
    if shutil.which('ffmpeg') is None:
        sys.exit('ffmpeg is required')
    scenes = args.scenes or sorted(p.stem for p in args.frames.glob('*.json'))
    args.out.mkdir(parents=True, exist_ok=True)
    for scene in scenes:
        make_gif(args.frames, scene, args.out, args.max_bytes)
    if not args.no_hero and all((args.frames / f'{s}.json').is_file() for s, _ in HERO):
        make_hero(args.frames, args.out)


if __name__ == '__main__':
    main()

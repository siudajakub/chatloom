#!/usr/bin/env node
// Renders the README demo animations from the HTML mockups in scenes/.
//
//   cd docs/readme-media && npm install && node render.mjs [--gif] [scene ...]
//
// Each scene is opened in headless Chromium at 390 x 844 (2x), stepped frame
// by frame through window.__seek(t) (see kit/kit.js), and encoded with ffmpeg
// into the animated WebP the README uses. --gif also writes a GIF, which is
// handy for previews but three times larger, so it is not committed.
// Set CHROMIUM=/path/to/chrome to use a browser outside Playwright's cache.

import { chromium } from 'playwright-core';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readdirSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const FPS = 15;
const WIDTH = 360; // output width; frames are captured at 780 px and downscaled
const HOLD_MS = 1200; // pause on the last frame before the loop restarts

const args = process.argv.slice(2);
const withGif = args.includes('--gif');
const wanted = args.filter((a) => a !== '--gif');
const scenes = readdirSync(join(here, 'scenes'))
  .filter((f) => f.endsWith('.html'))
  .map((f) => basename(f, '.html'))
  .filter((n) => wanted.length === 0 || wanted.includes(n));

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || undefined });
try {
  for (const name of scenes) await render(name);
} finally {
  await browser.close();
}

async function render(name) {
  const frames = mkdtempSync(join(tmpdir(), `readme-${name}-`));
  const page = await browser.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  await page.goto(pathToFileURL(join(here, 'scenes', `${name}.html`)).href);
  await page.evaluate(() => document.fonts.ready);
  const duration = await page.evaluate(() => window.__duration);
  const count = Math.ceil((duration / 1000) * FPS);
  for (let i = 0; i <= count; i++) {
    await page.evaluate((t) => window.__seek(t), (i * 1000) / FPS);
    await page.screenshot({ path: join(frames, `f${String(i).padStart(4, '0')}.png`) });
  }
  await page.close();

  const input = ['-y', '-loglevel', 'error', '-framerate', String(FPS), '-i', join(frames, 'f%04d.png')];
  const hold = `tpad=stop_mode=clone:stop_duration=${HOLD_MS / 1000}`;
  const scale = `scale=${WIDTH}:-1:flags=lanczos`;
  const webp = join(here, `${name}.webp`);
  const gif = join(here, `${name}.gif`);
  execFileSync('ffmpeg', [...input, '-vf', `${hold},${scale}`, '-c:v', 'libwebp_anim', '-lossless', '0',
    '-quality', '72', '-compression_level', '6', '-loop', '0', webp]);
  if (withGif) {
    execFileSync('ffmpeg', [...input, '-vf',
      `${hold},${scale},split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle`,
      '-loop', '0', gif]);
  }
  rmSync(frames, { recursive: true, force: true });
  const kb = (f) => `${Math.round(statSync(f).size / 1024)} KB`;
  console.log(`${name}: ${count + 1} frames, webp ${kb(webp)}${withGif ? `, gif ${kb(gif)}` : ''}`);
}

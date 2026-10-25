# README demo animations

The animated WebP files in this folder are the demos shown in the main
[README](../../README.md). They are **mockups**: HTML pages in `scenes/` that
copy the Notion dark v2 look (tokens from [DESIGN.md](../../DESIGN.md), the
app's Roboto fonts and pinned-chat artwork). They are not recordings of the
app. Every name, avatar, message and sticker is made up. No account, contact
or real chat data is involved.

| File | Shows |
|---|---|
| `inbox.webp` | Unified inbox, network filter in the floating dock |
| `round-transcribe.webp` | Telegram round video playback and voice-message transcription |
| `gifs-stickers.webp` | GIF search and a sticker pack in the composer panel |
| `send-later.webp` | Send later and Remind me |
| `appearance.webp` | Accent colours, intensity and text size |

## Regenerate

You need Node 20+ and ffmpeg built with libwebp.

```sh
cd docs/readme-media
npm install
npx playwright-core install chromium   # or set CHROMIUM=/path/to/chrome
node render.mjs                        # all scenes
node render.mjs --gif inbox            # one scene, plus a GIF preview
```

`render.mjs` opens each scene in headless Chromium at 390 × 844 (2×). It steps
through the scene frame by frame at 15 fps and encodes 360 px wide animated
WebP with ffmpeg. The last frame is held for 1.2 s.

## Writing a scene

A scene is one HTML file. It links `../kit/kit.css`, loads `../kit/kit.js`, and
declares its timeline:

```js
scene(9000, [
  [900,  () => tap('#netseg')],                  // finger tap on an element
  [1150, () => $('#sheet').classList.add('open')],
]);
type('#field', 'Hello!', 2000);                   // typing, 16 chars/s
during(3000, 1500, (p) => { /* p goes 0 → 1 */ });
```

`kit.js` pauses every CSS transition and animation and seeks it to the virtual
time of the frame. Scenes therefore render the same way on every run, and they
must not use timers or `requestAnimationFrame`. Keep animated areas small:
large moving gradients make the WebP files much bigger.

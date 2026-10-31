# ChatLoom brand

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="chatloom-lockup-dark.svg">
    <img src="chatloom-lockup-light.svg" width="360" alt="ChatLoom">
  </picture>
</p>

The mark is two round speech bubbles made of glass. A cyan bubble sits
behind and a Messenger-blue bubble sits in front. The front pane is 88 %
opaque, so the back one shows through it. Where the two overlap, a bright
lens forms: two networks woven into one conversation. The style follows the
app's glass language from [`DESIGN.md`](../../DESIGN.md): translucent panes,
a soft top sheen, a hairline edge and rounded shapes with no square corners.

## Files

| File | What it is | Use it for |
|---|---|---|
| [`chatloom-mark.svg`](chatloom-mark.svg) | Glass mark, transparent, 1024 box | in-app logo, README, documents, anything at 24 px or more |
| [`chatloom-mark-1024.png`](chatloom-mark-1024.png) | The same mark as a PNG | tools that cannot read SVG |
| [`chatloom-mark-flat.svg`](chatloom-mark-flat.svg) | One path, one colour (`#0A7CFF`) | monochrome uses, favicons, notification and themed icons (recolour to white), stamps, embossing |
| [`chatloom-wordmark.svg`](chatloom-wordmark.svg) | "ChatLoom" in Roboto Bold, converted to outlines, `#242424` | text-only placements on light backgrounds |
| [`chatloom-lockup-dark.svg`](chatloom-lockup-dark.svg) | Mark and wordmark, text `#E8E7E5` | dark backgrounds (the default) |
| [`chatloom-lockup-light.svg`](chatloom-lockup-light.svg) | Mark and wordmark, text `#242424` | light backgrounds |
| [`chatloom-app-icon.svg`](chatloom-app-icon.svg) | Mark on the glass slab (generated) | legacy Android launcher, web icons, store or press pages |
| [`chatloom-social.svg`](chatloom-social.svg), [`chatloom-social-1280x640.png`](chatloom-social-1280x640.png) | GitHub social preview, dark | repository Settings → Social preview |
| [`concepts/`](concepts/) | The two concepts that were not chosen, and a comparison sheet | history |

All text in the SVGs is converted to outlines, so no font is needed to view
them. The wordmark uses Roboto Bold (Apache-2.0, bundled in
`assets/notion/fonts/`) with −1.2 % tracking.

## Colours

| Role | Hex | Source |
|---|---|---|
| Front pane, flat mark | `#0A7CFF` | `NotionAccent.blue` seed, the default accent (`lib/ui/notion/notion_appearance.dart`) |
| Back pane | `#06B6D4` | `NotionAccent.cyan` seed, the cooler secondary |
| Pane highlights (top of each gradient) | `#5AA9FF`, `#67E8F9` | blue and cyan lifted toward white; logo only |
| Lens | `#E6FBFF` at 72 % → `#9CD2FF` at 28 % | logo only |
| Sheen, hairline | white, 55 % → 0 %; white 24 % | the glass hairline (`NotionGlass` border is white 10 %) |
| Dark page | `#191919` | `background` (dark) |
| Dark surface | `#252525` | `surface` (dark); the social card is this at 58 %, the dock tint |
| Text on dark | `#E8E7E5`, `#AAAAA5` | `text`, `textSecondary` (dark) |
| Light page, text on light | `#FAF9F6`, `#242424` | `background`, `text` (light) |
| App icon slab | `#2B2B2B` → `#151515`, `#0A7CFF` glow at 30 % | the dark surface lifted at the top and the page deepened at the bottom; icon only |

The mark keeps its blue and cyan whatever accent a user picks in Settings →
Appearance. The accent changes the app, not the brand.

## Construction

- 1024 × 1024 box. The visual bounds of the mark are x 140–884, y 144–880
  (744 × 736), centred on the box.
- Both bubbles are circles of radius 280. The back bubble's centre is at
  (604, 424) and the front bubble's centre is at (420, 600). Each bubble has
  one tail corner: bottom-left on the front bubble, mirrored to bottom-right
  on the back one. The outer edge of each tail is tangent to its circle. The
  inner edge is concave, and the tip is slightly rounded.
- Each pane has a diagonal gradient (highlight → seed), a 32-unit inner sheen
  at the top and a 5-unit hairline, both clipped to the pane.
- The flat mark is the union of both bubbles. It has a 34-unit gap around the
  front bubble, which keeps the two shapes apart at 16 px.

To change the geometry, edit `scripts/brand/build-sources.py`. It writes
every SVG listed above except the app icon.

## Clear space and minimum size

- Clear space: keep at least **¼ of the mark's height** free on every side of
  the mark or lockup. Nothing else goes there: no text, edges or other logos.
- Minimum sizes:
  - glass mark: 24 px (on screen) or 8 mm (in print);
  - flat mark: 16 px;
  - lockup: 120 px wide, which makes the mark 30 px tall.
  - Below these sizes, use the flat mark alone.
- In a lockup, the wordmark's cap height is 0.42 × the mark's height. The gap
  between the mark and the wordmark is 0.26 × the mark's height. The
  wordmark is centred vertically on the mark. Do not rebuild the lockup by
  hand; use the lockup files.

## Do

- Use the glass mark on the page colours (`#191919`, `#FAF9F6`) or on any
  calm dark or light surface.
- Use the flat mark, recoloured to one colour, wherever only one colour can
  be shown: white on dark, `#191919` on light, or the blue on white.
- Use the lockup files as they are, and pick dark or light by the background.
- On a photo or a busy background, use the app icon (the mark on its slab).

## Don't

- Don't recolour the glass mark, swap the bubbles, or follow the user's
  accent.
- Don't add shadows, outlines, glows or effects to the mark. The macOS icon
  shadow belongs to the platform grid, not to the mark.
- Don't stretch, rotate or skew it, and don't change the overlap.
- Don't set "ChatLoom" in another typeface. Don't colour half of the
  wordmark.
- Don't place the glass mark on mid-tone blue or cyan, where the panes
  disappear. Use the flat mark in white instead.
- Don't crop the tails. The flat mark's gap must stay open.

## Where it is used

| Place | File(s) | Built from |
|---|---|---|
| Intro, login (Hero), About dialog | `assets/logo/chatloom-mark.png` (`AppConfig.logoAsset`) | glass mark |
| Lock screen, empty two-column pane (tinted watermark) | `assets/logo/chatloom-mark-flat.png` (`AppConfig.logoSilhouetteAsset`) | flat mark, white |
| Android launcher (API 26+) | `mipmap-anydpi-v26/ic_launcher.xml` → `drawable-*/ic_launcher_{background,foreground,monochrome}.png` | slab fill; glass mark inside the 66 dp safe circle; flat mark (themed icons) |
| Android launcher (legacy), shortcuts | `mipmap-*/ic_launcher.png` | app icon |
| Android notifications, push setup service | `drawable-*/notifications_icon.png`; manifest meta-data `pl.personal.chatloom.notification_icon` and Firebase's default icon | flat mark, white, 22 dp of 24 |
| Android 12+ splash | `values{,-night}-v31/styles.xml` → `drawable-*/splash_icon.png` on `#191919` | glass mark inside the 160 dp circle of a 240 dp icon |
| Android splash before 12 | `drawable*/launch_background.xml` → `splash.png` on `background.png` | glass mark |
| macOS | `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png` | 824 slab on the 1024 grid, soft shadow |
| Web | `web/favicon.png`, `web/icons/Icon-{16,32,48}.png` (flat); `Icon-{192,512}.png` (app icon); `Icon-maskable-*.png` | flat mark, app icon, full-bleed slab |
| README | `docs/brand/chatloom-mark.svg` | glass mark |
| GitHub social preview | `docs/brand/chatloom-social-1280x640.png` (upload it in the repository settings) | lockup, tagline |

## Regenerating

Every raster comes from the SVGs above:

```sh
python3 scripts/brand/generate-icons.py          # writes all PNGs and chatloom-app-icon.svg
python3 scripts/brand/generate-icons.py --check  # renders to a temp dir, checks sizes
```

The script needs only Python 3 and one SVG renderer. It uses the first one
it finds: `rsvg-convert` (librsvg), `ffmpeg` built with librsvg, or the
`cairosvg` Python package. Rebuilding the SVG sources themselves
(`scripts/brand/build-sources.py`) also needs `fonttools`, `uharfbuzz` and
`skia-pathops` in a virtual environment; see the script's header. The project
does not use `flutter_launcher_icons` or `flutter_native_splash`.

## Concepts

Three directions were drawn and checked at 1024, 192, 48 and 24 px on
`#191919` and `#FAF9F6` ([`concepts/concepts.png`](concepts/concepts.png)).

- **A: glass duo (chosen).** Two filled glass bubbles with a bright lens.
  It has the strongest silhouette at 24–48 px, because filled shapes survive
  where outlines thin out. It shows the glass of the app's dock most
  directly. It has two shapes and two token colours. Its flat version still
  reads as two bubbles at 16 px. The overlap carries the loom idea without
  drawing threads.
- **B: woven rings** ([`concept-b-woven-rings.svg`](concepts/concept-b-woven-rings.svg)).
  This is the previous logo's idea redrawn as glass tubing: two bubble rings
  passing over and under each other. It tells the loom story most
  literally. Below 48 px it reads as a chain link, and the over/under gaps
  turn into noise in the notification icon.
- **C: thread loop** ([`concept-c-thread-loop.svg`](concepts/concept-c-thread-loop.svg)).
  One glass thread loops into a bubble and crosses itself at the tail. It is
  the most minimal of the three. The crossing disappears below 48 px, and
  the outline reads as the letter P.

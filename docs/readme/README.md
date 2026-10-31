# README media

The animations and the hero image in the main [README](../../README.md) are
**recordings of the app's own Flutter widgets**, not mockups. A widget test
pumps the production screens (inbox page and rows, the floating dock and its
network menu, swipe actions, the merged conversation page with the real
message rows, long-press menu, composer and sticker panel, the Appearance
page, the settings presenters) on a 412 × 915 phone viewport (Pixel 7/8
size), drives them with real gestures (taps, long-press, swipes, typing) and
records every frame of their real animation timelines. A small script turns
the frames into GIFs.

Everything on screen is fictional: offline fixtures with made-up people and
messages, letter avatars, and a photo and stickers drawn in code. No account,
server, network or real chat is involved. The status bar, home indicator and
the translucent finger circle are drawn by the capture host around the app;
everything inside the screen is the app.

| File | Scene in `test/readme/readme_capture_test.dart` |
|---|---|
| `inbox.gif` | Inbox with network badges, unread counts and pins; the dock's network menu filters to Telegram and back |
| `swipe.gif` | Inbox swipe actions: swipe right marks read, swipe left archives (the row flies off, the list closes the gap) |
| `chat.gif` | A merged WhatsApp + Telegram conversation (reply, photo, reactions); long-press opens the reaction menu and a reaction lands; a double tap reacts with a burst |
| `voice.gif` | Tap *Transcribe* on a voice note; the transcript shimmers in |
| `send.gif` | The composer's network chip switches the reply to Telegram; typing morphs the mic into send; the new bubble arrives |
| `stickers.gif` | The composer panel: emoji, then a sticker pack; a tapped sticker lands in the chat |
| `appearance.gif` | Settings → Appearance: intensity and accent re-theme the whole app live |
| `privacy.gif` | Settings → Privacy & security: Incognito and the receipts/typing switches |
| `hero.png` | Three settled frames from the scenes above, with rounded corners |

## Regenerate

From `client/`, with the pinned Flutter toolchain (see
[DEVELOPMENT.md](../DEVELOPMENT.md)), `ffmpeg` and Pillow:

```sh
export README_CAPTURE_DIR=/tmp/readme-frames   # any empty directory
python3 scripts/flutter-queue.py --timeout 3600 test test/readme/readme_capture_test.dart
python3 scripts/readme/make-media.py --frames "$README_CAPTURE_DIR"
```

One scene only: `python3 scripts/flutter-queue.py test --plain-name 'readme inbox'
test/readme/readme_capture_test.dart`, then `make-media.py --frames … --scenes
inbox --no-hero`.

- The test writes `<scene>/NNNN.png` frames at 2× (824 × 1830) and
  `<scene>.json` with the duration of each frame. Identical consecutive frames
  are merged, so still stretches cost one frame. Without `README_CAPTURE_DIR`
  the scenes still run as a smoke test and write nothing.
- `make-media.py` scales the frames to 360 px wide (Lanczos), builds one
  palette per scene with ffmpeg and dithers only the changed rectangle of each
  frame. A GIF over 3 MB is re-encoded narrower, with fewer colours or every
  second frame until it fits; scene timing never changes.
- Glass is forced on (`NotionGlassScope(mode: on)`), as in the production
  capture goldens, because the test renderer is not Impeller. Fonts are the
  bundled Roboto and Material Icons; emoji use the machine's Noto Color Emoji
  (or Apple Color Emoji on a Mac) when it is installed.
- What is fixture, not app: the inbox scenes feed `NotionInboxPage`,
  `NotionInboxRow` and `NotionSwipeAction` from a list instead of the Matrix
  inbox adapter (network filtering and the swipe sides are wired as in
  `chat_list.dart`); the privacy scene composes `NotionPrivacyPreferences` and
  `NotionSettingsToggle` like `SettingsSecurityView` (that view needs the app
  lock and the router); transcripts and sent messages are answered by the
  fixture's `PersonalClient` instead of the worker and the server. The
  conversation, menu, composer, sticker panel and Appearance page are the
  production widgets with fake rooms. The Linux test host would show the
  desktop composer, so `PlatformInfos.debugPlatformCanRecord` turns on the
  phone's voice mic.
- Look at the frames before you commit new GIFs: a changed GIF is a visual
  change of the README.

Text is set in the bundled Roboto (Apache-2.0); emoji in the images are
[Noto Color Emoji](https://github.com/googlefonts/noto-emoji) glyphs (SIL Open
Font License 1.1).

Messages in the conversation scenes are dated today, so no day chip shows an
old date; the long-press menu's caption shows the full date of the run. The renderer's text antialiasing differs slightly between Linux and
macOS hosts; regenerate all scenes on one machine.

# ChatLoom on macOS

The private macOS client shares the Android client's Matrix transport, E2EE,
SQLCipher store, private metadata sync, durable outbox and worker integration.
System notifications, notification sounds, Dock badges and push registration
are disabled on macOS. Reminders and scheduled messages remain in Tools; the
worker continues to execute accepted jobs independently of the app.
Voice and video calls are not supported (removed 2026-10-22).

## Build and download

The `Personal macOS` GitHub Actions workflow builds the Apple Silicon (arm64)
package on the standard `macos-15` runner with Flutter 3.47.4 and Xcode 26.3.
Intel Macs are not supported: `scripts/macos/build.py` refuses an x86_64 host. It runs desktop regressions and an
account-free native smoke test before building the release application. The
smoke test exercises vodozemac initialization, Keychain write/read/delete and
SQLCipher persistence, including rejection of a wrong key without changing the
database. It also loads synthetic Opus/CAF audio and H.264/AAC video through the
real native players, without playing sound. It creates and removes only its own
random synthetic fixtures.

Android and macOS share the `main` branch, `lib/` and `packages/`. Native projects
stay in `android/` and `macos/`; build helpers are grouped under `scripts/android/`
and `scripts/macos/`. The native smoke suite and its synthetic fixtures live in
`integration_test/macos/`.

Pushes to `main` run this workflow when build inputs change. The
workflow also supports `workflow_dispatch` once registered on the repository's
default branch. Runs have a 45-minute limit; the native smoke step has a
20-minute limit. A newer run cancels an older run on the same branch. Artifacts
expire after seven days. No release, store submission, installation or service
deployment happens automatically.

Open a successful workflow run and download its `ChatLoom-macos-ARM64-…`
artifact (Apple Silicon, M-series). Inside it are the application ZIP, `manifest.json` and `SHA256SUMS`. The manifest
records the commit, actual executable architectures, version, native smoke-test
result and ZIP digest. Every embedded Mach-O image must contain those same
architecture slices.
The package contains only arm64 code. The smoke suite exercises P-256 key
agreement.

Extract the application ZIP with Archive Utility and copy `Personal Chat.app`
to Applications. Its visible name is ChatLoom; the existing bundle identifier
`pl.personal.chat` and bundle filename remain stable. Do not delete an existing
installation's application data, Keychain items or Matrix devices.

The artifact has an ad-hoc signature verified by `codesign`. It is not Apple
notarized. macOS may require explicit approval in System Settings → Privacy &
Security on the first launch. Developer ID signing and notarization require the
owner's Apple certificate and notary credentials; this workflow does not
request, export or upload those credentials.

For a local Mac build, use the project's isolated Flutter SDK and run:

```sh
rtk python3 scripts/macos/build.py --smoke-test
rtk python3 scripts/macos/build.py
```

The script requires full Xcode and 10 GiB free disk space. It uses a temporary
Xcode signing override, preserves sandbox permissions and restores the original
entitlement files. It does not install the app. Linux can run the shared tests
but cannot compile this macOS target.

## Desktop behavior

- The first window uses a desktop size bounded by the screen. Later launches
  restore its saved frame. The minimum is 720 × 520 points; the existing layout
  switches to two columns above its shared width breakpoint.
- The app draws under a transparent title bar (Telegram for macOS): the glass
  headers reach under the traffic lights and their rows sit below them. The
  native side reports the title-bar height over `pl.personal.chat/window`
  (0 in full screen); the window's appearance follows the app theme, not the
  system setting. There is no window tabbing.
- Closing the red window button or Cmd+W keeps the process and Matrix sync
  alive. Clicking the Dock icon reopens the same window. Cmd+Q exits the
  process; messages synchronize again after reopening it.
- Menus: Edit has only Undo, Redo, Cut, Copy, Paste, Delete, Select All and
  Find…; Window has Close (Cmd+W); Help → Keyboard Shortcuts (Cmd+/).
- Typing while a message or the inbox has focus writes in the open chat's
  composer. Esc works like Back (cancels a reply or edit, closes the emoji
  panel or thread, then closes the chat); Esc in another field stays there.
- Cmd+Return always sends. Cmd+Shift+A archives the open chat, Cmd+Shift+U
  marks it unread (or read). Merged person chats accept dropped files, Cmd+V
  media, Up to edit the last message and Esc, like ordinary chats.
- Cmd+V of a copy that lists text before its image (Numbers, Excel, Word)
  pastes the text; files from Finder and copied images attach.
- Right click opens what a long press opens (who reacted, the pinned list,
  sticker and GIF previews, the playback speed list); custom tap targets show
  the pointer cursor.
- Cmd+K and Cmd+F open the inbox search, including with focus in the chat
  composer. Cmd+, and the native Settings menu open settings. The app lock
  blocks these commands. Repeated search commands reuse the open search flow.
- Existing Enter/Shift+Enter, Escape, text editing, pointer context actions,
  trackpad scrolling, file selection and desktop split navigation are retained.
- The native wake event restarts the existing clients' sync requests after
  sleep. It creates no extra account or database connection.

## Storage and media

All secure-storage consumers use the same macOS login Keychain options. This
uses the platform's Keychain without Keychain Sharing or a provisioning profile,
as supported by `flutter_secure_storage`. Its service is scoped to
`pl.personal.chat`, separating it from other Flutter applications. The smoke
test verifies isolation from the plugin's default service. Android and iOS storage options stay
unchanged. SQLCipher's existing key-preservation and fail-closed behavior stay
in force. No app data, existing keys or sessions are reset by this change. An
old installation using another Keychain namespace requires explicit recovery;
an inaccessible encrypted database must never receive a newly generated key.

Voice recording uses AAC in M4A on macOS: the pinned recorder writes Opus in
CAF, which cannot be advertised as an Ogg attachment. Incoming Ogg voice messages
use the existing Opus-to-CAF remuxer before the native Apple player loads them.
macOS has camera and microphone usage descriptions and the corresponding
sandbox entitlements.

Telegram round capture uses AVFoundation with a Flutter texture preview,
pause/resume segments, review, trimming and camera selection outside recording.
Export crops to a square, masks the corners, and validates H.264/AAC, dimensions,
duration, byte budget and the MP4 fast-start atom order. Its thumbnail and all
intermediate files stay inside the existing locked private media lease. Cancel
waits for the native writer/exporter before Dart releases the lease. Source
authorization, encryption and durable sending use the existing shared service.
Reaching a native limit, losing application focus or an interruption goes to
review and never sends by itself. Zoom and torch are unavailable on this desktop backend; camera
switching during recording is disabled.

## Acceptance on the owner's Mac

A green workflow proves compilation and its synthetic checks. The following
checks require a real Mac/account and remain **NOT RUN** until observed:

| Area | Required check |
|---|---|
| Startup and persistence | Launch, log in/recover in the app, quit/reopen, preserve Keychain and encrypted history |
| Networks and E2EE | Known old and recent messages on every needed bridge, encrypted media, existing recovery |
| Messaging | Send/reply/react/edit/delete to an owner-designated recipient; offline outbox and reconnect |
| Private features | Merge and source switching, drafts, bookmarks, organization and private sync with the phone |
| Worker | Manual/automatic transcription policy and results; scheduled messages and reminders in Tools |
| Media | Voice capture/playback/seek, video and round playback, attachments, downloads, clipboard and file drag/drop |
| Native round capture | Camera/mic allow/deny, cancel, pause/resume, trim, 60-second limit, A/V sync and Telegram delivery |
| Desktop lifecycle | Resize, two columns, native menus, shortcuts, close/Dock reopen, sleep/wake and app lock |
| Performance | Cold/warm startup, long inbox/history scroll, CPU/RAM at idle, media, sleep/wake and energy use |

Use the existing opt-in numeric performance probe for a profile build:

```sh
rtk python3 scripts/flutter-queue.py flutter run -d macos --profile --dart-define=PERSONAL_PERFORMANCE_PROBE=true
```

The probe records timing numbers and fixed phase labels. Record Mac model,
macOS version, architecture and app commit alongside measurements. Synthetic
desktop screenshots and CI timings do not establish real-account memory,
energy use or end-to-end bridge delivery.

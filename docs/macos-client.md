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
artifact (Apple Silicon, M-series). Inside it are the application DMG and ZIP, `manifest.json` and `SHA256SUMS`.
The manifest records the commit, actual executable architectures, version,
native smoke-test result and the DMG and ZIP digests. Every embedded Mach-O image must contain those same
architecture slices.
The package contains only arm64 code. The smoke suite exercises P-256 key
agreement.

Open the DMG and drag `ChatLoom.app` onto the Applications shortcut next to
it, replacing an older copy when Finder asks; then eject the disk image. A DMG
cannot copy itself, so this one drag is the install step. The ZIP is the same
app for Archive Utility. When `--sign-identity` is used, the DMG is signed with
the same certificate. The bundle identifier `pl.personal.chat` stays unchanged, so
the app keeps its sandbox data, Keychain items and Matrix session. Builds
before 25 October 2026 were named `Personal Chat.app`: after `ChatLoom.app`
opens with your account, move the old bundle to the Trash so Launchpad and
Spotlight show one app. Removing the bundle does not remove its data. Do not
delete an existing installation's application data, Keychain items or Matrix
devices.

The CI artifact is signed with the owner's stable self-signed certificate
when the repository has the `CHATLOOM_MACOS_SIGNING_P12` secret (see below);
otherwise it falls back to an ad-hoc signature and the run shows a warning.
Either signature is verified by `codesign`. It is not Apple notarized. macOS may require explicit approval in System Settings → Privacy &
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

### Stable local signature (no repeated Keychain prompts)

An ad-hoc signature identifies the app by its code hash, which changes with
every build. The login Keychain then treats each build as a new program and
asks for the Mac password once per stored item at startup. Signing local
release builds with one self-signed certificate keeps the app's designated
requirement stable, so "Always Allow" survives later builds.

Create the certificate once on the Mac:

1. Open Keychain Access → menu Keychain Access → Certificate Assistant →
   Create a Certificate…
2. Name: `ChatLoom Local Signing`; Identity Type: Self-Signed Root;
   Certificate Type: Code Signing. Create it in the `login` keychain.
3. Check it is listed:

   ```sh
   rtk security find-identity -p codesigning
   ```

Set its validity to ten years (Let me override defaults → Validity Period
3650): a new certificate brings the prompts back once. The certificate and
its private key stay in the Mac's login Keychain and in the CI secret below;
never put them in the repository or on the devbox. Build with it:

```sh
rtk python3 scripts/macos/build.py --sign-identity "ChatLoom Local Signing"
```

`CHATLOOM_MACOS_SIGN_IDENTITY` may be set instead of the flag. The script
re-signs the release bundle after Xcode, keeping its identifier and sandbox
entitlements, and fails if the designated requirement still pins a code hash.
The manifest's `signing` field records the identity. On the first build,
`codesign` may ask for access to the private key; choose Always Allow.

On the first launch after switching from ad-hoc to this certificate, macOS
asks for each Keychain item one last time: enter the password and choose
**Always Allow**. Existing Keychain items, sessions and data are kept. Later
builds signed with the same certificate do not ask again. If the certificate
is deleted or replaced, the prompts return once for the new one. The smoke
test stays ad-hoc signed.

#### The same certificate in CI

The `Personal macOS` workflow signs with the same certificate, so a
downloaded DMG and a local build are the same program to the Keychain. Store
it once as repository secrets:

1. Keychain Access → login → My Certificates → right-click
   `ChatLoom Local Signing` → Export… → format Personal Information Exchange
   (.p12), with a strong export password.
2. In the folder that holds `ChatLoom.p12`, upload it and delete the file.
   `test -s` stops the upload when the file is missing or empty, so a typo
   cannot store an empty secret (the build would then fall back to ad-hoc):

   ```sh
   test -s ChatLoom.p12 && base64 -i ChatLoom.p12 | rtk gh secret set CHATLOOM_MACOS_SIGNING_P12 --repo siudajakub/chatloom
   rtk gh secret set CHATLOOM_MACOS_SIGNING_P12_PASSWORD --repo siudajakub/chatloom
   rm ChatLoom.p12
   ```

   The second command asks for the export password. Then run the workflow
   and check that its summary has no ad-hoc warning and the manifest's
   `signing` field names the certificate.

A certificate with another name also needs the repository variable
`CHATLOOM_MACOS_SIGN_IDENTITY`. The workflow imports the .p12 into a
temporary keychain on the runner, re-signs the app and the DMG, and deletes
that keychain afterwards. Secrets reach only workflow runs of this
repository, not pull requests from forks. Whoever holds the .p12 can sign an
app the Keychain trusts as ChatLoom, so keep the export password private and
rotate the certificate if it leaks. The manifest's `signing` and
`designated_requirement` fields show the identity; the requirement of a CI
build must equal that of a local build (`codesign -d -r- ChatLoom.app`).

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

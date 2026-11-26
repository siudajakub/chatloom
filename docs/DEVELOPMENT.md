# Development environment

This is the generic setup for building and testing ChatLoom. Paths and hosts
are placeholders; keep your own machine names, signing material and service
credentials outside the repository.

## Toolchain

- Flutter 3.47.4 / Dart 3.13 (pinned; `pubspec.lock` is enforced). Install it
  in a directory of your choice, for example `$PERSONAL_CHAT_ROOT/spikes/toolchains/flutter-3.47.4`.
- JDK 17 and the Android SDK/NDK for Android; full Xcode for macOS builds.
- `scripts/devbox-env.sh` exports the Flutter, Android, Gradle and pub cache
  locations from `PERSONAL_CHAT_ROOT` and `PERSONAL_CHAT_RUNTIME`. Set both before
  sourcing it.

```sh
export PERSONAL_CHAT_ROOT=/path/to/project          # contains spikes/toolchains/
export PERSONAL_CHAT_RUNTIME=/path/to/runtime-cache  # SDKs, caches, build temp
source scripts/devbox-env.sh
flutter pub get --enforce-lockfile
flutter analyze lib
python3 scripts/verify-personal.py --dart "$(command -v dart)"
```

Run only one Flutter job (analyze, test, pub get, build) at a time per checkout.
`scripts/flutter-queue.py` serialises them; on a shared machine you can also wrap
heavy jobs in a lock, for example `flock -w 5400 /tmp/chatloom-heavy.lock nice -n 10 ...`.

## Build-time configuration

| Setting | How to provide it |
|---|---|
| Push gateway | `--dart-define=CHATLOOM_PUSH_GATEWAY=https://push.example.org` (origin of your `push-gateway/` deployment). No default: without it the build has no automatic push setup. |
| Firebase (Android FCM) | Your own ignored `android/app/google-services.json`. A release build without it stops unless `-Pchatloom.allowNoFirebase=true` is given. |
| Release signing | Your own ignored `android/key.properties` pointing at a keystore outside the repository (for example under `~/.local/share/personal-chat/signing/`). Back the key up privately; a lost key blocks upgrades. |
| Web crypto | `scripts/prepare-web.sh` builds the vodozemac web assets. |

Example release build:

```sh
python3 scripts/android/build.py --preflight-only
CHATLOOM_PUSH_GATEWAY=https://push.example.org python3 scripts/android/build.py
# or directly:
flutter build apk --release --target-platform android-arm64 \
  --dart-define=CHATLOOM_PUSH_GATEWAY=https://push.example.org
```

## Services

- `push-gateway/` — FCM push gateway with OpenID-verified registration; see its README.
- `worker/` — optional sync, reminders and transcription worker; see its README.
  Deploy both only to infrastructure you control, with credentials kept in
  systemd credentials or private files, never in Git.

## Tests and evidence

Unit, widget and golden tests use fictional fixtures only. They do not prove
end-to-end encryption, push delivery or native behaviour on a real account;
record those checks separately for each device and network.

## Performance snapshot

An app nobody touches should draw no frames and use ~0 % CPU.

- `test/perf/idle_frames_test.dart` is the automated gate: the main screens
  (inbox, conversation, merged conversation, chat details, settings, and the
  production inbox and chat page over fictional fixtures) must stop asking
  for frames after their entrance motion, keep no periodic timer armed and
  stay silent for ten fake minutes; with tickers off (`TickerMode`, or
  `NotionActivity` while the app is inactive) they must not draw at all.
- `scripts/android/perf-snapshot.sh [-s SERIAL] [-t SECONDS] [--perf]` measures
  the installed app on a device over an idle window: Flutter surface frames
  (SurfaceFlinger), HWUI frames (`dumpsys gfxinfo … framestats`), process CPU,
  `dumpsys meminfo` and a `dumpsys batterystats --charged` summary. Start the
  app, open the screen to measure, keep the screen on and do not touch it.
- `scripts/macos/perf-snapshot.sh [-t SECONDS]` samples the running ChatLoom
  app with `top -l` (CPU, idle wakeups, Energy Impact, memory) and prints
  `footprint` or `vmmap --summary` when available.

Both scripts print aggregate numbers only (no message content or
identifiers beyond the package or process name) and never launch, stop or
clear the app. Frame timing under interaction is covered separately by
[the benchmarks](performance-benchmarks.md).

## Performance tests

`test/perf/` is one gate that runs on Linux without a device or account
(fictional fixtures, fake time):

```sh
python3 scripts/flutter-queue.py --timeout 1800 test test/perf
```

On the shared devbox, run it under the heavy-job lock with `flock` and
`nice`, like every other Flutter job there.

- `idle_frames_test.dart`: idle screens draw no frames and keep no timer.
- `frame_budget_test.dart`: rebuilds per interaction (inbox and chat fling,
  syncs during a fling, chat open/close, composer focus) stay within the
  budgets in the test, and the screen goes idle afterwards. Each measured
  window prints `rebuilds: Type: n, …`.
- `inbox_sync_work_test.dart`: an inbox publish costs O(changed rooms).

Count rebuilds with `countRebuilds` (`test/perf/rebuild_counter.dart`): it
counts rebuilds of elements that were on screen before the window. Do not
filter on the `builtOnce` argument of `debugOnRebuildDirtyWidget`; Flutter
tracks it only while `debugPrintRebuildDirtyWidgets` is on, so such a filter
counts nothing. `perfInbox()` keeps the fixture's device-local registries in
memory; wait with `perfInboxRows` and assert rows exist before measuring, or
the benchmark measures an empty page.

## Logo and icons

The logo, app icons, splash images and notification icon are rendered from
the SVGs in [docs/brand/](brand/BRAND.md) with
`python3 scripts/brand/generate-icons.py` (needs one SVG renderer: librsvg,
ffmpeg with librsvg, or `cairosvg`). Do not edit the PNGs by hand.

## Feature notes

- [WhatsApp links and read-only polls](whatsapp-rich-messages.md): incoming
  bridge contract, disabled outgoing operations, compatibility and rollout.
- [Instagram link media](instagram-link-media.md): optional bridge contract,
  integration behavior and current acceptance limits.
- [Voice notes and round videos](voice-recording.md): microphone capture,
  codecs and what each bridged network receives.

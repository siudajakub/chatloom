# Performance: benchmarks and timing points

Wave 5 (2026-10-21), PF-08, PF-10, PF-11. Three layers, from the cheapest:

| Layer | Runs on | Answers |
|---|---|---|
| Frame-work budget test `test/perf/frame_budget_test.dart` | Linux devbox, CI | Do scroll frames rebuild pages or rows? Does the screen go idle afterwards? |
| Frame-timing benchmark `integration_test/perf/smoothness_test.dart` | Pixel, Mac (profile) | Build/raster ms per frame (p50/p90/p99, worst, missed budget) for fixed scenarios |
| In-app probe, Settings → Advanced → Performance | J's real app | Chat open, send, receive, member fetch, database open and frame times in real use |

All three use fictional data only. Nothing here sends messages or reads
an account.

## 1. Budget test (Linux)

```sh
cd client
source scripts/devbox-env.sh
rtk flock -w 5400 /tmp/chatloom-heavy.lock \
  nice -n 10 python3 scripts/flutter-queue.py --timeout 3600 \
  test test/perf/frame_budget_test.dart
```

On the Mac: `flutter test test/perf/frame_budget_test.dart`.

Scenarios (shared with the benchmark, `test/perf/perf_scenarios.dart`):
inbox fling (300 chats), inbox fling while 20 new messages arrive, chat
fling (500 messages, replies, varying lengths), chat open/close, composer
focus. Assertions: no `ChatListViewBody`/`NotionInboxPage`/row rebuilds
while rows only move, at most a few coalesced inbox publishes for 20 syncs,
no `ConversationBubble`/`MessageContent` rebuilds during a chat fling or a
keyboard toggle, and `hasScheduledFrame == false` once everything settled
(no endless animation).

## 2. Frame-timing benchmark (Pixel and Mac)

Profile mode, real frames. Results land in
`build/perf/chatloom_smoothness.json` (Flutter's `FrameTimingSummarizer`:
`average/90th/99th_percentile_frame_build_time_millis`, rasterizer
equivalents, `worst_*`, `missed_frame_*_budget_count`, `frame_count`) and
as one `PERSONAL_BENCH {json}` line per scenario in the output.

```sh
cd $PERSONAL_CHAT_ROOT/client
export FLUTTER=$PERSONAL_CHAT_ROOT/spikes/toolchains/flutter-3.47.4/bin/flutter

# Pixel (USB debugging on, screen unlocked, 120 Hz left on):
scripts/perf/run-benchmarks.sh android            # or: android <adb-serial>

# Mac (quit ChatLoom first; same bundle id, separate .app under build/):
scripts/perf/run-benchmarks.sh macos
```

**Never run `flutter drive` or `flutter run` of this target directly on the
phone.** A profile build is signed with the debug key; when `pl.personal.chat`
(the real, release-signed app) is installed, the Flutter tool uninstalls it
to install the test build, deleting ChatLoom's data, keys and history. The
script builds with `-PchatloomPerfBenchmark=true` (via
`ORG_GRADLE_PROJECT_chatloomPerfBenchmark`), which installs a separate app,
`pl.personal.chat.perf`, without Firebase, and refuses to continue unless
`aapt2` confirms that package name. Remove it afterwards with
`adb uninstall pl.personal.chat.perf`.

The fixtures mock shared preferences, give the private client no database
and never call the app's `main()`, so the benchmark does not open the
Keychain, SQLCipher databases or the network.

How to use the numbers:

- Run each platform three times and keep the median of each field; close
  other apps; keep the Pixel cool (thermal throttling doubles raster times).
- Budget: 8.3 ms per frame at 120 Hz (Pixel, ProMotion Mac), 16.7 ms at
  60 Hz. `90th_percentile_*` under budget and few `missed_*` is smooth.
- Compare before/after a change on the same device and refresh rate:
  baseline on `main` before wave 5 phase 2, then after the merge.
- `inbox_fling_syncs` vs `inbox_fling` shows the cost of inbox publishes
  (PF-07); `chat_open_close` and `keyboard` show route and inset work
  (PF-03, PF-14).

## 3. In-app probe (real use)

Settings → Advanced → Performance. Durations since the app started, the
last 128 samples per operation, median/90 %/99 % and count. "Measure frame
times" collects frame build/raster times until the app restarts. "Copy
summary" copies the same numbers as text (labels and milliseconds only).

| Label | From → to |
|---|---|
| `chat_open.first_frame` / `.route` / `.timeline` / `.rows` | chat page created (tap) → first frame / slide finished / history loaded / first frame with rows |
| `merged_open.*` | same for a merged person |
| `send.durable` / `.bubble` / `.acked` | send tap → outbox persisted / local echo on screen / server accepted |
| `send.http` | the `PUT …/send/…` request alone |
| `receive.row` | sync with a new incoming message starts processing → the frame after the inbox showed it (only while the inbox is visible; > 5 s waits for a covered inbox are dropped) |
| `sync.process` | SDK processing of one sync response |
| `inbox.publish` | one inbox refresh (selection) |
| `members.fetch` | `GET …/members` until the body is read: count = how often the trust check/encryption hits the network |
| `db.key.*`, `db.open.matrix`/`.personal`/`.pending` | secure-storage key read; SQLCipher open incl. key derivation (input for the deferred KDF decision, threshold > 150 ms) |
| `startup.*` | milliseconds since `main` for this start |

Builds with `--dart-define=PERSONAL_PERFORMANCE_PROBE=true` also log every
sample, lifecycle changes and a 5-second frame summary as
`PERSONAL_PERF {json}` lines (`adb logcat | grep PERSONAL_PERF`).

## PF-08: animation pauses when the app is in the background

`NotionActivity` (app root) turns `TickerMode` off and makes
`NotionMotion.reduced` true while the app is not resumed or the macOS window
is occluded/minimised/closed (`MainFlutterWindow.swift` reports occlusion
over `pl.personal.chat/desktop`, method `visibility`). Measure on the Mac with
Activity Monitor (CPU, Energy Impact) with a GIF and a typing indicator on
screen: focused vs. unfocused vs. minimised. Expected: unfocused and
minimised drop to idle.

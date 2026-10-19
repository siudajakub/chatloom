# Notion dark v2 — local delivery, 2026-10-13

Update 2026-10-16: unified settings categories, focused Personal pages, responsive navigation and offline/privacy regressions are recorded in [the settings unification report](../personal/settings-unification-2026-10-16.md). Earlier settings screenshots describe the superseded layout; new synthetic captures are kept separately.

Update 2026-10-15, canonical `client/`: the previously blocked full app graph now executes with the real native hooks and CLT SDK. Final startup/controller/details/inbox-widget run: **39 PASS**, ten suites. Escape in inbox search now closes once and preserves active IME composition, with a failing-before/passing-after regression. Analyzer: zero errors/warnings, 80 existing infos. The earlier isolated-checkout results below remain historical. Logged-in browser acceptance is partial and its privacy gate remains open after four unclassified denied POST attempts and loss of CDP; the new web/APK runtime is NOT RUN. See [current report](../personal/logged-in-wave-2026-10-15.md).

The approved five-screen interface is implemented in the isolated current-source checkout `$PERSONAL_CHAT_ROOT/client-worktrees/notion-ui`. Three screen agents and the coordinator integrated production presenters with the existing controllers. The original `client/` was read-only throughout.

Inbox has private ordered pinned shortcuts, a flat Messages list, a floating Settings/Search/network dock, any-source merged filtering, account-bound selection, and explicit public discovery. Typing stays local; Clear, outside/Back/Escape dismissal, focus restoration, sync retry, invitations, spaces, archive, unread and drafts remain available. The merged-person draft is included in the Drafts view.

Ordinary and merged conversations have a compact identity/details header, authored rows, inline media, manual transcription and a rectangular composer. Existing replies, reactions, edits, selection, pagination, encrypted media, schedules and durable outbox remain connected. IME candidates cannot submit. The merged microphone opens the existing source recorder with a frozen source/account guard; during a source-locked reply its helper requires cancelling that reply first. Reply attachments and round controls remain available through their existing source-bound paths.

Details and settings use real private metadata, three source notification states, loaded/paged media and existing account/security/recovery/device routes. Incognito in details is a read-only device status linking to global Settings. Native Mute uses the source's fully muted rule; request acknowledgement waits for actual rule sync. Private mutation pending does not disable native notification settings. Account changes reset profile, recovery, metadata listeners and account-management caches; old dialogs/pickers/bootstrap completions cannot mutate the newly selected account.

The app explicitly selects English. User content, identifiers and protocol values are unchanged. Roboto Regular/Medium/Bold and its license are bundled from the installed Flutter SDK, and the default theme is neutral dark. Existing light/system, accent, text-size, wallpaper and private appearance preferences remain reachable. No runtime stock-photo or font requests were introduced.

## Evidence and limits

| Check | Result | Evidence / exact scope |
|---|---|---|
| Immutable dirty-source BASE | PASS, 1,101 files and archive hashes verified | `integration-three-way.json`; archive retains its original 0444 mode |
| Locked dependency resolution | PASS; five added SVG graph packages, no existing version changes | `dependency-delta.json`, `svg-dependency.log` |
| Production presentation tests | PASS, 34 tests | `widget-final-valid-captures.log`; copied, hashed production presenters plus unchanged core, fictional adapters |
| Production round widget/controller regressions | PASS, 27 tests | `round-widgets-final.log`; capture/gesture/playback fixtures and existing privacy/TTL controls |
| Core/storage/outbox/privacy/capability regressions | PASS, 82 core tests plus 11 standalone suites | `personal-regressions.log`; SQLCipher/wrong-key/fail-closed, source routing, crash/retry and HTTP privacy fixtures |
| Application analyzer | PASS with `--no-fatal-infos`, zero errors/warnings; 88 style infos remain | `analyze-complete.log`; exact final totals retained in log |
| Diff whitespace | PASS | `git diff --check` |
| Android release attempt with pub | BLOCKED at package signing after Dart/native compilation | `android-release-delivery.log`; isolated checkout lacks `android/key.properties` / release `storeFile` |
| Full app graph widget/controller/adapter runner | BLOCKED before tests execute | Native `webcrypto` CMake hook requires the missing Xcode platform SDK; native-tools PATH retry attempted, without disabling hooks |
| Signed APK, phone installation, original reintegration, deployment | NOT RUN | No signing inputs copied, dummy key, install, commit, push or deployment |
| Real account/history/recovery/E2EE, physical media/Telegram round-trip, FCM/push/Doze/battery | NOT RUN | No account/private message read, real recipient or device test was authorized/exercised |

Android Firebase configuration is absent in this isolated checkout. Build progress does not confirm Firebase availability, push delivery or account correctness. Full-graph tests under `*_controller_test.dart` and `*_adapter_test.dart` remain saved and analyzed; they are excluded from the separate presenter harness and remain NOT RUN, rather than counted among the 34 passes.

## Visual verification

[Offline comparison gallery](evidence/visual-comparison.html) pairs the five approved references with actual production presenters. Reference SVG view boxes exclude exterior/frame/generated OS chrome using explicitly estimated content bounds in `reference-crop-estimates.json`. The 390 × 844 target is independent of the reference raster dimensions. No automated pixel-equality score or live-app acceptance is claimed.

Sixteen PNGs were rendered and opened for inspection: the five main surfaces at 390 × 844; scrolled detail privacy and Settings preferences; 320/360/412/430 widths; 200% text; empty/many pins; keyboard/error merged composition; and the existing production two-column layout at 900/1200 widths. `screenshots/manifest.json` records dimensions, 2× capture ratio and SHA-256. Raw OS safe areas are blank; there is no fake status bar, home indicator or phone frame.

Approved fictional portrait/café pixels are loaded only into the disposable capture package as image data. They are absent from production assets; actual app avatars/media use the existing permitted SDK/private loaders and initials fallback. The screenshots do not seed contacts, messages, network accounts or success states. English fixture names/messages/counts are illustrative. Larger text reflows property/value rows and the dock while preserving touch targets. Details and settings scroll to expose the complete hierarchy instead of compressing it into the mock's raster aspect ratio. Empty send is visibly disabled.

An initial renderer pass lacked test fonts/icons; those malformed images were replaced after loading production fonts/MaterialIcons. A later asset/scroll restoration capture race was corrected by waiting for image decoding and explicitly setting capture positions. Final valid images supersede those earlier files. These repairs changed evidence mechanics, not application transport.

## Safe integration

`integration-three-way.json` compares immutable BASE, this UI checkout and the current original code. `ui-against-base.patch` is the textual redesign delta against BASE, not against upstream HEAD. New asset hashes and paths accompany it. The source-only delta archive is for reviewed staging; never unpack it over the original checkout.

The final inventory records 60 changed UI files plus 43 new source/assets/tests/helpers, 19 original files changed since BASE, and 10 overlapping paths. All 103 delta archive members were checked against their recorded hashes. Before reintegration, obtain the Android owner's explicit path release, take a fresh code-only original inventory, and reconcile each overlap in staging. Verify the current original hash immediately before every write. Keep newer round/FCM/privacy/outbox work and regenerate platform outputs normally. The UI checkout has not imported post-BASE Android changes; its passing checks apply to its preserved functional snapshot.

Protected SDK/core/storage/media/outbox/worker/push/native source is byte-identical to BASE where inventoried, except eleven separately verified English-copy-only files. Mixed conversation presentation/controller hunks were reviewed for source/account/reply/round invariants. Private configs, signing material, runtime databases and credentials are absent from the delta. No source was copied from the older Skiff functional checkout.

## Reproduce

From the isolated checkout, run one Flutter job at a time:

```sh
rtk python3 scripts/verify-notion-ui.py --flutter $PERSONAL_CHAT_ROOT/spikes/toolchains/flutter-3.47.4/bin/flutter
rtk python3 scripts/verify-round-widgets.py --flutter $PERSONAL_CHAT_ROOT/spikes/toolchains/flutter-3.47.4/bin/flutter
rtk python3 scripts/verify-personal.py --dart $PERSONAL_CHAT_ROOT/spikes/toolchains/flutter-3.47.4/bin/dart
rtk $PERSONAL_CHAT_ROOT/spikes/toolchains/flutter-3.47.4/bin/flutter analyze --no-pub --no-fatal-infos lib test/notion
rtk python3 scripts/notion-integration-report.py
```

The exact pinned SVG package usage was checked against [flutter_svg's official package documentation](https://pub.dev/packages/flutter_svg). Only its local original vector assets are used.

The inherited homeserver unread-notification count can include source control events; control-neutral server counts remain an unverified account/bridge boundary. The UI preserves the existing truthful count source.

## Conversation UX — 2026-10-16

[Raport i dokładne granice dowodów](../personal/conversation-ux-2026-10-16.md): 306 app-graph PASS z native hooks, 25 captures/contrast PASS, końcowy adapter/paleta 7 PASS, presentation harness 120 PASS, Personal 98 core i suites PASS, analyzer 0 errors/0 warnings (151 info), web assets/worker oraz web release PASS. Liczniki przebiegów pokrywają się. Nowe faktyczne Message/MergedChatPage/CompactComposer captures: `artifacts/conversation-ux-2026-10-16/final-captures/` w głównym projekcie. Fizyczny runtime, konto, dostawa/push i deploy/install pozostają NOT RUN.

## Chat rules — 2026-10-16

Network/group visibility, Ignored/Technical categories and private notification rules are described in [the chat rules report](../personal/chat-rules-2026-10-16.md). These settings use the native encrypted journal; web has the corrected classifier and selectors without a plaintext preference store. Device, account delivery and deployment remain separate acceptance gates.

## Compact voice player — 2026-10-16

38 focused full-graph tests PASS with native hooks; 5 synthetic presentation captures; analyzer 0 errors / 0 warnings / 165 info (`--no-fatal-infos`); JS web release PASS. Verified in an isolated source copy because shared checkout build files changed during earlier runs. Voice sources match canonical client byte-for-byte. Physical codec/account/device acceptance remains NOT RUN. Evidence: `artifacts/voice-player-implementation-2026-10-16/RESULTS.json` in project root; report `docs/personal/compact-voice-player-2026-10-16.md`.


## Profile content — 2026-10-16

164 focused full-app-graph tests PASS with real native hooks/CMake, plus 10 supplementary overlapping details/interaction/capture checks and 21 final overlapping sync/redaction/source/transport regressions. 101 Personal core tests and storage/outbox/privacy/capability suites PASS. 29 production-presenter captures use fictional data; corrected profile-320/loading frames are indexed in the capture manifest. Analyzer: zero errors/warnings, 182 info. See [full scope, final transport/build results and Git-directory limitation](../personal/profile-content-2026-10-16.md). Real account/device/E2EE/history/push/CI/install/deploy remain NOT RUN.

## Design system hardening — 2026-10-17

See [`DESIGN.md`](../../DESIGN.md). `scripts/verify-notion-ui.py --update-goldens`: 143 presentation tests PASS, 15 goldens written (10 primitives/component themes dark+light, 5 screens: inbox, conversation, merged conversation, chat details, settings), viewed. The capture test's stale `All chats` tap now targets the current `All networks` dock label; full-graph SDK suites that cannot compile in the harness are excluded there as before. `flutter analyze lib`: 0 errors, 0 warnings, infos only in files outside this change. `verify-personal.py`: PASS including design-lint report (642 legacy hits frozen in `scripts/design-baseline.json`). Real device/account rendering NOT RUN.

## Glass chrome (direction B) — 2026-10-17

`NotionGlassSurface`/`NotionGlassBar` + `NotionGlass` tokens (DESIGN.md "Glass"). Applied to the inbox pinned header and floating dock, conversation `AppBar` and composer strip (`ChatView`, shared `BackdropGroup` in `ChatPageWithRoom`), and the merged chat header. Harness: 162 tests PASS with 20 goldens (glass on dark/light, fallback dark, scrolled inbox/conversation with glass forced on); the run was then aborted only by source drift from concurrent sessions (`notion_motion.dart`, `personal_core` contracts). `flutter analyze lib`: no issues in glass files; 4 errors at that moment in `lib/utils/push_helper.dart` from a concurrent push change. `verify-personal.py` PASS. flutter_tester has no Impeller, so `auto` mode renders the solid fallback there; real Impeller blur, performance and Android/iOS scrolling are NOT RUN (no emulator or device available).

## Motion foundation — 2026-10-19

Packages `flutter_animate 4.5.2` and `skeletonizer 3.0.0` (exact pins; new transitive `flutter_shaders 0.1.5`; no other lock change). The golden harness copies every `lib/ui/notion/*.dart` (except `metadata_actions.dart`) plus the two legacy loop shims and pins both packages. `test/notion/motion_primitives_test.dart` (33 tests) covers settle-to-identity, reduced motion, no pending timers, loops under `TickerMode` off, the delayed loader, dialog/popover/sheet routes and play-once scopes. New golden `primitives/motion-dark.png` (resting states under reduced motion); every existing golden unchanged. Design lint gained `motion-import`, `motion-blur`, `motion-duration`, `legacy-material-import` and `motion-animate-widget`; existing hits (2 blur, 5 duration) were frozen in the baseline. On-device frame timing (Pixel probe build), real predictive back and haptics are NOT RUN.

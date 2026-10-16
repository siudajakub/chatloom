# Preserved feature ledger

Update 2026-10-16: unified settings categories, focused Personal pages, responsive navigation and offline/privacy regressions are recorded in [the settings unification report](../personal/settings-unification-2026-10-16.md). Earlier settings screenshots describe the superseded layout; new synthetic captures are kept separately.

Update 2026-10-15: canonical full startup/controller/details/inbox-widget graph **39 PASS** with native hooks enabled. Search Escape regression fixed with IME preservation. This supersedes the historical full-graph NOT RUN below for those ten named suites only. Account/browser, native storage, device and deployment boundaries are recorded separately in [the logged-in wave report](../personal/logged-in-wave-2026-10-15.md).

Baseline archive hash verified before editing; inherited files require comparison against SOURCE-SNAPSHOT, not HEAD.

| Flow | Route / implementation retained | Owner |
|---|---|---|
| Auth and recovery | Existing guards, /backup, bootstrap, account selection | Root |
| Inbox, invitations, spaces, archive, unread, drafts | /rooms and ChatListController / InboxProjection | A |
| Pins, private labels, organization | Existing org metadata and journal, OrganizationPage | Root / A / C |
| Search | Local conversation search; explicit public discovery; scoped loaded-history search | A / C |
| Ordinary timeline and event actions | /rooms/:roomid with stable event identities | B |
| Merged timeline and frozen source | MergedChatPage, SourceChatPage | B |
| Media, voice, manual transcript, rounds | Existing SDK renderers/outbox/capability/TTL gates | B |
| Details and notification rules | /rooms/:roomid/details and source-scoped merged drilldown | C |
| Private sync, conflicts, jobs, merge, bookmarks, schedules | PersonalHub and existing secondary pages | Root / C |
| Security, recovery, devices, lock, account, logout | Existing settings routes and bootstrap | C / Root |
| Appearance and accessibility | System/light/dark, text scale and existing preferences | C / Root |
| Crypto/storage/privacy/startup/push | Protected sources retained, regressions queued | Root |

Real account, device, bridge delivery, physical push, install/deploy/reintegration: NOT RUN.

## Final status

All listed UI adapters/routes are integrated locally. Production presenter fixtures: 34 PASS; round production widget/controller fixtures: 27 PASS; core/storage/privacy/outbox/capabilities: 82 core + 11 standalone suites PASS. The evidence/VERIFICATION report names exact scope and omitted native tests.

Additional guards: device-wide privacy display, source-authoritative notifications, any-source filters, pre-search inbox position restoration, source/account frozen across voice/picker/profile actions, account-specific details/settings cache keys, initial and decoded-avatar failure fallback. No production mock contact/image/network/status data seeded.

A/B/C and root source are frozen. Controller and adapter tests requiring the full app native graph remain NOT RUN because the existing webcrypto/Xcode hook blocks the runner. Original reintegration and all real-account/device/deployment gates remain NOT RUN.

## Conversation UX — 2026-10-16

Zatwierdzony A jest zintegrowany w ordinary i merged: kierunkowe grupowane dymki, compact composer, pełny source picker/reply lock, wspólne gesty i reakcje. Aktualny zakres i ograniczenia: [raport rozmów](../personal/conversation-ux-2026-10-16.md). 306 testów pełnego app graph PASS, uzupełniające integracje/kontrast/paleta PASS; realne konto i urządzenie NOT RUN. Historyczne NOT RUN dla native hooka powyżej nie dotyczy tych wybranych suites uruchomionych przez aktualny runner z prawdziwym CMake.

## Chat rules — 2026-10-16

Network/group visibility, Ignored/Technical categories and private notification rules are described in [the chat rules report](../personal/chat-rules-2026-10-16.md). These settings use the native encrypted journal; web has the corrected classifier and selectors without a plaintext preference store. Device, account delivery and deployment remain separate acceptance gates.

## Compact voice player — 2026-10-16

Inline waveform/flat fallback, drag preview + release seek, ±10s, speed, save, pause/loading, keyboard/adjustable semantics, RTL and 200% text. No expand/fullscreen. SDK adapter ownership, duration/speed streams and shutdown covered by offline fixtures. See `docs/personal/compact-voice-player-2026-10-16.md`.


## Profile content — 2026-10-16

Profile refinement, three shared-content tabs/grid, short ordinary/merged menu and legacy-label inbox visibility are implemented locally. Real SDK SENDING/history regression and bounded source controller covered; see [implementation and evidence](../personal/profile-content-2026-10-16.md). Real account/device/CI/deployment remain NOT RUN.

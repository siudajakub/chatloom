# Preserved feature ledger

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

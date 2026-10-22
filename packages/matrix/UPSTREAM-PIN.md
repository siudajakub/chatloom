Upstream Matrix Dart SDK commit: 355bf1d2d471ef2ab578d83a14a684cea7c07a1c
Local patch: timeline database pagination excludes unsynced local echoes from its synced-ID offset, preventing a missing first event on the next page. Regression: real SQL database fixture in app `test/notion/content_history_controller_test.dart`.
Local patch: application clients opt in to cancellable exponential sync retry delays with `syncErrorMaxTimeoutSec = 60`; the SDK default preserves the fixed base interval for the worker and other consumers. Push `oneShotSync`, foreground resume and explicit retries bypass the timer; background disable/dispose cancels it. Successful sync clears the failure count. No push registration, notification eligibility, presence policy or cryptographic changes. Regression: app `test/personal/resource_optimization_test.dart`.
Local patch: sanitize log events before buffering/printing; cap log buffer.
Transport and cryptography remain upstream.
Local patch: attachment byte streams propagate progress callback failures through the download future and cancel the subscription. Round-video cancellation, source invalidation and size guards can no longer escape as unhandled zone errors or leave the download pending. Regressions: application `round_media_loader_test.dart` and `round_mini_player_lifecycle_test.dart`.
Local patch: bridge-aware room titles, avatars and presentation-only DM classification use bridge channel metadata and exclude declared service members. Legacy DM inference requires a complete participant count; explicit group/channel types remain groups. Native `m.direct`, merge authorization, transport and cryptography are unchanged. Regression: `test/personal/bridge_conversation_identity_test.dart` in the application graph.
Local patch: optional source-bound outgoing acceptance callback for all message/media paths; callback failures cannot alter transport result.
Local patch: optional capability authorization before outgoing content and redactions; source events retain their original room.
Local patch: explicit startup-only `preserveSessionOnInitFailure` mode retains persisted session/history/keys on local initialization failure. It requires completed local loaders, no first-sync wait and no active/soft-logged-out session; default login/register cleanup remains upstream. App `initWithRestore` opts in and requires explicit consent in code for backup restoration. Regressions: `worker/test/sdk_startup_preservation_test.dart` and app startup tests.


### 2026-10-16 — local history cursor

`Timeline` backward database pagination uses the synced ID boundary rather than
`events.length`. The real MatrixSdkDatabase regression reproduces 81 returned
records for limit 80 when SENDING exists, and demonstrates the previously skipped
synced event. Bounded ID scans also advance across missing stored rows and survive
head insertions. Rows are materialized by those captured IDs to avoid a sync
insertion between separate ID and row reads. Cursor state rolls back after a
database error. Future/fragmented/network history and decryption remain SDK paths.
Regression: app `test/notion/content_history_controller_test.dart`; before/after
logs under `artifacts/profile-content-2026-10-16` in the Personal project.

### 2026-10-18 — off-isolate `/sync` decoding

`Api.sync` (generated `api.dart`) hands the response bytes to
`matrix_api_lite/utils/sync_body_decoder.dart`. Bodies above 256 KiB run UTF-8 +
JSON + `SyncUpdate.fromJson` in `Isolate.run`; the decoded graph returns through
`Isolate.exit` without a second copy. Smaller bodies and web (conditional import,
no shared-heap isolates) decode inline exactly as upstream. HTTP status handling,
request parameters, sync processing order, database transactions, transport and
cryptography are unchanged; decode errors still fail the same `sync()` future.
Re-apply after regenerating `api.dart`. Regression: app
`test/personal/sync_body_decoder_test.dart` (inline/isolate equivalence on the
SDK sync fixture and a >256 KiB body through `MatrixApi.sync`).

### 2026-10-20 — restartable sync long-poll

`Client.restartSync({timeout})` drops a `/sync` request that is still waiting
for its response (for example a long-poll on the socket of a network that went
away after a Wi-Fi/mobile switch) and starts a new request at once. The dropped
request's late response or error is discarded unprocessed and reports no sync
status; a response already being processed is never interrupted (the call then
joins it like `oneShotSync`). The loop's completion handler only clears or
continues the loop it started, so a request dropped by `restartSync` or
`abortSync` can no longer clobber `_currentSync` or spawn a second parallel
loop, and a dropped request's failure no longer sets `_lastSyncFailed` or emits
`SyncStatus.error`. Since tokens, processing order, database transactions,
transport and cryptography are unchanged. Regression: app
`test/personal/sync_network_restart_test.dart` (plus
`test/personal/resource_optimization_test.dart`).

### 2026-10-21 — undeclared rooms of kind-declaring bridges are groups

mautrix bridgev2 writes `com.beeper.room_type.v2` only for `dm`, `group_dm`
and `space`; groups, channels and broadcasts (`RoomTypeDefault`) carry no
room type at all. The bridge-aware presentation used to fall back to member
counting for such rooms, so a Telegram channel (owner + bridge bot + channel
ghost), a hidden-member supergroup with one synced sender, a 2-member group
or a WhatsApp status broadcast with one poster showed as a DM. `Room` now
treats a bridged room without a declaration as a group when its bridge is
known to declare kinds: the bridge bot sent `com.beeper.room_features` under
the same state key (every bridgev2 portal), or the same bot sent a declaration
in another room of the client (`Room.bridgeBotsDeclaringRoomKinds`, filled in
`setState`, grows only, bot-sent declarations only). Bridges that never
declare kinds keep the complete-member-list heuristic. Presentation only:
native `m.direct`, merge authorization, transport and cryptography are
unchanged. Regression: app `test/personal/conversation_kind_networks_test.dart`
and `test/personal/merge_conversations_test.dart`.

### 2026-10-21 — `sendFileEvent`: one full-resolution decode, concurrent uploads

Two scheduling changes in `Room.sendFileEvent`, both after the local echo
exists, so they only shorten the time until the message is delivered:

- An image is shrunk (`shrinkImageMaxDimension`) first and its thumbnail is
  derived from the shrunk image. Upstream generated the thumbnail from the
  original and then shrank the original again, so a 12 MP photo was decoded
  and resampled twice on the calling isolate (the app's resizer is
  synchronous FFI after the codec decode). The files produced are the same
  kind (a ≤ shrink-size JPEG and a ≤ 800 px thumbnail with blurhash).
- The file and its thumbnail upload concurrently, and a retry inside the
  transport loop uploads only the part that is still missing (upstream
  re-uploaded the file when only the thumbnail had failed). Same requests,
  same encrypted payloads, same event content; the loop's timeout and the
  `MatrixException` handling are unchanged.

Transaction IDs, the event content, encryption (`MatrixFile.encrypt`) and
the server requests are unchanged. Regression: app
`test/personal/outgoing_media_test.dart` (send order and retries through the
app's media queue) and `test/notion/attachment_flow_test.dart`.

### 2026-10-22 — unsent files: no self-deleting bubble, copy kept until accepted

Two one-line changes on the send path of files (wave 5, lane outbox-send):

- `Event._getCachedFile` no longer calls `cancelSend()` when this device's
  copy (`cache://file/<txid>`) is missing; it returns null. Upstream deleted
  the unsent event from the database and the timeline there, so any preview,
  save, share or download of an unsent file without a copy (a round echo, a
  file above the cache's size limit, an evicted copy) made its bubble vanish
  (CC-03). `Event.sendAgain` still throws `FileNoLongerInCacheException`;
  `downloadAndDecryptAttachment` falls through to the server URL (or throws
  when there is none yet).
- `Room.sendFileEvent` deletes the cached copy and thumbnail only when
  `sendEvent` returned an event ID. `sendEvent` returns null after a failed
  final PUT (any `MatrixException` but `M_FORBIDDEN`, or the transport
  timeout); upstream deleted the copy anyway, so Retry of that file could
  never work (CC-04). The app's Retry resends such an event without its bytes
  (`OutgoingMedia.retry`).

Regression: app `test/personal/sdk_send_file_event_test.dart` (real SDK
database) and `test/personal/outgoing_media_test.dart`.

### 2026-10-22 — member list stored in one transaction

`Room.requestParticipants(cache: true)` stores the fetched members inside one
`database.transaction` instead of one autocommit per member (PF-04): one
commit instead of N on the database isolate, for the chat-open warm-up, the
trust check and the first encryption of a room without complete member
counts. Members are still set in memory first; the stored rows, the request
and encryption are unchanged. Regression: app
`test/personal/sdk_send_file_event_test.dart`.

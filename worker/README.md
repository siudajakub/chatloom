# Personal Matrix feature worker

This is a separate, silent Matrix device. Android/macOS keep their own Matrix transport. The worker consumes only authenticated encrypted personal journal commands from explicitly paired, verified devices. It never generates replies to contacts. Automatic transcription of new incoming voice notes, other audio, round videos and videos is opt-in twice: the synced user policy and the private operator switch `autoTranscription` (default false); see "Automatic transcription".

## Build and synthetic verification

Use Dart 3.13.3 and Rust 1.99.0 (isolated toolchains work), a C compiler, and ffmpeg (optional ffprobe). From `worker/`, run `bash scripts/build-native.sh`, `dart test`, then `bash scripts/native-spike.sh`. The build uses `dart build cli`, since `dart compile exe` does not bundle SQLCipher native assets.

Matrix SDK is the adjacent `packages/matrix` vendor, upstream commit `355bf1d2d471ef2ab578d83a14a684cea7c07a1c` with the parent application's central diagnostic sanitizer. Vodozemac Dart 0.8.0 uses Rust bindings tag 0.8.0, peeled commit `1902d5ded6a3d8c2fc120168f0e08d60d71f58b5`, locked Cargo dependencies. The bundle contains SQLCipher and the Vodozemac native library. No account is needed for the native spike.

## Media runtime without system packages

For Linux without ffmpeg/ffprobe, run `bash scripts/setup-media-runtime.sh /absolute/project/runtime`. The script creates a dedicated Python venv and downloads only the pinned `imageio-ffmpeg==0.6.0` binary wheel from PyPI. All temporary files and package caches stay in that project directory; it does not use sudo, change system packages, modify HOME, or install a global executable. The [official imageio documentation](https://github.com/imageio/imageio-ffmpeg) confirms that its wheels bundle native ffmpeg. This wheel does **not** provide ffprobe.

For development, load the generated `runtime.env` with `set -a; . /absolute/project/runtime/runtime.env; set +a`. `FFMPEG_PATH` selects the exact wheel binary and an empty `FFPROBE_PATH` explicitly uses the duration fallback. Constructor paths take precedence over these variables; otherwise names are resolved through PATH. `runtime.json` records the pinned package version, actual FFmpeg version and SHA-256 of the executable.

When ffprobe is absent, the worker decodes the selected audio with the same configured ffmpeg binary into mono 16 kHz signed 16-bit PCM and derives duration by counting complete samples in the stdout stream without retaining them. This avoids FFmpeg 6 progress timestamps that can undercount the final packet. It does not invent duration or claim that ffprobe exists. Malformed audio, failed conversion, cancellation, oversized output and process timeouts stop before any provider upload and clean the plaintext work directory. A configurable process timeout defaults to ten minutes.

Every probe, decode and conversion restricts input protocols to `file,pipe` and demuxers to `ogg,mp3,wav,mov,aac,matroska,webm,flac,avi,amr` (mov covers mp4/m4a/m4v/3gp, matroska covers mkv/webm); playlists and network-backed formats are rejected. Media children start without the parent's environment and receive only PATH, so provider keys, HOME and service credentials are not inherited. Tests include a disguised playlist with local HTTP canary and private-file reference, and verify zero fetches/uploads, as well as a child-environment witness. The flags follow [FFmpeg format](https://ffmpeg.org/ffmpeg-formats.html#Format-Options) and [protocol](https://ffmpeg.org/ffmpeg-protocols.html) documentation.

This filtering is not a process sandbox and does not establish safety against codec memory-corruption attacks. The current architecture uses a separate service account, systemd restrictions, protocol/demuxer limits, a clean child environment and temporary-file cleanup. Additional codec isolation is optional future hardening. `requireCodecSandbox` defaults to false; when explicitly true, transcription refuses before decoding or uploading until a sandbox is implemented, while schedules/reminders keep working. Do not treat binary availability as proof of isolation. A future implementation should bind the verified codec binary and required libraries read-only, expose only the per-job work directory, hide HOME/credentials/Matrix databases and unshare networking. On the checked VPS, `bwrap` was absent; no such isolation is claimed.

For deployment, the operator must install that verified binary into a readable, executable service location such as `/opt/personal-worker/media/ffmpeg` and set `FFMPEG_PATH` there (and `FFPROBE_PATH=`) in the service environment. The service's `ProtectHome` and dedicated account make a developer's private venv unsuitable as its deployment path. Keep the binary checksum and wheel license material with the deployed artifact. These source files and setup script do not alter the live service.

Media tests deliberately fail when no ffmpeg runtime is configured, instead of silently skipping. They cover real WAV silence, OGG Opus, missing ffprobe fallback, input over 25 MB with real splitting, oversized output rejection, process timeout, missing provider key, cancellation, paid uncertainty and cleanup, using mocked OpenAI responses only.

## Enrollment and pairing

The deployment templates bound the whole service cgroup, including codec or CLI
children: the worker, offline admin and session commands use `MemoryHigh=768M`,
`MemoryMax=1536M`, `MemorySwapMax=0`, `TasksMax=128` and `CPUQuota=100%`.
Decoder, encoder and FFmpeg filter pools each use one thread. A cgroup OOM kills
the whole worker unit, preserving the normal crash-recovery and paid-uncertainty
rules instead of leaving child processes alive. The daemon limits restarts to
five starts in five minutes. These are local templates; applying limits to an
existing installation requires an authorized rollout and runtime verification.

Copy `config.example.json` into a private operational directory outside the repository; choose absolute paths. Set umask 077. Run `bundle/bin/worker enroll CONFIG` interactively as the future service account. Password, existing recovery key and OpenAI key are entered with terminal echo disabled; no secret is printed. Enrollment preserves any existing session and refuses reset. After an interrupted enrollment, `worker restore CONFIG` unlocks the existing session with the existing recovery key.

The credentials JSON contains `databaseCipher` (64 hexadecimal characters) and optional `openaiApiKey`; the file must be mode 600. No token is copied from browsers or Beeper. Matrix session credentials are stored inside the encrypted SDK DB. Keep an independent protected copy of the database cipher before any operational migration; losing it does not authorize deleting the DB or session.

The app creates a private encrypted room with `pl.personal.client.journal.v1` state `{ "schema": 1 }`, and sends an encrypted `worker.pairing` operation. Configure that room ID and explicitly paired Android/macOS device IDs privately in `trustedDeviceIds`. The private `pairing.json` produced on enrollment contains the worker device ID for app pairing. `worker check CONFIG` verifies membership, encryption, device trust, and actual decryption of an authenticated personal event; a Verified flag alone is insufficient.

Only then start `worker run CONFIG`. The systemd unit is a deployment template; these files do not install or start a service. A worker lock protects all session commands before SDK initialization. The deployment template uses a dedicated account, encrypted state, systemd credentials, private transient storage and no access to Beeper/Hermes service secrets.

## systemd credentials preparation

Install Python 3 and `deploy/prepare_credentials.py` as `/opt/personal-worker/prepare_credentials.py` alongside the Linux bundle in an authorized deployment. Keep `/etc/personal-worker/credentials.json` root-owned mode 0600. The unit's `LoadCredential` feeds `CREDENTIALS_DIRECTORY`; `ExecStartPre` reads only that credential and creates `/run/personal-worker/credentials.json` mode 0600 inside the service-owned 0700 `RuntimeDirectory`. Set `credentialsPath` to that runtime path, as in `config.example.json`. Do not point the owner-only application validator at a systemd file exposed as 0440. Enrollment/restore outside systemd requires a separate private operational config pointing to its existing owner-only credential, since the transient copy exists only during service startup.

The preparer accepts regular single-link source files owned by root or the service UID, mode 0400/0440/0600 (0440 requires a service group); it refuses writable/shared directories, symlinks, unexpected owners/modes and inputs over 65536 bytes. Directory descriptors pin input/output directories; bounded reads and atomic exclusive 0600 replacements prevent partial outputs and following destination links. Every input is validated before writing any output. Failure stops `ExecStartPre` with a fixed message containing no paths or secret values. The worker's strict application validator stays unchanged.

Run both preparers' synthetic regressions from the client checkout: `rtk python3 -W error::ResourceWarning -m unittest discover -s push-gateway/tests -p test_prepare_credentials.py -v`. This covers 0440→0600, owner/group/mode, links/FIFO/oversize, missing inputs, repeated start, plus gateway initialization with/without the reminder relay. Linux/systemd acceptance and its exact command are in [credentials acceptance](../docs/personal/credentials-acceptance-2026-10-15.md). No preparer test proves enrollment or pairing.

## Wire contract

All commands/results use the frozen `PersonalOperation` schema 1 and custom `personalEventType`. Result operations have unique IDs per transition and increasing entity revisions. ACK/status and job changes are persisted atomically; journal publication uses a stable Matrix transaction ID and a durable outbox. Failed publication resumes with the same transaction ID on the same worker device.

* `transcript.request`: full `TranscriptionJob` JSON. Only source, ID, optional language and optional `origin` (`manual` default, `auto` for a client request made on the policy's behalf) are accepted from the caller. Language must be absent/null (automatic detection) or one of `pl`, `en`, `hy`; anything else is rejected with `invalid_language` before a job exists. Model is `gpt-transcribe`. `transcript.cancel` cancels that entity at the current revision. Results use full job JSON plus revision and accepted operation ID. Explicit re-request of a failed/unknown/cancelled job is supported with the current base revision; paid uncertainty never retries automatically.
* `schedule.create/update`: full `ScheduledSend` JSON, canonical account/room target and text or pre-uploaded encrypted media content. The worker owns state, revision, transaction ID and dispatch device. `schedule.cancel/sendNow` targets the entity with its current base revision. Results add error/event status. Initial dispatch over five minutes late pauses; a previously attempted ambiguous dispatch continues using its original transaction ID. A device change or failed verification pauses dispatch.
* `reminder.create`: `{id, conversation, dueAt, untilReply, anchorEventId}`; only these fields are stored and echoed, others are dropped. `untilReply` is an optional boolean. `anchorEventId` is an optional `$…` event ID of at most 255 characters that the app uses to show the reminded message; the worker never fetches or resolves it. `reminder.cancel` targets the current revision. `reminder.result` carries the durable reminder JSON; due results set `due: true`, so clients can display local notifications. `untilReply` means waiting for the recipient response (UI wording: Oczekiwanie na odpowiedź rozmówcy). It cancels after a newer received Message/Sticker in that source room, never on an own message, edit, reaction, redaction or journal event. History is paginated to the createdAt frontier; missing recipient keys or incomplete history keep the reminder pending as waitingKeys/waitingSync and retry without a false due alert or implicit read markers.
* `metadata.put`: direct JSON value (a single `value` wrapper is also accepted). `metadata.delete` creates a tombstone. Conflicts preserve both `existingValue` and `proposedValue`, with neither silently replacing the other.
* `worker.heartbeat`: health, verification state, pending count and `autoTranscription: scan|off`; sent every five minutes, and on a payload change at most once a minute; clients treat it as fresh for 11 minutes. No source IDs or messages in diagnostics or heartbeat.

Automatic background work sends no typing, public/private read receipts or online presence. `syncPresence` is offline from initialization. A bound `readUpToEventId` is sent only after an explicitly authorized scheduled reply has been accepted; background audio processing and reminder scans never mark rooms read. No unconfigured Beeper Client API fallback exists. Explicitly enabled local sources use the restricted Unix-socket adapter described below.

## Reminder wake relay

The private journal is muted; a same-user Matrix worker cannot rely on standard Synapse pushrules because Synapse suppresses events from the recipient's own user before evaluating those rules. Encrypted reminder results therefore remain encrypted and do not add cleartext alert markers.

For closed-app delivery, optionally configure `reminderRelayUrl` as `http://127.0.0.1:8088/internal/reminder` and add `reminderRelayToken` to the protected credentials JSON. Only literal loopback HTTP, the exact path, and no userinfo/query/fragment are allowed. The worker POSTs only `{hintId, emittedAt}` using the separate Bearer credential; the identifier is a stable opaque 64-character SHA-256 value. It contains no room, person, source event ID or text. Redirects are refused.

After the homeserver accepts a due `reminder.result`, the worker commits journal ACK and wake-hint enqueue atomically. Pending hints survive restarts. The relay must deduplicate the identifier across retries; timeout/503 retains the identical hint with thirty-second default backoff and honors the relay Retry-After. Only 2xx removes it. A 2xx denotes gateway/FCM acceptance, not physical device delivery. An absent relay URL or credential leaves hints pending and heartbeat reports `reminderPush: not_configured` with their count. No live service or credential is configured by these source changes.

The app must fetch and decrypt the journal, verify the trusted worker result and deduplicate the reminder before showing a generic notification. Actual closed-app Android/macOS delivery and private-account interoperability remain device/runtime gates.

## Transcription boundaries

The worker sends audio only to OpenAI, using the configured private key. It strips media metadata, converts to mono 16 kHz MP3 at 32 kbit/s (about 240 KB per minute) and splits into 15-minute chunks below 25 MB. Accepted media (shared rule `transcribableMediaKind` in personal_core): voice notes and other `m.audio`, Telegram rounds, any `m.video` and `m.file` with an `audio/*` or `video/*` type (or a known extension). GIF-style loops (`fi.mau.gif`, `fi.mau.no_audio`, loop+autoplay), images, playlists and protected/disappearing media are refused before download. FFmpeg keeps only the first audio stream (`-map 0:a:0 -vn -sn -dn`), so video is never decoded or uploaded. ffprobe reads only the container header; a file without an audio stream fails with `no_audio_track` before any conversion or upload (automatic jobs are then silently `cancelled`). Without ffprobe the PCM fallback reports the same code. Provider answers that prove nothing was processed (429, 502, 503, refused connection or failed DNS) are retried up to three times per chunk with 1 s/2 s backoff or `Retry-After` (max 20 s); 500, 504 and other 5xx, a timeout or a dropped connection after sending remain a paid uncertainty (`unknown`) and are never retried. A failure after an earlier chunk was accepted is final (`openai_partial_failure`), so no chunk is paid twice. Duration and estimated cost (USD 0.0045/minute) are published while processing for manual requests; manual requests have no budget cap. Automatic jobs have a per-message duration cap and a rolling 24-hour budget (below). Timeout/connection uncertainty becomes `unknown`, including crash recovery during a paid request. A user can explicitly retry, with possible additional cost. Cancellation cannot undo a charge already accepted by the provider. Temporary plaintext audio is removed on success, failure, cancel, and the next startup after a crash.

### Automatic transcription

Pipeline (2026-10-19): sources are the local index scan (every 3 s, local bridge rooms) and the worker's own Matrix sync (`MatrixLiveSources`, cloud rooms, event driven: subscribed before the first sync, so the catch-up sync after a restart is seen too; undecryptable events are re-read from the SDK store for 10 minutes). Both report identifiers, kind, declared duration, network and timestamp only. The daemon loop wakes as soon as the feed has items or a transcript finished, instead of sleeping 2 s. Up to two transcripts run in parallel (manual first, then the newest automatic message); the local adapter still serializes exports. Before download an automatic job reads declared metadata (`MediaPreflight`): a disabled kind (`auto_skipped_kind`), a declared duration above `maxSeconds`, or a declared size above 150 MiB (`auto_skipped_size`) is cancelled without fetching anything. An automatic job whose size is undeclared (older adapters) or whose metadata lookup failed runs as a small job under the 32 MiB hard cap; a stream passing it stops with `auto_skipped_size_cap` before any provider request. Memory is bounded: downloads stream with a hard byte cap (Matrix: `boundedMediaDownload` refuses a larger `Content-Length` and cancels the stream at the cap; adapter: the same per-response limit). Media declared above 32 MiB, or a manual job of unknown size, takes a single "large" slot, so at most one large file is in memory and in the tmpfs work directory at a time; every other download is capped at 32 MiB. The kind switch is re-checked after measuring, before upload. Byte-identical media (forwards, merged chats) reuses an earlier done transcript in the same language at zero cost; the SHA-256 is computed in 1 MiB slices that yield to the event loop, and dedupe entries expire after 14 days (pruned hourly, and at once when the source is redacted or the job lost its text). Transient failures (`local_source_*`, `source_unavailable`, `room_unavailable`, provider overload/unreachable) are retried with backoff 15 s, 1 min, 4 min, 16 min (four retries); missing keys back off up to 30 minutes instead of reloading every tick. An event the SDK stored before its room key arrived is decrypted with the keys held at each attempt (the SDK itself re-decrypts stored events only for live timelines and for to-device keys within 5 minutes, not for keys from the backup), and a received to-device room key retries key-waiting jobs at once (2026-10-21). The heartbeat adds `transcriptionMedia: 2` and `autoTranscriptionLive`; apps request videos/media files only from such a worker, and wait a grace period in cloud rooms when the worker watches its own sync. `autoTranscriptionMatrix: false` in the config keeps automatic work to local sources only. The synced policy gains `kinds` (`voice`, `round`, `video`, `audio`; absent = on).

Instagram reels (2026-10-20, J: only on demand): a video shared from Instagram — mautrix-meta delivers the post's own video with the post's link as the top-level `external_url` — is its own kind `reel` (`transcribableMediaKind`, personal_core). Its switch `kinds.reel` defaults to off, so reels are never transcribed automatically unless switched on; a manual request transcribes them like any video. The local scan asks the adapter for `reel` items only while that switch is on (an adapter that predates reels refuses the kind; the worker then scans without it for the rest of the run, so reels stay on demand). The adapter detects a share from an Instagram `external_url` field or, for Instagram messages, a post/reel/story link in the indexed caption; it answers a selected reel as `kind: video` plus `reel: true`, which older workers ignore. The heartbeat reports `transcriptionMedia: 3`. Older workers and apps drop the unknown switch and treat a reel as a video.

J asked for automatic transcription of incoming voice and round messages on 2026-10-17. It needs **both** the synced user policy and the private operator switch `"autoTranscription": true` in the worker config (default false); the worker's own scan additionally needs `localSourceSocket`. The synced policy is the private journal metadata entity `transcription-policy` (`version`, `auto`, `enabledAt`, `defaultLanguage`, `networks`, `chatOverrides`, `maxSeconds` default 300, `dailyBudgetUsd` default 1.0). An absent policy means automatic on for incoming voice/round messages in every network (J's request); an unreadable or newer-version policy means off. A policy that was never switched on explicitly has no `enabledAt`: the worker scan then starts at the end of the index, and each app starts its own window when it first sees that policy together with a `scan` heartbeat (stored only in the device's encrypted local store, never journaled), so an upgrade never sweeps up the last 24 hours.

* Every ~10 s the daemon asks the local adapter (`POST /recent`) for identifiers of messages indexed after its private cursor (checkpoint `auto-scan`). The first scan, and the first after the policy was off, only records the current end of the index: no history sweep. Messages older than 24 hours or older than `enabledAt` are ignored, and so are messages whose timestamp is missing or unreadable (treated as too old, by the adapter and by the worker). A worker started with the switch off forgets the scan cursor, so switching it back on starts at the end of the index.
* Skipped: own messages (the app that sent one requests it itself, as an automatic job under the same limits, when the synced policy's `outgoing` is on; 2026-10-21), deleted/edited rows, disappearing or protected media (the adapter refuses `disappearingTimer` and other protective markers), anything not exportable speech media (voice, round, video, other audio), kinds switched off in the policy, chats muted or ignored in private metadata (`org:<room>`, `org:person:<group>`, `network-policy:<network>` notifications muted), per-chat "Never", disabled networks (and unknown networks once any network is disabled), and messages that already have a job of any state. Per-chat "Always" outranks network, mute and ignore rules.
* A new job uses the deterministic entity `transcript:<sha256(source key)>` (same as the app), `origin: auto`, the policy language and revision 1, and is published like any job. Manual jobs always run first.
* Before upload: a known duration above `maxSeconds`, or a rolling 24 h automatic spend at or above `dailyBudgetUsd`, records the job as `cancelled` with `auto_skipped_duration` / `auto_skipped_budget` without downloading. After local measurement (still before upload) the same limits are checked again, and a policy switched off cancels with `auto_disabled`. Nothing is uploaded in these cases. Automatic jobs do not publish a separate estimate step; the final result carries duration and cost.
* The app also asks on the policy's behalf (`origin: auto`) for a qualifying visible message without a job: immediately in cloud rooms the scan cannot see, and after a 2-minute grace period in local bridge rooms. It does so (and shows "Transcribing…") **only** while a fresh heartbeat reports `autoTranscription: scan`; with `off` or an older worker that does not report the field, the app sends nothing automatically. These requests are bound by the same limits. The worker rejects `transcript.request` with `origin: auto` (`conflict`, `auto_disabled`) unless the operator switch is on, and cancels queued automatic jobs before download (`auto_disabled`) when it runs without the switch. Workers built before this change ignore `origin`; the app-side gate is what protects them.
* Disappearing messages are never transcribed, manually or automatically: mautrix bridgev2's `com.beeper.disappearing_timer` in the message content, or as the room's state (the chat's current setting), refuses the source with `protected_media`. Anything except an explicit off (`{}`, or type `""`/`none` with no positive timer) counts as on (fail closed). The app applies the same rules before automatic requests and media prefetch.
* The heartbeat reports `autoTranscription: scan` when the operator switch is on and a source (local adapter or the Matrix sync feed) is active, otherwise `off`.

OpenAI model and price were verified against [official model documentation](https://developers.openai.com/api/docs/models/gpt-transcribe), and format/size/language fields against [file transcription documentation](https://developers.openai.com/api/docs/guides/speech-to-text), on 2026-10-04. Pricing is an estimate, not invoiced usage.

## Legacy import

`bundle/bin/migrate SOURCE.sqlite EXPLICIT_MAPPING.json CONFIG` is a dry run. `--apply` creates an independent encrypted source backup, then imports only explicitly mapped completed results into the worker's encrypted jobs and journal outbox. It never connects to Matrix/OpenAI/Beeper or sends to anyone. Stop the old consumer before live migration, and stop the new worker while applying the import.

Mapping is an array of `{ "legacy": { "chatId": "...", "messageId": "..." }, "source": SourceEventRef }`. No mapping by title, text, timestamps or guessed IDs is allowed. Unmapped rows stay unimported. The original SQLite source remains read-only. No deletion of legacy state occurs.

## Verification boundaries

Synthetic tests prove state machines, encrypted storage, cleanup, conversion, request shape, ambiguous-send retries and migration safety. Native spikes prove Linux/macOS library loading and encrypted SDK initialization. They do not prove private-account enrollment, source-history decryption, bridge delivery, OpenAI account permissions, native app notifications or real-device battery behavior. Those gates require the user's controlled pairing and designated test recipient, with no key reset or browser-auth export.

A private encrypted journal can be decryptable by other authorized devices on the same Matrix account under standard SDK key sharing. Hiding it in this client's inbox does not hide it in official Beeper. Removing a device cannot recall keys or transcriptions already downloaded by that device.

Journal sender trust accepts only events decrypted with a megolm session delivered directly by a verified own device; backup-imported and forwarded sessions are refused. The worker rotates its journal outbound session at start and every 24 h so new devices catch up. See [journal trust](../docs/personal/journal-trust-2026-10-17.md).

Source deletion: the worker checks fresh source-event metadata before a paid request and again before publishing its result. Unknown status (missing keys, 404 or network failure) does not prove deletion and never triggers another paid request automatically. After journal reconciliation, a bounded round-robin audit checks at most four explicitly requested transcript jobs every 30 seconds; it never sweeps room history or downloads audio. Jobs parked on an unknown status (`waitingSync` + `source_status_unknown`: the check before the download failed, or a finished transcript waits for the check before it is published) are probed first, at most four every 5 seconds (2026-10-21; before, they waited for the round-robin over every job). Confirmed redaction cancels inflight/completed jobs, publishes a durable `text:null` tombstone, and retries idempotent redactions of previous text-bearing private-journal results. Publication intents are stored before sending, so a lost ACK can still resolve the original event ID using the same transaction. This removes current server copies; it cannot recall text already downloaded/exported by another device.


## Headless deployment acceptance

`bundle/bin/worker transcribe-check /absolute/config.json < /private/voice.ogg`
is an explicit paid probe of the exact bundled `OpenAiTranscriber`. It reads at
most 64 MiB from stdin, converts OGG/Opus with the production codec pipeline,
uses `gpt-transcribe`, and prints only status, model, duration, estimated cost
and transcript character count. It does not initialize Matrix, enqueue jobs,
persist text or publish messages. Run it with a separate private state and
transient directory so it cannot contend with the daemon's session lock. Paid
uncertainty is not retried; select recordings explicitly before invoking it.

For transcription-only rollout set `allowConversationSends: false` (as in the
example). The final Matrix transport then refuses both conversation sends and
after-reply receipts before touching the session. Encrypted journal results
remain available after enrollment and pairing. The default for existing configs
which omit this field remains true, preserving scheduled-send behavior.
A successful stdin probe proves the deployed codec/provider path, not private
journal enrollment, trusted command ingestion, decryption or result delivery.


## Explicit local Beeper sources

`deploy/personal-worker-source.service` is the matching adapter template for the
existing `eouser` Beeper account and `personalworker` socket group. It confines
network access to loopback and bounds the complete adapter cgroup to 512 MiB
RAM (256 MiB pressure threshold), no swap, 32 tasks and one CPU core. Stop/OOM
cleanup includes every child in the cgroup; restart bursts are bounded to five
starts per five minutes. Check the account and private paths before installing
on another host. These limits protect other services even if a future adapter
regression leaks a process; they are not evidence that an installed unit has
these properties.

Cloud Matrix does not expose the local bridge rooms ending in `:beeper.local`.
Set `localSourceSocket` to `/run/personal-worker-source/source.sock` only when
installing `deploy/local_sources.py` under the existing Beeper service account.
The worker retains its separate verified Matrix device, SQLCipher state and
E2EE command/result journal; no Beeper API token is copied to its credentials.
The adapter has no OpenAI key. Its socket is 0660 inside a 0750 runtime directory,
shared only with the worker group, and its service permits loopback networking.

The adapter reads the existing account's private, owner-only
`~/.beeper/targets/server.json` and talks directly to the pinned HTTP server at
`127.0.0.1:23374`. It launches no Beeper CLI, updater or child processes. The
token remains in the source service; it is never passed to the worker. Proxy
variables and redirects cannot change the destination. It checks the profile
directory and current account through `GET /v1/app/setup`, maps `(roomID,eventID)`
exactly in a read-only index database, and retrieves that exact numeric message
ID with the read-only message API. Only ordinary, single-attachment voice notes,
Telegram round videos, other videos (`video/mp4`, `webm`, `quicktime`, `3gpp`,
`3gpp2`, `x-matroska`, `x-m4v`, `x-msvideo`; not GIF/sticker) and other audio
are exportable. Rounds are classified before ordinary videos. `/recent` lists
`video`/`audio` items only when the request carries `kinds` (this worker sends
`["voice","round","video","audio"]`), so an older worker never receives a kind
it would reject. Metadata responses add declared `durationMs` and `fileSize`. Deleted, disappearing,
view-once, protected, unsupported and oversized inputs fail closed. The sole API
write is `/v1/assets/download` for the selected attachment; file results must
resolve inside Beeper's private directory. Metadata is checked again after
materialization and after transfer to the worker. Metadata responses add
`kind: voice|round`; the wire mode stays `audio` and means "approved media
bytes". This does not provide generic local schedules/reminders.

A round must be exactly one `type: video`, `mimeType: video/mp4` attachment,
not GIF/sticker/voice, `0 < fileSize <= 64 MiB`, at most 60 s (+1.5 s
tolerance) and square (±2 px) at most 640 px where the source reports
duration/size. Round evidence is an explicit boolean field in the canonical
index model; because the production field name is unverified, the adapter
honours `fi.mau.telegram.round_message`, `round_message`, `isVideoNote`,
`videoNote`, `isRoundVideo`, `roundVideo`, `isRoundMessage` and `isRound` at any
depth of the message/attachment (a false or non-boolean value refuses). Without
such a field the documented fallback applies: video/mp4 **and** measured square
<= 640 px **and** measured duration <= 60 s **and** a Telegram source (the
account fields of the indexed message, or the Telegram label of the requesting
device's room). For an explicit request the API's documented `size`/`duration`
may complete a canonical row that lacks them; restrictions are always checked
on the canonical row first. The worker accepts `video/*` only as `video/mp4`
with `kind: round` (`invalid_round_format` otherwise) and bounds round exports
to 64 MiB. Duration values above 1000 are read as milliseconds, smaller ones as
seconds (Beeper API documents seconds, Matrix uses milliseconds); the worker's
own measurement is authoritative. Verify the canonical field names read-only on
the server before relying on automatic round detection; manual and app catch-up
requests carry the Telegram label and work with the fallback.

`POST /recent` (`{accountId, cursor, sinceMs, limit <= 200}`) verifies the
account through `GET /v1/app/setup`, then reads only the index:
`SELECT … FROM mx_room_messages WHERE id > cursor ORDER BY id LIMIT n`. It
returns `{cursor, items: [{roomId, eventId, kind, durationMs, network,
timestampMs}]}` for incoming (`isSender` false, sender not the account),
not deleted/edited, exportable voice/round rows in `:beeper.local` rooms and not
older than `sinceMs` when the row has a timestamp. A null cursor returns the
current maximum ID and no items. No sender, text, media, file path or token is
returned and no message/media API is called. The worker serializes its own
requests to the single-slot adapter, so a scan or deletion audit never makes a
running export fail; a busy scan is skipped until the next interval.

One request runs at a time; overload fails immediately rather than creating
unbounded threads. API calls have a 30-second deadline and a 2 MiB JSON limit.
Audio streams in 64 KiB chunks instead of allocating a second copy of up to
250 MB. Client socket reads and writes time out after 15 seconds of inactivity.
Each read-only SQLite connection is closed explicitly, including error paths.

The worker owns and closes its underlying Matrix HTTP transport, active local
source requests and reminder-relay requests during shutdown before disposing
storage. The deployed resource limits, native session check and measured clean
shutdown are recorded in the [2026-10-17 acceptance](../../session-logs/2026-10-17-worker-resource-repair.md).

`deploy/admin.sh inspect|pair|enqueue|verify` runs offline administration under
the worker account while the daemon is stopped. Pairing reuses an unambiguous
self-only journal or creates the same private E2EE room/account-data pointer as
the app. It pins a snapshot of the account's currently verified, valid devices;
future devices require another explicit pairing operation. The HTTP guard
refuses non-journal sends, plaintext sends, room joins/invites and read activity.
`enqueue` accepts only the private, explicit manifest of at most three source
references, uses deterministic transaction IDs, and never retries an uncertain
paid job. `verify` fetches the accepted result events and checks fresh encrypted,
authenticated decryption against the encrypted job ledger, without printing text.
Use `session.sh enroll` to resume interrupted anonymous enrollment with the
existing cipher; an already authenticated session is reused rather than logged
in again. Existing paired state is never reset.

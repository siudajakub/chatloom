# Personal Matrix feature worker

This is a separate, silent Matrix device. Android/macOS keep their own Matrix transport. The worker consumes only authenticated encrypted personal journal commands from explicitly paired, verified devices. It never automatically transcribes all messages and never generates replies to contacts.

## Build and synthetic verification

Use Dart 3.13.3 and Rust 1.99.0 (isolated toolchains work), a C compiler, and ffmpeg (optional ffprobe). From `worker/`, run `bash scripts/build-native.sh`, `dart test`, then `bash scripts/native-spike.sh`. The build uses `dart build cli`, since `dart compile exe` does not bundle SQLCipher native assets.

Matrix SDK is the adjacent `packages/matrix` vendor, upstream commit `355bf1d2d471ef2ab578d83a14a684cea7c07a1c` with the parent application's central diagnostic sanitizer. Vodozemac Dart 0.8.0 uses Rust bindings tag 0.8.0, peeled commit `1902d5ded6a3d8c2fc120168f0e08d60d71f58b5`, locked Cargo dependencies. The bundle contains SQLCipher and the Vodozemac native library. No account is needed for the native spike.

## Media runtime without system packages

For Linux without ffmpeg/ffprobe, run `bash scripts/setup-media-runtime.sh /absolute/project/runtime`. The script creates a dedicated Python venv and downloads only the pinned `imageio-ffmpeg==0.6.0` binary wheel from PyPI. All temporary files and package caches stay in that project directory; it does not use sudo, change system packages, modify HOME, or install a global executable. The [official imageio documentation](https://github.com/imageio/imageio-ffmpeg) confirms that its wheels bundle native ffmpeg. This wheel does **not** provide ffprobe.

For development, load the generated `runtime.env` with `set -a; . /absolute/project/runtime/runtime.env; set +a`. `FFMPEG_PATH` selects the exact wheel binary and an empty `FFPROBE_PATH` explicitly uses the duration fallback. Constructor paths take precedence over these variables; otherwise names are resolved through PATH. `runtime.json` records the pinned package version, actual FFmpeg version and SHA-256 of the executable.

When ffprobe is absent, the worker decodes the selected audio with the same configured ffmpeg binary into a null output and derives duration from validated machine-readable `out_time_us` progress ending in `progress=end`. It does not invent duration or claim that ffprobe exists. Malformed audio, failed conversion, cancellation, oversized output and process timeouts stop before any provider upload and clean the plaintext work directory. A configurable process timeout defaults to ten minutes.

Every probe, decode and conversion restricts input protocols to `file,pipe` and demuxers to `ogg,mp3,wav,mov,aac,matroska,webm,flac`; playlists and network-backed formats are rejected. Media children start without the parent's environment and receive only PATH, so provider keys, HOME and service credentials are not inherited. Tests include a disguised playlist with local HTTP canary and private-file reference, and verify zero fetches/uploads, as well as a child-environment witness. The flags follow [FFmpeg format](https://ffmpeg.org/ffmpeg-formats.html#Format-Options) and [protocol](https://ffmpeg.org/ffmpeg-protocols.html) documentation.

This filtering is not a process sandbox and does not establish safety against codec memory-corruption attacks. The current architecture uses a separate service account, systemd restrictions, protocol/demuxer limits, a clean child environment and temporary-file cleanup. Additional codec isolation is optional future hardening. `requireCodecSandbox` defaults to false; when explicitly true, transcription refuses before decoding or uploading until a sandbox is implemented, while schedules/reminders keep working. Do not treat binary availability as proof of isolation. A future implementation should bind the verified codec binary and required libraries read-only, expose only the per-job work directory, hide HOME/credentials/Matrix databases and unshare networking. On the checked VPS, `bwrap` was absent; no such isolation is claimed.

For deployment, the operator must install that verified binary into a readable, executable service location such as `/opt/personal-worker/media/ffmpeg` and set `FFMPEG_PATH` there (and `FFPROBE_PATH=`) in the service environment. The service's `ProtectHome` and dedicated account make a developer's private venv unsuitable as its deployment path. Keep the binary checksum and wheel license material with the deployed artifact. These source files and setup script do not alter the live service.

Media tests deliberately fail when no ffmpeg runtime is configured, instead of silently skipping. They cover real WAV silence, OGG Opus, missing ffprobe fallback, input over 25 MB with real splitting, oversized output rejection, process timeout, missing provider key, cancellation, paid uncertainty and cleanup, using mocked OpenAI responses only.

## Enrollment and pairing

Copy `config.example.json` into a private operational directory outside the repository; choose absolute paths. Set umask 077. Run `bundle/bin/worker enroll CONFIG` interactively as the future service account. Password, existing recovery key and OpenAI key are entered with terminal echo disabled; no secret is printed. Enrollment preserves any existing session and refuses reset. After an interrupted enrollment, `worker restore CONFIG` unlocks the existing session with the existing recovery key.

The credentials JSON contains `databaseCipher` (64 hexadecimal characters) and optional `openaiApiKey`; the file must be mode 600. No token is copied from browsers or Beeper. Matrix session credentials are stored inside the encrypted SDK DB. Keep an independent protected copy of the database cipher before any operational migration; losing it does not authorize deleting the DB or session.

The app creates a private encrypted room with `pl.personal.client.journal.v1` state `{ "schema": 1 }`, and sends an encrypted `worker.pairing` operation. Configure that room ID and explicitly paired Android/macOS device IDs privately in `trustedDeviceIds`. The private `pairing.json` produced on enrollment contains the worker device ID for app pairing. `worker check CONFIG` verifies membership, encryption, device trust, and actual decryption of an authenticated personal event; a Verified flag alone is insufficient.

Only then start `worker run CONFIG`. The systemd unit is a deployment template; these files do not install or start a service. A worker lock protects all session commands before SDK initialization. The deployment template uses a dedicated account, encrypted state, systemd credentials, private transient storage and no access to Beeper/Hermes service secrets.

## Wire contract

All commands/results use the frozen `PersonalOperation` schema 1 and custom `personalEventType`. Result operations have unique IDs per transition and increasing entity revisions. ACK/status and job changes are persisted atomically; journal publication uses a stable Matrix transaction ID and a durable outbox. Failed publication resumes with the same transaction ID on the same worker device.

* `transcript.request`: full `TranscriptionJob` JSON. Only source, ID and optional language are accepted from the caller. Model is `gpt-transcribe`. `transcript.cancel` cancels that entity at the current revision. Results use full job JSON plus revision and accepted operation ID. Explicit re-request of a failed/unknown/cancelled job is supported with the current base revision; paid uncertainty never retries automatically.
* `schedule.create/update`: full `ScheduledSend` JSON, canonical account/room target and text or pre-uploaded encrypted media content. The worker owns state, revision, transaction ID and dispatch device. `schedule.cancel/sendNow` targets the entity with its current base revision. Results add error/event status. Initial dispatch over five minutes late pauses; a previously attempted ambiguous dispatch continues using its original transaction ID. A device change or failed verification pauses dispatch.
* `reminder.create`: `{id, conversation, dueAt, untilReply}`. `reminder.cancel` targets the current revision. `reminder.result` carries the durable reminder JSON; due results set `due: true`, so clients can display local notifications. `untilReply` means waiting for the recipient response (UI wording: Oczekiwanie na odpowiedź rozmówcy). It cancels after a newer received Message/Sticker in that source room, never on an own message, edit, reaction, redaction or journal event. History is paginated to the createdAt frontier; missing recipient keys or incomplete history keep the reminder pending as waitingKeys/waitingSync and retry without a false due alert or implicit read markers.
* `metadata.put`: direct JSON value (a single `value` wrapper is also accepted). `metadata.delete` creates a tombstone. Conflicts preserve both `existingValue` and `proposedValue`, with neither silently replacing the other.
* `worker.heartbeat`: health, verification state and pending count. No source IDs or messages in diagnostics or heartbeat.

Automatic background work sends no typing, public/private read receipts or online presence. `syncPresence` is offline from initialization. A bound `readUpToEventId` is sent only after an explicitly authorized scheduled reply has been accepted; background audio processing and reminder scans never mark rooms read. No arbitrary Beeper Client API fallback exists.

## Reminder wake relay

The private journal is muted; a same-user Matrix worker cannot rely on standard Synapse pushrules because Synapse suppresses events from the recipient's own user before evaluating those rules. Encrypted reminder results therefore remain encrypted and do not add cleartext alert markers.

For closed-app delivery, optionally configure `reminderRelayUrl` as `http://127.0.0.1:8088/internal/reminder` and add `reminderRelayToken` to the protected credentials JSON. Only literal loopback HTTP, the exact path, and no userinfo/query/fragment are allowed. The worker POSTs only `{hintId, emittedAt}` using the separate Bearer credential; the identifier is a stable opaque 64-character SHA-256 value. It contains no room, person, source event ID or text. Redirects are refused.

After the homeserver accepts a due `reminder.result`, the worker commits journal ACK and wake-hint enqueue atomically. Pending hints survive restarts. The relay must deduplicate the identifier across retries; timeout/503 retains the identical hint with thirty-second default backoff and honors the relay Retry-After. Only 2xx removes it. A 2xx denotes gateway/FCM acceptance, not physical device delivery. An absent relay URL or credential leaves hints pending and heartbeat reports `reminderPush: not_configured` with their count. No live service or credential is configured by these source changes.

The app must fetch and decrypt the journal, verify the trusted worker result and deduplicate the reminder before showing a generic notification. Actual closed-app Android/macOS delivery and private-account interoperability remain device/runtime gates.

## Transcription boundaries

The worker sends audio only to OpenAI, using the configured private key. It strips media metadata, converts to mono MP3 and splits into 15-minute chunks below 25 MB. Duration and estimated cost (USD 0.0045/minute) are published while processing; there is no budget cap. Timeout/connection uncertainty becomes `unknown`, including crash recovery during a paid request. A user can explicitly retry, with possible additional cost. Cancellation cannot undo a charge already accepted by the provider. Temporary plaintext audio is removed on success, failure, cancel, and the next startup after a crash.

OpenAI model and price were verified against [official model documentation](https://developers.openai.com/api/docs/models/gpt-transcribe), and format/size/language fields against [file transcription documentation](https://developers.openai.com/api/docs/guides/speech-to-text), on 2026-10-04. Pricing is an estimate, not invoiced usage.

## Legacy import

`bundle/bin/migrate SOURCE.sqlite EXPLICIT_MAPPING.json CONFIG` is a dry run. `--apply` creates an independent encrypted source backup, then imports only explicitly mapped completed results into the worker's encrypted jobs and journal outbox. It never connects to Matrix/OpenAI/Beeper or sends to anyone. Stop the old consumer before live migration, and stop the new worker while applying the import.

Mapping is an array of `{ "legacy": { "chatId": "...", "messageId": "..." }, "source": SourceEventRef }`. No mapping by title, text, timestamps or guessed IDs is allowed. Unmapped rows stay unimported. The original SQLite source remains read-only. No deletion of legacy state occurs.

## Verification boundaries

Synthetic tests prove state machines, encrypted storage, cleanup, conversion, request shape, ambiguous-send retries and migration safety. Native spikes prove Linux/macOS library loading and encrypted SDK initialization. They do not prove private-account enrollment, source-history decryption, bridge delivery, OpenAI account permissions, native app notifications or real-device battery behavior. Those gates require the user's controlled pairing and designated test recipient, with no key reset or browser-auth export.

A private encrypted journal can be decryptable by other authorized devices on the same Matrix account under standard SDK key sharing. Hiding it in this client's inbox does not hide it in official Beeper. Removing a device cannot recall keys or transcriptions already downloaded by that device.

Source deletion: the worker checks fresh source-event metadata before a paid request and again before publishing its result. Unknown status (missing keys, 404 or network failure) does not prove deletion and never triggers another paid request automatically. After journal reconciliation, a bounded round-robin audit checks at most four explicitly requested transcript jobs every 30 seconds; it never sweeps room history or downloads audio. Confirmed redaction cancels inflight/completed jobs, publishes a durable `text:null` tombstone, and retries idempotent redactions of previous text-bearing private-journal results. Publication intents are stored before sending, so a lost ACK can still resolve the original event ID using the same transaction. This removes current server copies; it cannot recall text already downloaded/exported by another device.

# Read-only browser acceptance transport barrier

This directory belongs to the acceptance harness. It does not modify the app,
read profiles or credentials, or attach to a live browser during its tests.
Node 22 with built-in `WebSocket` is sufficient; no package install is needed.
Verified locally: `~/.local/bin/node`, v22.23.1. Locate with `rtk which node`.

Run the guard **before** account navigation, using the existing dedicated browser:

```sh
rtk ~/.local/bin/node scripts/browser_acceptance/run_guard.mjs http://127.0.0.1:9238 $PERSONAL_CHAT_ROOT/artifacts/browser-acceptance-2026-10-15/transport-guard.json
```

Keep this process running throughout acceptance. Root owns the live CDP session;
subagents must not execute that command. `GUARD_READY` means the initial HTTP
barrier installed successfully. It does not assert application acceptance.
Before every action, the root driver must verify the process is still alive,
the evidence `pid` matches that process, current time is before `expires_at`,
and `guarded=true`, `harness_errors=0`, `unresolved_detaches=0`,
`unsupported_transports=0`. Compare `blocked_attempts` before and after actions.
A forbidden attempt means application **FAIL**, even when transmission was
prevented. Zero observed attempts is not a general privacy/E2EE/history PASS.

Evidence uses an atomic rename and serialized one-second publication. It
contains fixed codes and aggregate counters, a PID and heartbeat timestamps.
The snapshot expires after three seconds. It never records request URLs,
headers, bodies, IDs, target names, private console output, or CDP error text.

## HTTP scope and policy

The browser session auto-attaches existing and future page, iframe, dedicated
worker, shared-worker and service-worker targets. New targets wait for the
debugger while the guard installs. Every HTTP request is paused at the CDP
Fetch **Request** stage; forbidden requests receive `BlockedByClient` instead
of continuation. Existing requests started before attachment are **NOT COVERED**.

Dedicated workers expose Network but reject their own `Fetch.enable` in the
tested Chrome. Their requests are intercepted by their owning page's Fetch
agent. The owning session must be guarded; an orphaned worker cannot make
readiness true. The synthetic test proves immediate dedicated-worker fetches
are denied before the fixture receives them. Thus `page:blocked` counters can
include dedicated-worker requests; `worker:network_observed` separately proves
worker Network coverage.

Service-worker Fetch is installed before startup is released. Chrome's
`Network.enable` waits for initialization, so its Network observation is enabled
after the HTTP barrier and debugger release. The synthetic service worker makes
its forbidden requests immediately at top-level startup, before activation or
any message from the page. Page requests bypass service-worker handling while
acceptance runs; service-worker-originated HTTP remains guarded independently.
The harness does not unregister a service worker or clear its storage.

All HTTP methods except GET/HEAD/OPTIONS are denied by default, including:
messages, encrypted room sends, reactions, redactions, state, receipts,
read markers, typing (including `false`), presence (including `offline`), room
membership, account data, settings, devices, login/logout and media uploads.
This is intentionally stricter than the app's incognito policy. Incognito
permits manual read grants, typing cancellation and offline presence; ordinary
messages are not generally suppressed by incognito. Do not test incognito by
deliberately sending a real request.

Narrow natural Matrix crypto exceptions remain observable separately:
POST `keys/query`, `keys/claim`, `keys/upload`, and PUT `sendToDevice` for
encrypted/key-request/secret/verification protocol events listed in the
classifier. This is transport permission for the existing SDK, not a proof of
crypto correctness or an authorization to initiate verification/recovery.
GET sync requires exactly one `set_presence=offline`; an absent or competing
presence parameter fails closed. The guard does not rewrite application requests.
OPTIONS sync CORS preflights are allowed independently; the actual authenticated
GET is still intercepted and checked. Counters include an allowlisted HTTP
method suffix and fixed sync reasons (`options_preflight`, `presence_offline`,
`presence_missing`, `presence_non_offline`, `presence_multiple`, `bad_method`).
No URL, header value or presence query value is exported.
Default-denied client writes additionally expose a fixed `denied_endpoint`
label such as `filter_create`, `user_search`, `server_search`, `token_refresh`,
`keys_signature`, `keys_backup` or `other`; this diagnoses SDK traffic without
granting new transport permission. Failed CDP commands expose fixed
`command_failed:fetch_fail|fetch_continue` and handler-stage/error-category
counters. A generic `server_error` does not establish that a browser abort
caused the error. Unconfirmed errors continue to make readiness false. The snapshot
records `policy_revision=2026-10-15-cancellation-proof-v6`.

After the restored same-profile reproduction positively identified four blocked
POSTs as `filter_create`, root approved one natural sync bootstrap exception:
POST exactly `/_matrix/client/v3/user/{nonempty}/filter`, with no query, path
prefix/suffix or duplicate slash. It is counted as `natural_sync_filter`.
The SDK `_checkSyncFilter` uses this route when its stored filter ID is absent.
This creates an event-filter definition; it does not alter account data, device
trust, membership or outgoing events. Other versions, write methods and sibling
paths remain denied.

After live fixed codes identified `keys_backup` PUTs, source review established
the existing SDK auto-upload path: `encryption.dart:68` starts the sync listener,
`key_manager.dart:838` uploads queued sessions after sync, checks the existing
backup algorithm/public key, and `key_manager.dart:927` calls aggregate
`putRoomKeys(info.version, roomKeys)`. The database takes at most 50 queued
sessions. `generateUploadKeysImplementation` encrypts the session exports before
forming `session_data`; the guard does not implement or replace cryptography.

Root approved only PUT exactly `/_matrix/client/v3/room_keys/keys` with one
nonempty `version` query and no extra query/path components. Its JSON body must
be at most 1 MiB and match the compact SDK JSON representation exactly; this
rejects duplicate/overwritten keys before they can hide raw extra fields. The
schema permits only `rooms` maps, `sessions` maps, at most 50 sessions total,
nonnegative integer `first_message_index`/`forwarded_count`, boolean `is_verified`
and `session_data` containing exactly nonempty base64-shaped `ephemeral`,
`ciphertext`, `mac` strings. Unknown fields, including plaintext `session_key`,
are rejected at every schema level. The empty `rooms` map is harmless and may
occur when SDK export skips invalid queued sessions. No body/identifier is
logged or retained. Accepted uploads count as `natural_crypto_backup`; rejected
ones expose fixed `backup_rejected` reason codes.

This is an envelope-shape check, not cryptographic verification. The existing
SDK checks the backup key, and the homeserver enforces the current version.
Room/session-specific PUTs, all DELETEs, backup-version creation/update/reset,
cross-signing/trust and other account writes remain denied.

V6 changes no HTTP permissions. Only an already-allowed `Fetch.continueRequest`
failure with CDP code `-32602` and the exact fixed Chromium missing-interception
reason can enter cancellation correlation. It needs a matching request's
`Network.loadingFailed(canceled=true)` on the same session or a proved
`owner_fetch` worker ancestry, or destruction of that owning target. Network IDs
are correlated only in memory within that scope; unrelated sessions/IDs, plain
detach, generic invalid-parameters errors and `canceled=false` are insufficient.
Facts are bounded to 15 seconds/2048 entries. A pending proof check makes
`guarded=false` for up to 500 ms. Without positive proof, the error becomes
sticky. The destroyed-target timestamps cover the short acceptance process
lifetime. `confirmed_cancellations` and fixed proof counters explain recognized
races; their diagnostic `command_failed` counter remains recorded while
`harness_errors` stays zero. Forbidden attempts are never removed and a failed
`Fetch.failRequest` is always a sticky harness error, even if cancellation occurs.

This handles observed, positively proved cancellation; it does not assert that
every browser reload emits enough evidence. The native no-hook reload fixture
can omit positive cancellation and must remain unready. Do not inject fixture
AbortController hooks into the real app to claim its reload passed.

Unexpected detach invalidates readiness until CDP explicitly reports target
destruction; loss of an owning page also invalidates inherited worker coverage.
A debugger disconnect removes its interception: stop acceptance immediately.
The harness does not claim to preserve protection after process/browser failure.

## Unsupported transports

This barrier covers **HTTP only**. Fetch and `Network.setBlockedURLs` do not
prevent websocket handshakes in the tested Chrome. A new WebSocket/WebTransport
event invalidates readiness, but that detection occurs after creation and must
not be represented as prevention. Connections existing before attachment are
**NOT COVERED**. Root must establish that the tested Matrix path uses HTTP,
avoid calls/playback or other features that introduce unsupported transports,
and stop on any unsupported-transport counter. This harness cannot establish a
safe boundary for an arbitrary application using those transports.

## Synthetic verification

```sh
rtk ~/.local/bin/node --test scripts/browser_acceptance/test_transport_guard.mjs
rtk ~/.local/bin/node scripts/browser_acceptance/synthetic_transport.mjs
rtk ~/.local/bin/node scripts/browser_acceptance/synthetic_transport.mjs --raw-reload-negative
```

The second command starts a fresh disposable headless Chrome profile and a
loopback fixture. It never connects to CDP9238 or reads the real browser profile.
`CHROME_BIN` can select another local Chrome executable. Only its own temporary
profile/process are removed on exit; the live browser remains untouched.

Verified 2026-10-15: fifteen pure suites PASS. Actual Chrome transport fixture PASS:
page, immediate dedicated-worker and top-level service-worker each reject 13
forbidden HTTP operations. Two additional unsafe sync GETs bring the total to
**41 rejected requests, with 0 forbidden requests transmitted**.
The fixture receives **21 natural filter/sync/crypto requests**. No harness errors; all HTTP targets
are guarded before the deliberate unsupported-transport probe. The subsequent
websocket upgrade reaches the synthetic fixture once and invalidates readiness,
explicitly proving that websocket prevention is unavailable. The snapshot's
application FAIL is expected because synthetic forbidden operations were attempted.
These results do not establish real-account history, receipts, E2EE or native
Android behavior.

The initial classifier incorrectly rejected every sync OPTIONS request. A
different-origin synthetic CORS server now verifies a genuine browser preflight
caused by a fictional Authorization header: three OPTIONS requests pass, one
offline GET transmits, and two actual GET requests with missing/online presence
are blocked before transmission. This preserves the original 27 blocked
communication/account writes and adds two blocked unsafe sync GETs. The v5 backup
fixture adds 12 blocked malformed/duplicate-envelope/delete/new-version attempts.
The fixture therefore reports 41 deliberate blocked attempts, 21 same-origin natural requests
and one additional successful cross-origin offline GET. Historical counters
without methods/reasons cannot distinguish preflight from actual GET and remain
unclassified; retain the original evidence instead of rewriting it as an app bug.
The v4 fixture also proves one exact filter-definition POST succeeds from each
page, dedicated-worker and service-worker target while the forbidden writes stay
blocked. The earlier four POSTs without endpoint labels remain an inference;
their classification is not retroactively proven by the later reproduction.
The v5 fixture proves one aggregate encrypted-envelope upload succeeds from
each page/worker/service-worker while backup deletion and version creation remain
blocked. Pure tests additionally cover all route/query boundaries, per-room and
per-session writes, schema/type/plaintext/duplicate-key rejection, the 1 MiB
body limit and the total 50-session limit.

The default real-Chrome fixture holds actual continuation commands until four
cancellations occur: page AbortController, dedicated-worker AbortController,
unassisted worker termination, and reload with a fixture-only beforeunload
AbortController. All four produce matched positive proof, zero canceled requests
reach the fixture, and readiness is retained with zero harness errors before
the unsupported-websocket probe. The worker-termination case proves the
`target_destroyed` branch; the other three prove `network_canceled` including
owner-page Fetch/worker Network correlation. The explicit negative mode leaves
the raw reload without a cancellation hook: its missing-interception error has
no positive proof and correctly ends with one sticky harness error/unready.
That negative mode reports PASS only because it asserts the required failure;
it does not represent application acceptance.

Protocol references: [Target auto-attach](https://chromedevtools.github.io/devtools-protocol/tot/Target/)
and [Fetch Request-stage interception](https://chromedevtools.github.io/devtools-protocol/tot/Fetch/).
The fixed missing-interception reason is grounded in
[Chromium's interception-job lookup](https://chromium.googlesource.com/chromium/src/+/lkgr/content/browser/devtools/devtools_url_loader_interceptor.cc).

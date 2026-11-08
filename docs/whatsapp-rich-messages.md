# WhatsApp links and read-only polls

ChatLoom can display URL buttons received through a compatible WhatsApp bridge.
Opening or copying one uses the received HTTP(S) URL; it does not send a
WhatsApp button response. The destination site still receives an ordinary
browser visit. No link preview is fetched by this feature.

Polls show their question, options, the user's available selection and results
from received Matrix relations. Missing results are unknown, not zero. Results
can be incomplete when the bridge lacks earlier votes or their decryption data.
Voting, creating/ending WhatsApp polls and answering business buttons/lists are
disabled in this release, including in the final outgoing authorization.
Other networks keep their existing poll behavior.

This does not make an unofficial WhatsApp bridge authorized or immune to account
restrictions. WhatsApp warns that linking unofficial applications can cause
temporary or permanent account bans:
https://faq.whatsapp.com/1217634902127718/

## Incoming bridge contract

The bridge keeps a readable standard `body`/`formatted_body`, including links,
for clients that do not understand this extension. It additionally supplies:

```json
{
  "pl.personal.chat.whatsapp.interactive": {
    "schema_version": 1,
    "body": "A fictional event update",
    "formatted_body": "<b>A fictional event update</b>",
    "actions": [
      {"kind": "url", "label": "View post", "url": "https://example.org/post"}
    ]
  }
}
```

The extension's body is the header, main text and footer before URL fallbacks
are appended. Unsupported action instructions remain there. `formatted_body`
is optional Matrix HTML and uses the existing HTML renderer and settings.
The application makes a presentation copy of the content; it never rewrites
the stored event or its event type. Existing media/encrypted-file properties
are retained. Business cards remain separate from adjacent photo albums so
their buttons cannot disappear on a hidden album member.

Version 1 contains URL actions only: no raw native-flow JSON, callback tokens,
phone dialing or automatic replies. The parser rejects unknown versions,
malformed payloads, more than 20 actions, extensions above 64 KiB, labels over
1024 characters and URLs over 8192 characters. URLs must be HTTP(S), have a
host and no user info, raw whitespace or encoded control characters. Ordinary
percent-encoded spaces are allowed. Invalid data retains the standard fallback.

The same validated URLs feed Copy link and the profile's Links section.
Forwarding removes the interactive extension and leaves ordinary readable
links; it cannot address an action back to the original conversation.

## Poll compatibility

The receive adapter supports disclosed WhatsApp MSC3381 polls with 2–12 unique
options of at most 100 characters, whether the start is a dedicated
`org.matrix.msc3381.poll.start` event or a nested payload inside
`m.room.message`. It does not require the legacy top-level MSC1767 text field.
Unsupported variants retain their textual fallback. No global `extev_polls`
configuration change is required.

Existing Matrix `/relations` fetching supplies paginated/decrypted references.
Loading starts outside widget build, requests share the SDK's timeline cache,
and detached rows cannot apply old completion state. The latest response per
sender replaces previous choices; only valid available choices contribute
counts. Empty, known redacted or invalid responses cannot revive an older
choice. The feature
does not ask WhatsApp to reload message history.

WhatsApp operation policy uses the source room's bridge protocol state
(`whatsapp` or `whatsappgo`), independently of incognito and the selected
network in a merged composer. Blocking is applied before local echo and at
the SDK's final send authorization. Merely rendering a poll has no vote
callback. A bridge capability advertising polls does not override this policy.

## Verification and release

Run checks sequentially through `scripts/flutter-queue.py` after sourcing the
project's `scripts/devbox-env.sh`. Focused suites:

```sh
rtk python3 scripts/flutter-queue.py test \
  test/notion/whatsapp_message_test.dart \
  test/notion/whatsapp_rich_message_adapter_test.dart \
  test/personal/whatsapp_rich_policy_test.dart
rtk python3 scripts/flutter-queue.py analyze lib
rtk python3 scripts/verify-personal.py --design-strict --dart /path/to/dart
```

Pure parser/aggregation tests are in
`packages/personal_core/test/whatsapp_rich_message_test.dart`. The presentation
harness includes the primitive tests, dark/light goldens and a 320 dp / 200%
RTL capture. Fixtures are
fictional; passing tests do not establish live-account or native-device behavior.

Release the tolerant client before the patched bridge. Before a bridge rollout,
identify the actual portal/service and running executable revision, preserve a
coherent private backup and prepare the prior binary/config for rollback.
Retain the current database, keys and linked session. Do not re-pair, clear app
data, reset keys or restore an old live database merely to roll back a binary.
The source fork's runbook records its exact base and build backend; a local
development-service path does not establish the production revision.

Already-bridged messages containing only `<cta_url>` cannot be repaired by
guessing an address. No automatic history repair is included. New business
responses or voting require a separate implementation/review and explicit
acceptance of the remaining account risk; there is no user-facing switch that
silently enables them in this release.

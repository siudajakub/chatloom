# Voice to text in the composer

**Dictate a message** (**Dyktuj wiadomość** in Polish, the note-and-pencil
icon) is the third recording choice in ordinary and merged conversations,
beside the existing voice-note and round-video controls. It opens a large
dialog for recording, transcription and text review. On narrow screens those
controls share a row above the editor with the sending-source chip; on wider
screens they sit beside the editor. The existing controls still send their
original media types.

## Flow

1. Tap **Dictate a message** to start recording. Microphone permission uses the
   existing voice recorder and platform capture settings.
2. Stop and transcribe. The recording goes through the owner's private,
   encrypted journal to the worker and then to ElevenLabs Scribe v2 through
   OpenRouter. It is never posted to the recipient's conversation.
3. Review the complete transcript in the large editable field. Edit it if
   needed, then tap **Send message**. This explicit action sends ordinary text
   through the existing trust checks and encrypted durable outbox. Closing
   after acceptance means the send became durable; it does not prove remote
   delivery.

The dialog keeps text after a send failure. Close and Back ask to discard an
existing recording or text; tapping outside does not dismiss it. Cancelling
or leaving the dialog does not send a message. Changing account, sending
source, conversation, reply, thread, draft or the app's privacy state
invalidates the captured send context. A remaining unlocked review can be
copied when sending becomes unavailable. A privacy lock invalidates Send even
if the app is subsequently unlocked.

Backgrounding pauses capture, including when native startup or resume finishes
late. **Resume recording** is an explicit action. The review editor adapts to
keyboard space and remains editable until a send is pending; short windows
can scroll to the action.

## Privacy and limits

Audio and the transcript travel through the owner's private encrypted
journal and worker sync. The worker decrypts audio for the provider request;
ElevenLabs receives the audio through OpenRouter to perform transcription.
The recipient receives only the explicitly reviewed text. The app attempts
to redact the private source event after each attempt and cancels pending
work on discard. Redaction is best effort and is not proof that uploaded
media, synced job results or provider copies have been erased.

The recording is limited to five minutes and 10 MiB. The dialog stops near the
duration cap; the app and worker enforce the hard limits. The worker measures
the actual media before reserving the transcription estimate against a
separate $0.50 budget over the preceding 24 hours for outgoing dictation.
Source requests expire after 15 minutes; the app waits up to seven minutes
for a result. An uncertain paid request is not automatically repeated. A
manual retry can incur another charge, as the dialog explains.

The worker caps the encoded transcript result before private sync. The
recipient's network text limit is checked before sending; an over-limit
review stays editable and must be shortened, without silent truncation.

## Availability and release

This feature needs an updated app and an updated worker advertising
`dictation: ready` and `dictationVersion: 1` in a fresh, healthy, verified
heartbeat. An older worker does not confirm availability. The button remains
discoverable when the worker is unavailable and explains the requirement
before starting capture. Only one private dictation attempt per account can
be in flight. Existing incoming-message transcription and its GPT-plus-Scribe
timing pipeline remain separate from outgoing Scribe dictation.

There is no provider credential in the app. The worker uses its configured
OpenRouter credential. Real transcription incurs provider charges; offline
tests and synthetic screenshots do not make provider requests.

Local implementation, synthetic UI captures, app builds, worker deployment,
installation and physical-device acceptance are separate results. A
phone-sized Flutter test render demonstrates layout, not microphone capture,
keyboard behavior or delivery on a physical phone. Synthetic preview routes
use fictional content and do not establish worker or physical-device
acceptance.

UI contracts are documented in
[`notion-ui/SHARED-API.md`](notion-ui/SHARED-API.md#composer-dictation-and-compact-action-toolbar--2026-11-05).

Provider contract: [OpenRouter's ElevenLabs integration](https://openrouter.ai/blog/announcements/elevenlabs-on-openrouter/)
and [ElevenLabs speech-to-text documentation](https://elevenlabs.io/docs/overview/capabilities/speech-to-text).

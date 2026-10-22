<!--
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Privacy

ChatLoom has no analytics, advertising or crash-reporting service. It talks
only to the services below, and only those the user or operator configures.

| Party | What it receives |
|---|---|
| Your Matrix homeserver (default: Beeper, `matrix.beeper.com`) | Your account session and your messages, as for any Matrix client. End-to-end encrypted rooms stay encrypted; the Beeper bridges you use see the bridged networks' content. |
| Your contacts | Only what you send. New installs start in Incognito: read receipts, typing and presence are blocked unless you turn Incognito off; reading a chat manually sends a receipt only for that chat. |
| Push gateway (Android) | A device key, a short-lived Matrix OpenID proof of your account ID, your FCM token and, per notification, opaque room/event IDs and unread counts (`event_id_only` pushers carry no message content). The main Matrix access token is never sent. |
| Google Firebase Cloud Messaging (Android) | The FCM token, opaque routing IDs and delivery time; no message text or names. |
| Worker (optional, self-hosted) | A separate Matrix device of your own account. It reads only end-to-end encrypted journal commands from your verified devices, and media you ask it to transcribe, or that automatic transcription selects when both the synced user policy and the operator switch are on. Disappearing messages are never transcribed. It never replies to contacts. |
| Transcription provider (OpenAI, via the worker) | The audio track of the selected media, stripped of metadata. No text, names or chat IDs. |
| GitHub | The sign-in screen fetches a public list of recommended homeservers. |
| Call service | Calls in native Matrix rooms request a token from the homeserver's advertised LiveKit service, or from a fallback service when none is advertised. |

On the device, Matrix data is stored in an SQLCipher-encrypted database whose
key is held in the platform's secure storage; if secure storage is unavailable
the app refuses to open the database instead of falling back to plaintext. The
optional encrypted backup export is created only on request. Logs stay on the
device unless you share them.

The maintainer's deployment of the push gateway and worker serves only the
maintainer's account. If you build ChatLoom yourself, configure your own
gateway (see [push-gateway/README.md](push-gateway/README.md)).

<!--
SPDX-FileCopyrightText: 2019-Present Christian Kußowski
SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
SPDX-License-Identifier: AGPL-3.0-or-later
-->

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/brand/chatloom-lockup-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/brand/chatloom-lockup-light.svg">
    <img src="docs/brand/chatloom-lockup-light.svg" alt="ChatLoom" width="360">
  </picture>
</p>

<p align="center">
  <b>Every chat app. One calm, private inbox.</b><br>
  An open-source Beeper client for Android and macOS, built on Matrix and FluffyChat.
</p>

<p align="center">
  <img alt="Android" src="https://img.shields.io/badge/Android-arm64-3DDC84?logo=android&logoColor=white">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-Apple%20silicon-000000?logo=apple&logoColor=white">
  <img alt="Flutter 3.47" src="https://img.shields.io/badge/Flutter-3.47-02569B?logo=flutter&logoColor=white">
  <a href="LICENSE"><img alt="License: AGPL-3.0-or-later" src="https://img.shields.io/badge/license-AGPL--3.0--or--later-blue"></a>
</p>

<p align="center">
  <img src="docs/readme/hero.png" width="860" alt="Three ChatLoom screens: the unified inbox with network badges, a merged WhatsApp and Telegram conversation with a photo and reactions, and the Appearance settings in a vivid pink accent">
</p>

## Why ChatLoom

Your friends are spread over WhatsApp, Telegram, Messenger, Instagram, Signal
and Slack. ChatLoom signs in to your **Beeper** account and puts all of them in
one inbox that feels like a single, well-made app: one look, one set of
gestures, one place to search. Someone who writes to you on two apps becomes
**one conversation**.

It is built to be calm and private. **Incognito is on from the first launch**,
messages stay **end-to-end encrypted**, the local database is encrypted, and
ChatLoom never sends anything you did not send yourself.

## See it move

Every animation below is the app itself: its real Flutter widgets, recorded
frame by frame from a widget test with made-up people and messages
([how](docs/readme/README.md)).

<table>
<tr>
<td width="50%" valign="top" align="center">
<img src="docs/readme/inbox.gif" width="100%" alt="The inbox: chats from six networks with network badges, unread counts and pinned chats; the floating glass dock opens the network menu, filters the list to Telegram and back to all networks"><br>
<b>One inbox, every network</b><br>
<sub>Network badges on every avatar, pinned chats on top, unread at a glance. The glass dock filters by network in one tap.</sub>
</td>
<td width="50%" valign="top" align="center">
<img src="docs/readme/chat.gif" width="100%" alt="A conversation that merges WhatsApp and Telegram with a reply, a photo and reactions; a long-press lifts the message, the reaction bar springs out and a reaction lands; a double tap adds a heart"><br>
<b>One person, one conversation</b><br>
<sub>Maya on WhatsApp and Telegram, in one thread. Long-press for reactions and actions, double-tap for a quick heart.</sub>
</td>
</tr>
<tr>
<td width="50%" valign="top" align="center">
<img src="docs/readme/send.gif" width="100%" alt="Choosing Telegram in the composer's network menu, typing a message while the microphone morphs into the send button, and the sent bubble arriving marked via Telegram"><br>
<b>You choose where it goes</b><br>
<sub>A merged chat marks the app every message came through. Pick the network for your reply in the composer; typing turns the mic into send.</sub>
</td>
<td width="50%" valign="top" align="center">
<img src="docs/readme/voice.gif" width="100%" alt="Tapping Transcribe under a voice message: a shimmer while it works, then the transcript appears in the bubble"><br>
<b>Voice notes as text</b><br>
<sub>Transcribe any voice note or round video with one tap, or automatically within a daily budget, through your own worker. Only you see the transcript.</sub>
</td>
</tr>
<tr>
<td width="50%" valign="top" align="center">
<img src="docs/readme/stickers.gif" width="100%" alt="Opening the composer panel: the emoji tab, then a sticker pack; tapping a sticker sends it into the conversation"><br>
<b>Stickers, GIFs and emoji</b><br>
<sub>One panel for emoji, GIF search and sticker packs imported from Telegram links, with instant local search.</sub>
</td>
<td width="50%" valign="top" align="center">
<img src="docs/readme/swipe.gif" width="100%" alt="Swiping inbox rows: right marks a chat as read, left archives it and the list closes the gap"><br>
<b>Triage with a swipe</b><br>
<sub>Swipe right to mark read, left to archive (or pin; you choose). The row follows your finger and springs back.</sub>
</td>
</tr>
<tr>
<td width="50%" valign="top" align="center">
<img src="docs/readme/appearance.gif" width="100%" alt="Settings, Appearance: switching between muted, balanced and vivid colours, accent colours and light and dark themes re-themes the whole page instantly"><br>
<b>Make it yours</b><br>
<sub>Eleven accents or any colour you pick, from muted grey to vivid Messenger gradients, light or dark. Everything re-themes live.</sub>
</td>
<td width="50%" valign="top" align="center">
<img src="docs/readme/privacy.gif" width="100%" alt="Settings, Privacy and security: Incognito mode is on; turning it off enables the typing and read receipt switches, turning it back on suppresses them again"><br>
<b>Incognito by default</b><br>
<sub>No read receipts, typing or presence until you decide. A chat is marked read only when you do it yourself.</sub>
</td>
</tr>
</table>

And there is more:

- Telegram **round videos**: watch, record and send them
- A **photo and video editor** before you send: crop, draw, adjust, trim
- **Send later** and **reminders**, kept by your own worker
- Telegram-style **delivery ticks**, replies and in-chat search
- **Drafts, bookmarks and labels** synced over an encrypted journal
- **Instagram posts, reels and stories** play inside the chat
- **Bridge health**: the app tells you when a network's bridge stops responding

## Highlights

- **Every network you have on Beeper.** WhatsApp, Telegram, Messenger,
  Instagram, Signal, Slack and the rest of Beeper's bridges, filtered from the
  dock. Smart views for Unread, Unanswered, Groups, message requests, Low
  priority and Archive; Beeper's helper bots stay out of the way.
- **Privacy first.** Incognito from the first launch, an HTTP filter that
  blocks automatic read receipts, typing and presence, and *Hide for me* to
  hide a message on this device without deleting it for anyone.
- **End-to-end encrypted.** Matrix encryption unlocked with your recovery key;
  the local store is an encrypted SQLCipher database that is never reset
  silently.
- **Feels native.** A glass dock and headers, spring physics on the things you
  touch, Telegram-style swipe, long-press and predictive back, haptics where
  they help, reduced motion and Battery Saver respected.
- **Yours to run.** Notifications through your own push gateway; sync,
  transcription, reminders and send later through your own worker. Without
  them ChatLoom is still a full chat client.
- **Android and macOS** from one codebase, with the same look and features
  (the Mac has no system notifications).

The full feature tour, everyday tips and the self-hosting overview are in the
**[user guide](docs/GUIDE.md)**.

## Install & deploy

ChatLoom is built from source for now; there are no store releases.

| You want to | Read |
|---|---|
| Set up the toolchain, build and run the tests | [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) |
| Build and sign the Android app | [android/README.personal.md](android/README.personal.md) |
| Build the macOS app (Apple silicon) | [macos/README.personal.md](macos/README.personal.md) · [docs/macos-client.md](docs/macos-client.md) |
| Run the bridges on your own server | [docs/SELF-HOSTING.md](docs/SELF-HOSTING.md) |
| Run the companion worker (sync, transcription, reminders, send later) | [worker/README.md](worker/README.md) |
| Get Android notifications through your own push gateway | [push-gateway/README.md](push-gateway/README.md) |
| Read the maintainer notes (Polish) | [README.personal.md](README.personal.md) |

Security and privacy: [SECURITY.md](SECURITY.md) · [PRIVACY.md](PRIVACY.md) ·
[CONTRIBUTING.md](CONTRIBUTING.md). The logo, app icons and brand rules are in
[docs/brand/BRAND.md](docs/brand/BRAND.md).

## Credits and license

ChatLoom is a fork of [FluffyChat](https://github.com/krille-chan/fluffychat)
by Christian Kußowski and contributors, and is licensed under the
[AGPL-3.0-or-later](LICENSE) (see [NOTICE.md](NOTICE.md)). It uses the
[Matrix Dart SDK](https://github.com/famedly/matrix-dart-sdk) and talks to
your networks through [Beeper](https://www.beeper.com/)'s bridges. ChatLoom is
not affiliated with Beeper, Meta, Telegram, Signal or Slack.

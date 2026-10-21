<!--
SPDX-FileCopyrightText: 2019-Present Christian Kußowski
SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
SPDX-License-Identifier: AGPL-3.0-or-later
-->

<p align="center"><img src="assets/logo/img/logo.png" width="96" alt="ChatLoom logo"></p>

# ChatLoom

A private messenger for Android and macOS that brings your Beeper conversations into one quiet workspace. Built with Flutter and Matrix, with encrypted storage, private organization and a shared interface across both platforms.

## Screens

<p>
  <img src="docs/screenshots/inbox.png" width="240" alt="ChatLoom inbox with pinned conversations and floating network dock">
  <img src="docs/screenshots/conversation.png" width="240" alt="ChatLoom conversation with grouped messages, replies and voice transcription controls">
  <img src="docs/screenshots/settings.png" width="240" alt="ChatLoom settings and privacy controls">
</p>

Rendered on 21 October 2026 from production presentation widgets with fictional data. These are component previews, not captures of a signed-in device. The test renderer uses the opaque glass fallback; native blur and account behavior require separate verification. [Capture provenance](docs/screenshots/README.md).

## What ChatLoom does

- **One inbox:** network filters, pins, private labels and reversible groups that combine a person's conversations while preserving each message's source.
- **Conversations:** replies, reactions, voice, attachments and Telegram round video, subject to the source network's capabilities. The composer keeps the sending network visible.
- **Private tools:** synchronized drafts, bookmarks, reminders, scheduled messages and transcription through an enrolled worker.
- **Privacy:** new installations start in Incognito. Matrix encryption and recovery remain in place; native storage uses SQLCipher and fails closed when unavailable.
- **Shared desktop and mobile app:** Android and macOS use the same Flutter screens and domain logic on `main`, with native platform code in separate directories.

Transcription requires the configured worker; automatic incoming voice/round transcription also requires both user policy and the operator switch, with duration and budget limits. Disappearing messages are excluded. ChatLoom does not automatically reply.

## Design language

ChatLoom is text-first: warm charcoal backgrounds, neutral surfaces and clear type hierarchy. The floating inbox dock sets the visual language for navigation, controls and overlays.

| Element | Language |
|---|---|
| Palette | Warm near-black `#191919`, grey surfaces, off-white text; semantic colors for status |
| Typography | Bundled Roboto, restrained weights, large page titles and muted metadata |
| Shapes | Rounded message groups, circular avatars, pill controls and a floating dock |
| Glass | Translucent tint and fine borders on fixed bars and overlays; solid scrolling content |
| Motion | Brief press and transition feedback, reduced-motion support, no animated blur |
| Themes | Dark by default; light mode, accent, text size and private conversation appearance |

The implementation is documented in [DESIGN.md](DESIGN.md). Its internal `Notion*` tokens and primitives define the shared ChatLoom design system.

## Development

Use Flutter **3.47.4** and the pinned dependencies. Android and macOS are developed together on `main`.

On the Linux devbox, from this directory:

```sh
source scripts/devbox-env.sh
rtk python3 scripts/flutter-queue.py flutter pub get --enforce-lockfile
rtk python3 scripts/flutter-queue.py analyze lib
```

Use the queue for Flutter jobs so analysis, tests and builds do not overlap. Keep private configuration and signing material outside Git.

| Area | Guide |
|---|---|
| Setup, privacy, worker and verification | [Client guide](README.personal.md) |
| Android build and signing | [Android](android/README.personal.md) |
| macOS build and native behavior | [macOS](macos/README.personal.md) |
| Design tokens and components | [Design system](DESIGN.md) |
| Worker and private task execution | [Worker](worker/README.md) |
| Android push registration | [Push gateway](push-gateway/README.md) |

macOS requires a Mac with full Xcode. System notifications, notification sounds and Dock badges are disabled there; Android push has its own configuration. A passing build or component test does not establish real-account encryption, history, media delivery or push acceptance. See the [macOS acceptance guide](docs/macos-client.md) and [UI verification record](docs/notion-ui/VERIFICATION.md) for the tested scope.

## License and acknowledgements

ChatLoom is derived from [FluffyChat](https://github.com/krille-chan/fluffychat), with the Matrix SDK retained. The application is licensed under **AGPL-3.0-or-later**; see [LICENSE](LICENSE). Original copyright notices and third-party licenses remain with their sources, including bundled fonts and Matrix emoji verification data. Thanks to the upstream contributors, translators and testers.

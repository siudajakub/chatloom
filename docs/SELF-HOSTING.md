# Self-hosting ChatLoom

This guide sets up ChatLoom the way it runs for its author: a normal Beeper
account, with the chat bridges running on your own Linux server instead of on
Beeper's. Two of those bridges are ChatLoom forks with features the official
ones don't have (Telegram round videos and GIF search, native Instagram link
previews). The rest are the official bridges, unchanged.

It follows Beeper's own self-hosting tool, [Bridge Manager
(`bbctl`)](https://github.com/beeper/bridge-manager#readme). Read its README
first; this guide only adds the ChatLoom parts.

## What you are setting up

| Part | Runs on | Needed? |
|---|---|---|
| Beeper account | Beeper | Yes. Your Matrix account stays on beeper.com. |
| Bridges | Your server, through `bbctl` | Yes, one process per network. |
| ChatLoom app | Android or macOS | Yes. |
| Companion worker (`worker/`) | Your server | Optional: sync, transcription, reminders, scheduled messages. |
| Push gateway (`push-gateway/`) | Your server, behind HTTPS | Optional: Android notifications. |

This is not a fully self-hosted Matrix stack. `bbctl` only connects bridges to
the beeper.com server. Messages are re-encrypted on your server, but your
account, rooms and encrypted history stay with Beeper. Beeper gives limited
support for self-hosted bridges; ask in
[#self-hosting:beeper.com](https://matrix.to/#/#self-hosting:beeper.com).

## Bridges

| Network | Bridge | Source |
|---|---|---|
| Telegram | ChatLoom fork of mautrix-telegram | [siudajakub/chatloom-telegram-bridge](https://github.com/siudajakub/chatloom-telegram-bridge) |
| Instagram | ChatLoom fork of mautrix-meta (`mautrix-instagram`) | [siudajakub/chatloom-instagram-bridge](https://github.com/siudajakub/chatloom-instagram-bridge) |
| WhatsApp | official | [mautrix/whatsapp](https://github.com/mautrix/whatsapp) |
| Messenger | official (`mautrix-meta`) | [mautrix/meta](https://github.com/mautrix/meta) |
| Slack | official | [mautrix/slack](https://github.com/mautrix/slack) |
| Signal, Discord, Google Messages, LinkedIn, … | official | [`bbctl` bridge list](https://github.com/beeper/bridge-manager#official-bridge-list) |

What the forks add:

- **Telegram:** round (circle) videos in both directions, with echo, backfill
  and per-chat capabilities; Telegram GIF search; GIF/TGS sticker support;
  correct handling of chats with forwarding restrictions; readable errors.
  Without it, round videos arrive as ordinary videos and ChatLoom can't record
  or send them.
- **Instagram:** an authenticated endpoint that opens shared Instagram posts,
  reels and stories through your own Instagram login, so ChatLoom plays them in
  the app. Without it, Instagram links stay plain links.

ChatLoom works with the official bridges too; you only lose those features.

## 1. Prepare the server

Any always-on Linux machine (amd64 or arm64) works. A small VPS with 2 GB RAM
is enough for five bridges; plan for 150 MB per bridge at peak.

- Don't open any inbound port for the bridges. They connect out to Beeper over
  a WebSocket. Keep SSH private (a VPN such as Tailscale, or an IP allowlist).
- Create a dedicated user for the bridges (this guide calls it `bridges`).
- Install ffmpeg (`sudo apt install ffmpeg`). The Telegram fork also needs
  `ffprobe`, which comes with it.
- To build the forks: Go (the version in each fork's `go.mod`), a C compiler and
  libolm (`sudo apt install build-essential libolm-dev`).
- Plan backups of `~/.local/share/bbctl` (bridge databases and configs). Losing
  them means signing in to every network again.

## 2. Install `bbctl` and sign in

As the `bridges` user, follow [Bridge Manager → Usage](https://github.com/beeper/bridge-manager#usage):

```sh
# Download the latest release binary for your architecture from
# https://github.com/beeper/bridge-manager/releases and put it on PATH as bbctl.
bbctl login
```

Use the same Beeper account you'll sign in to ChatLoom with.

## 3. Run the official bridges

```sh
bbctl run sh-whatsapp
bbctl run sh-meta        # Messenger
bbctl run sh-slack
```

The name must start with `sh-`; `bbctl` guesses the bridge type from it. Each
command runs in the foreground; step 5 turns them into services.

## 4. Build and run the ChatLoom bridges

### Telegram

Get an API ID and hash for your own Telegram app at
[my.telegram.org](https://my.telegram.org/apps) (`bbctl` asks for them).

```sh
git clone https://github.com/siudajakub/chatloom-telegram-bridge
cd chatloom-telegram-bridge
./build.sh
install -m 755 mautrix-telegram ~/bin/chatloom-telegram

bbctl run --type telegram \
  --param api_id=YOUR_API_ID --param api_hash=YOUR_API_HASH \
  --custom-startup-command ~/bin/chatloom-telegram sh-telegram
```

`--custom-startup-command` keeps `bbctl` in charge of registration and config
generation but starts your binary instead of the official one. It also turns
off `bbctl`'s automatic updates, so you update the bridge by pulling and
rebuilding.

Optional, animated stickers as WebP: `bbctl` always writes
`convert_from_webm: false` into the Telegram config. To change that, point
`--custom-startup-command` at a small wrapper script that edits the generated
`config.yaml` (it receives `-c config.yaml` as arguments) and then `exec`s the
bridge binary with the same arguments. TGS stickers also need
[lottieconverter](https://github.com/sot-tech/LottieConverter) on `PATH`.

### Instagram

```sh
git clone https://github.com/siudajakub/chatloom-instagram-bridge
cd chatloom-instagram-bridge
./build-ig.sh
install -m 755 mautrix-instagram ~/bin/chatloom-instagram

bbctl run --type instagram \
  --custom-startup-command ~/bin/chatloom-instagram sh-instagram
```

Keep Messenger on the official `sh-meta` bridge from step 3.

### Switching an existing bridge to a fork

If you already run the official Telegram or Instagram bridge, keep its name
(`sh-telegram`, `sh-instagram`) so the database and logins carry over. Stop the
bridge, back up its directory under `~/.local/share/bbctl`, then start it again
with `--custom-startup-command`. The forks only add tables, so the official
binary can still start on the same database if you switch back.

## 5. Keep the bridges running

`bbctl run` stays in the foreground. Run each bridge as a systemd service so it
restarts on failure and starts at boot. A template unit,
`/etc/systemd/system/bbctl@.service`:

```ini
[Unit]
Description=Beeper bridge %i
After=network-online.target
Wants=network-online.target

[Service]
User=bridges
Environment=BBCTL_EXTRA=
ExecStart=/usr/local/bin/bbctl run --no-update $BBCTL_EXTRA %i
Restart=on-failure
RestartSec=10
MemoryMax=512M

[Install]
WantedBy=multi-user.target
```

For a ChatLoom fork, add a drop-in instead of editing the template, for example
`/etc/systemd/system/bbctl@sh-telegram.service.d/chatloom.conf`:

```ini
[Service]
Environment=BBCTL_EXTRA=--custom-startup-command=/home/bridges/bin/chatloom-telegram
```

Then:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now bbctl@sh-whatsapp bbctl@sh-meta bbctl@sh-slack bbctl@sh-telegram bbctl@sh-instagram
```

Rolling back a fork is removing its drop-in, `daemon-reload` and a restart of
that one unit. Update deliberately: back up, rebuild, restart one bridge, check
its log (`journalctl -u bbctl@sh-telegram`), then move on.

## 6. Connect your accounts

A running bridge doesn't mean the network is connected. Sign in to each one by
messaging its bot from Beeper or ChatLoom: start a chat with
`@sh-telegrambot:beeper.local` (or `sh-whatsappbot`, `sh-instagrambot`, …), send
`login` and follow the steps (QR code, phone code or cookies, depending on the
network). Network-specific details are in the
[mautrix documentation](https://docs.mau.fi/bridges/go/), for example
[WhatsApp](https://docs.mau.fi/bridges/go/whatsapp/authentication.html) and
[Meta](https://docs.mau.fi/bridges/go/meta/authentication.html).

These bridges use the networks' consumer apps and web logins, not official
business APIs. WhatsApp and Meta can flag or block accounts they find
suspicious; open WhatsApp on your phone at least every two weeks to keep the
linked device alive.

## 7. Install ChatLoom

Build the app from this repository: toolchain and build-time settings are in
[DEVELOPMENT.md](DEVELOPMENT.md). Sign in with the same Beeper account and enter
your recovery key. ChatLoom picks up the self-hosted bridges on its own, since
they're part of your account.

## 8. Optional: worker and push gateway

- **Companion worker** — a separate, silent Matrix device for sync, voice
  transcription, reminders and scheduled messages. It never replies to anyone on
  its own. Setup: [worker/README.md](../worker/README.md).
- **Push gateway** — delivers Android notifications through your own Firebase
  project. It needs a public HTTPS address (only the push and registration
  paths). Setup: [push-gateway/README.md](../push-gateway/README.md); build the
  app with `--dart-define=CHATLOOM_PUSH_GATEWAY=https://your-gateway`.

Without them, ChatLoom still works as a chat client; the features above show
as unavailable.

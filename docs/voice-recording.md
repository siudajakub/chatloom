# Voice notes and round videos: capture and formats

How ChatLoom records voice notes and round videos, and what each bridged
network receives. Since 31 October 2026 the capture follows Telegram for
Android: the plain microphone, no platform effects, no Bluetooth call audio
unless asked for, and 64 kbit/s Opus.

## Why

Voice notes sounded worse than Telegram's because of the capture, not the
codec. ChatLoom recorded from Android's `VOICE_RECOGNITION` source with the
platform's automatic gain control and noise suppressor on, and routed a
connected Bluetooth headset through its call microphone (SCO, 8 or 16 kHz).
Those effects are tuned for calls: they pump the level and thin out a voice
close to the microphone. Telegram for Android records `AudioSource.DEFAULT`
at 48 kHz mono, attaches no Android audio effects, uses a Bluetooth headset
only when the user turns on "record via Bluetooth" (off by default), and
encodes about 30 kbit/s Opus. Its round videos also record
`AudioSource.DEFAULT`.

## Capture

| | Android voice note | Android round video | macOS voice note |
|---|---|---|---|
| Source | `DEFAULT` (the device maps it to the main microphone) | `DEFAULT` | the system input device |
| Effects | none by default | none by default | none (file recording ignores them) |
| Strong noise reduction | `VOICE_COMMUNICATION` with echo cancellation, noise suppression and gain control | Noise reduction: `VOICE_COMMUNICATION` | not offered |
| Bluetooth headset | phone microphone; "Record with Bluetooth headset microphone" turns on SCO | phone microphone | the system input device |
| Codec | Ogg/Opus 48 kHz mono 64 kbit/s (96 high quality), or AAC-LC MP4 44.1 kHz mono 64 kbit/s (128) where the network prefers it | AAC-LC 48 kHz mono in H.264 MP4, bitrate from the bridge's round profile (64 kbit/s by default) | AAC-LC M4A 44.1 kHz mono 64 kbit/s (128) |

Settings → Chats & media → Voice messages & round videos keeps every
choice: noise suppression, automatic gain, echo cancellation, strong noise
reduction, high quality and the Bluetooth microphone (Android) for voice
notes; high quality, stabilization and noise reduction for rounds. Strong
noise reduction locks the three effects on, because the recorder switches
off an effect it is told is off, which can remove the call path's own
gain control.

Defaults are read when a recording starts and are never written to the
preferences, so an install that never changed a switch follows the new
defaults (no gain control, no noise suppression, no round noise
reduction), while a switch the user set keeps its value.

## Per network

The recorder picks the codec from the room's bridge capabilities
(`com.beeper.room_features`, the `org.matrix.msc3245.voice` MIME list):
the format the network takes natively, Opus when nothing is declared.
Rules in `lib/personal/media/voice_format.dart` (`preferOpusVoice`), cases
in `test/personal/voice_format_test.dart`.

| Network | Bridge declares for voice | Android records | What the bridge does | Arrives as |
|---|---|---|---|---|
| Telegram | `audio/ogg`, `audio/mpeg`, `audio/mp4` fully supported | Ogg/Opus | forwards the bytes, MIME normalised to `audio/ogg`, voice attribute and waveform set | a native voice note |
| WhatsApp | `audio/ogg; codecs=opus` fully, plain `audio/ogg` unsupported | Ogg/Opus | forwards the bytes as a push-to-talk audio message (`audio/ogg; codecs=opus`); no transcode, no bitrate or sample-rate limit | a native voice note |
| Messenger, Instagram | `audio/mp4` fully, `audio/ogg` only with ffmpeg | AAC in MP4 | uploads the bytes as a voice clip with the waveform (encrypted Messenger chats convert anything but MP4 to AAC) | a native voice clip |
| Slack | `audio/webm; codecs=opus` and `audio/mp4` fully, `audio/ogg` only with ffmpeg | Ogg/Opus (AAC without ffmpeg) | with ffmpeg, copies the voice stream into WebM without re-encoding and posts a Slack audio clip; without ffmpeg, posts MP4 as one | a Slack audio clip |
| Signal | `audio/aac` fully, `audio/ogg` only with ffmpeg | Ogg/Opus | re-encodes to AAC (ADTS) and sets the voice-message flag | a native voice note |
| Other or undeclared | anything else | Ogg/Opus unless the bridge prefers MP4 | depends on the bridge | — |

Slack: its bridge copies any voice note into WebM when ffmpeg is present;
WebM cannot hold AAC, so an AAC note fails there. That is why a network
whose own voice codec is Opus in another container records Opus even
though the bridge marks Ogg as "converted" (it is only remuxed). Signal
re-encodes every voice note to AAC; the 64 kbit/s source leaves room for
that second generation. A Signal bridge without ffmpeg sends the Ogg file
as a plain audio attachment, not a voice note.

The bitrate and sample rate change only the file size: Telegram and
WhatsApp decode any Opus stream, and Ogg/Opus always carries 48 kHz. A
minute is about 480 KB at 64 kbit/s (720 KB at 96).

### macOS

The pinned macOS recorder cannot write Ogg/Opus (it writes Opus in CAF), so
macOS always records AAC in M4A, whatever the network. Known limitations,
not addressed here:

- Telegram takes `audio/mp4` voice notes and the mobile apps play them, but
  Telegram Web needs Ogg/Opus.
- WhatsApp receives an AAC push-to-talk message; its own clients record
  Opus.
- Slack with ffmpeg cannot copy AAC into WebM (see above).

## Checks on a phone

Unit tests pin the configuration only. On a device, while a voice note or
round is recording:

- `adb shell dumpsys media.audio_flinger`: the input thread's source is
  `AUDIO_SOURCE_MIC` (DEFAULT maps to it; `VOICE_COMMUNICATION` with strong
  noise reduction), 48000 Hz, one channel, device `AUDIO_DEVICE_IN_BUILTIN_MIC`;
  its effect chain has no enabled noise suppressor or gain control.
- With a Bluetooth headset connected, the device stays
  `AUDIO_DEVICE_IN_BUILTIN_MIC`; with the Bluetooth setting on it is
  `AUDIO_DEVICE_IN_BLUETOOTH_SCO_HEADSET`.
- `adb shell dumpsys media.audio_policy` lists the active input with the same
  source and device.
- Send a note to each network and confirm it arrives as a voice note there.

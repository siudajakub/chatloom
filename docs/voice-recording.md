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
| Effects | none by default | none by default | none (file recording has no effects; the switches are hidden) |
| Strong noise reduction | `VOICE_COMMUNICATION` with echo cancellation, noise suppression and gain control | Noise reduction: `VOICE_COMMUNICATION` | not offered |
| Bluetooth headset | phone microphone; "Record with Bluetooth headset microphone" turns on SCO | phone microphone | the system input device |
| Codec | Ogg/Opus 48 kHz mono 64 kbit/s (96 high quality), or AAC-LC MP4 44.1 kHz mono 64 kbit/s (128) where the network prefers it | AAC-LC 48 kHz mono in H.264 MP4, bitrate from the bridge's round profile (64 kbit/s by default) | the same as Android: Opus 48 kHz mono 64 kbit/s (96), recorded in CAF and remuxed to Ogg/Opus before sending; AAC-LC M4A 44.1 kHz mono 64 kbit/s (128) where the network prefers it or Opus fails (see macOS) |

Settings → Chats & media → Voice messages & round videos keeps every
choice: noise suppression, automatic gain, echo cancellation, strong noise
reduction, high quality and the Bluetooth microphone (Android) for voice
notes; high quality, stabilization and noise reduction for rounds. Strong
noise reduction locks the three effects on, because the recorder switches
off an effect it is told is off, which can remove the call path's own
gain control.

On macOS the page shows only what the Mac honours: High quality for voice
notes, with the caption "macOS records from the system input device without
effects.", and High quality for rounds, which there only enlarges the
picture (up to 480 px instead of the bridge's standard side; the bitrate
comes from Apple's `AVAssetExportPresetMediumQuality` export,
`macos/Runner/RoundCapture.swift`). The effect, strong noise reduction,
Bluetooth, stabilization and round noise reduction switches are Android
only (`SettingsMediaPage.showEffectOptions`).

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

Android and macOS make the same choice and send the same formats
(`VoiceRecordingPlan` in `lib/pages/chat/recording_view_model.dart`, cases
in `test/personal/recording_lifecycle_test.dart`); macOS records Opus in
CAF and sends it remuxed to Ogg/Opus, byte for byte the same packets.

| Network | Bridge declares for voice | Android and macOS record | What the bridge does | Arrives as |
|---|---|---|---|---|
| Telegram | `audio/ogg`, `audio/mpeg`, `audio/mp4` fully supported | Ogg/Opus | forwards the bytes, MIME normalised to `audio/ogg`, voice attribute and waveform set | a native voice note |
| WhatsApp | `audio/ogg; codecs=opus` fully, plain `audio/ogg` unsupported | Ogg/Opus | forwards the bytes as a push-to-talk audio message (`audio/ogg; codecs=opus`); no transcode, no bitrate or sample-rate limit | a native voice note |
| Messenger, Instagram | `audio/mp4` fully, `audio/ogg` only with ffmpeg | AAC in MP4 (M4A on macOS) | uploads the bytes as a voice clip with the waveform (encrypted Messenger chats convert anything but MP4 to AAC) | a native voice clip |
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

`record_macos` 2.1.1 records to a file with `AVCaptureAudioFileOutput`; for
`AudioEncoder.opus` it writes Opus in a CAF file (Apple writes Opus only in
CAF), 48 kHz mono at the requested bitrate. Since 31 October 2026 macOS
records that wherever Android records Ogg/Opus, and before sending
`lib/personal/media/opus_container.dart` copies the Opus packets unchanged
from CAF into Ogg (RFC 7845): no re-encode, the same `audio/ogg;
codecs=opus` file Android sends. Before that, macOS always recorded AAC in
M4A, so Slack voice notes from a Mac failed (WebM cannot hold AAC), WhatsApp
got AAC instead of an Opus push-to-talk message and Telegram Web could not
play them.

The remux (`remuxCafVoiceToOgg`, `lib/personal/media/voice_remux.dart`):

- reads the CAF description, magic cookie and packet table (packet sizes
  and, when they vary, frame counts are variable-length integers);
- takes each packet's length from its Opus TOC byte (RFC 6716 §3.1), so
  the granule positions are the decoded 48 kHz samples whatever the CAF
  frames per packet say (10/20/40/60 ms, multi-frame packets);
- writes `OpusHead` (channels, pre-skip from the CAF priming frames, else
  an `OpusHead` cookie, else libopus' 312 samples; input rate; gain 0;
  mapping family 0), `OpusTags`, then pages of at most about one second,
  each with its CRC, terminating lacing for packets of 255-byte multiples,
  the end-of-stream flag and the CAF remainder frames trimmed from the
  last granule;
- reads the result back with a strict parser (CRC, page sequence, flags,
  every granule) before it is sent, and gives the exact duration from the
  last granule minus the pre-skip; the waveform is the recorder's
  amplitude envelope, as on Android;
- waits up to three seconds for the recorder to finish the file (the
  plugin returns the path before `AVCaptureAudioFileOutput` closes it).

The pub package `ogg_caf_converter` 0.1.4 was not usable for this and is
no longer a dependency: its CAF → Ogg path read the packet table byte by
byte instead of as variable-length integers (every packet of 128 bytes or
more broke it), computed the page CRC with a table truncated to 8 bits
(every page fails libogg's check), marked the first audio page as a
continuation (libogg drops its first packet), did not terminate packets of
a 255-byte multiple, never set the continuation flag on later pages, used
the frames per packet as the pre-skip and left granules without it. Its
Ogg → CAF path, which played received Ogg voice notes on the Mac, stored
packet sizes in bytes, so every packet of 256 bytes or more was cut (96
kbit/s notes from Android, and peaks of 64 kbit/s ones), and split packets
that span pages. ChatLoom's own `oggOpusToCaf` replaces it for playback and
keeps its CAF layout (description, channel layout, data, packet table
without priming), which AVPlayer plays.

Playback: the voice bubble on a Mac remuxes any Ogg file to CAF for
AVPlayer, recognised by its bytes or its MIME type with parameters
(`audio/ogg; codecs=opus`, which Android, WhatsApp and the Mac send; before,
only a bare `audio/ogg` was converted). The review player before sending
plays the recorder's CAF file directly.

Fallbacks keep AAC for anything Opus cannot do: a room whose network
prefers MP4 records AAC like on Android; if the Opus encoder cannot start,
the same recording starts again as AAC; if the remux or its validation
fails (or the recorder returns no file), the draft stays with "Oops, something went wrong" (it is never sent
as CAF under an Ogg label) and every later note of this app run records
AAC (`VoiceRecordingPlan.appleOpusFailed`; the log says "Voice note CAF to
Ogg/Opus remux failed").

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

## Checks on a Mac

`test/personal/media/opus_container_test.dart` remuxes synthetic CAF files
and, where ffmpeg is installed, libopus CAF files (64 kbit/s VBR, 255- and
510-byte packets, stereo, 60 ms frames) and decodes the Ogg with ffmpeg.
Apple's own CAF writer can only be checked on a Mac:

1. Record a voice note of about ten seconds in a Telegram chat, pause it
   and play it back before sending (the CAF file).
2. While it is paused, copy the recording out of the app's temporary
   directory (`find ~/Library/Containers/pl.personal.chat /private/var/folders
   -name 'voice_*.caf' 2>/dev/null`) and run `ffprobe -show_streams` on it:
   `codec_name=opus`, 48000 Hz, one channel. Keep it for a failure report.
3. Send it. The bubble plays on the Mac, and the note arrives as a voice
   note with its waveform and the recorded length on Telegram for Android
   or iOS and on Telegram Web (web.telegram.org plays only Ogg/Opus).
4. Send one to WhatsApp (arrives as a push-to-talk voice note), Slack with
   the bridge's ffmpeg (a Slack audio clip that plays) and Messenger or
   Instagram (still AAC, a voice clip).
5. Save a received copy (Telegram Desktop: Save as) and check it with
   `ffprobe` (opus, 48000 Hz, mono, the recorded duration) and
   `ffmpeg -v error -i note.ogg -f null -` (no output).
6. Turn on High quality and repeat step 3: about 96 kbit/s, still plays.
7. If a send shows "Oops, something went wrong", the next note must record
   AAC and send; keep the CAF from step 2 and the log line.

## Mark listened (Telegram)

An incoming Telegram voice note offers "Mark listened" when its bridge
declares playback receipts. Tapping it sends the bridge's `media_played`
request; nothing else (playing, reading the transcript) does. The notes an
account marked are kept in its encrypted private store on this device
(`VoiceListenedMarks`, the newest 1000), so the action does not return
after a restart; it is hidden while they load. A verified bridge media
state saying the note is no longer unread (listened on another Telegram
client) hides it too. The button takes the bubble's text colour, so it
stays readable on private chat palettes.

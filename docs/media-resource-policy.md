# Media, data and cache limits

These controls are local to the device. They do not change message history,
account keys or the bridge's encoding of existing uploads.

## Sending

The attachment preview offers Economy, Standard (default) and HD per send:

| Profile | Photo | Video |
|---|---|---|
| Economy | 1280 px, JPEG 72 | long side 854 px, 30 fps, ~900 kbit/s + 96 kbit/s audio allowance |
| Standard | 2048 px, JPEG 80 | 720p, 30 fps, ~2.5 Mbit/s |
| HD | 2560 px, JPEG 85 | 1080p, 30 fps, ~5 Mbit/s |

Efficient files may pass through without another lossy encode. Transparent
images retain transparency. Voice recording quality remains independent.
Failed required image or large-video preparation no longer silently uploads
the original. The failed bubble offers retry; sending original bytes is an
explicit attachment-as-File action. The durable outbox retains the job.

Videos prepare one at a time. Photos decode at their target dimensions and
encode off the UI isolate; the native frame is released before JPEG encoding.
Video bytes still enter the Matrix SDK as a complete buffer. This does not
implement streaming upload or custom encryption.

## Receiving

The existing voice/round settings page contains Data saver, automatic
downloads, Wi-Fi-only downloads and Storage & cache. Existing explicit
Wi-Fi-only choices are preserved; its default is now on.

Data saver defaults on. An image preview without a separate thumbnail waits
for a tap when its original exceeds 2 MiB or has unknown size. Encrypted URI
previews and missing server thumbnails also wait before fetching an unknown
original. Available cached bytes remain usable. Opening the image viewer is
an explicit request for the original. Automatic image-original transfers are
bounded while streaming, so misleading size metadata cannot bypass the cap.
Image transfers have a 64 MiB safety cap. Scanner downloads keep the SDK's
scanner path: metadata gates large originals and returned bytes are checked,
but the local HTTP stream cap cannot interrupt scanner-managed transfers.

URI thumbnails use stable physical-size buckets up to 1600 px. Nearby layout
widths share one server rendition. The encoded scrolling cache does not
retain individual payloads over 8 MiB. Full image decodes leave the shared
cache when replaced or closed. Shared URI reads abort HTTP when their last
consumer leaves; image work pauses while the app is in the background.

Automatic voice/round prefetch budgets per open chat:

Scanner-managed attachments are excluded from automatic prefetch because
the SDK scanner transport cannot enforce its streaming budget or immediate
cancellation. Explicit playback keeps the scanner path.

| Connection | Initial candidates | Body-data budget | File cap | Parallel downloads |
|---|---:|---:|---:|---:|
| Wi-Fi or Ethernet | 6 | 16 MiB | 8 MiB | 2 |
| Cellular or unknown, when allowed | 3 | 2 MiB | 512 KiB | 1 |

Cellular round thumbnails are capped at 128 KiB and can prefetch independently
of larger videos. Music is excluded. Failed and cancelled transfers count
received bytes and back off before retrying. A delivered HTTP chunk can
cross the cap before cancellation. These budgets exclude protocol overhead;
connection type does not prove that Wi-Fi is unmetered.

## Storage

Storage & cache shows category usage and pending-send copies separately.
Compact, Standard and Generous presets set cache limits. The SQLCipher
allowance is per account; video, avatar and sticker files are shared by the
device. This is not one hard cap on the entire app or a multi-account device.
History, pending sends, database overhead and temporary opened-file copies
are outside these limits.

Selective clearing preserves history, encryption keys and `cache://` retry
copies. Generations reject stale downloads after clear. Lowering a limit can
evict older downloads. SQL usage counts logical payload bytes: free database
pages can be reused without immediately shrinking the database file.

Instagram media retains its absolute 24-hour lifetime. Ordinary encrypted
video retains its 30-day policy. No new plaintext cache is introduced.
Physical-device transfer, memory, frame-time and battery measurements remain
separate release acceptance.

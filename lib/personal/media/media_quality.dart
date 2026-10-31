// SPDX-License-Identifier: AGPL-3.0-or-later

/// ChatLoom's one media quality profile for sending, shared by Android
/// (Pixel 8) and macOS (M3): files get noticeably smaller with no visible
/// loss, the middle Telegram, WhatsApp and Messenger settle on.
///
/// Everything here is a pure decision (no I/O, no decoding), so the rules
/// are unit-tested with synthetic inputs (`test/personal/media/`).
///
/// | Media | Profile |
/// |---|---|
/// | Photo | long side ≤ [photoMaxSide] px, JPEG q[photoJpegQuality] 4:2:0; never upscaled; EXIF/GPS stripped |
/// | Transparent PNG/WebP/GIF | never JPEG (no black backgrounds): original, or PNG when it must shrink |
/// | Screenshot (opaque PNG) | original up to [screenshotKeepBytes], else JPEG q[screenshotJpegQuality] 4:4:4 (crisp text) |
/// | Thumbnail | long side ≤ [thumbnailMaxSide] px, JPEG q[thumbnailJpegQuality] + blurhash |
/// | Video | long side ≤ [videoMaxSide] (720p), ≤ [videoMaxFps] fps, H.264 ≈ [videoBitrate] bit/s, AAC; skipped when already that small |
/// | Voice | Opus mono 48 kHz at [voiceOpusBitrate] bit/s (Ogg); AAC-LC mono 44.1 kHz at [voiceAacBitrate] bit/s (MP4) where the network's native voice is AAC |
///
/// Sending never asks whether to compress (J, 2026-10-24): every photo and
/// video is compressed on the device before upload by the [MediaProfile]
/// chosen in the send preview — [MediaProfile.standard] unless the "HD"
/// chip is on for that send ([MediaProfile.hd]: photos 2560 px JPEG q85,
/// video 1080p30 ≈ 5 Mbit/s, still without EXIF/GPS). The exact original
/// bytes go out only through the attach menu's "File" entry (a document).
library;

import 'dart:math' as math;

abstract final class MediaQuality {
  /// Longest side of a compressed photo. Fills an M3 MacBook Air screen
  /// height (1664 px) and a Pixel 8 screen width at 2× zoom; Messenger's
  /// size, under Telegram HD (2560).
  static const photoMaxSide = 2048;
  static const photoJpegQuality = 80;

  /// The SDK's thumbnail side (`Client.defaultThumbnailSize`): a timeline
  /// bubble at 2.6 dpr.
  static const thumbnailMaxSide = 800;
  static const thumbnailJpegQuality = 75;

  /// Opaque PNG (screenshots, diagrams): text stays sharp up to this size,
  /// above it a high-quality JPEG without chroma subsampling.
  static const screenshotKeepBytes = 1500 * 1000;
  static const screenshotJpegQuality = 85;

  /// A JPEG/WebP within [photoMaxSide] is already efficient at or under
  /// this many bytes per pixel (≈ q85) or [smallPhotoBytes]: re-encoding
  /// would cost a generation of quality for little gain.
  static const efficientBytesPerPixel = 0.35;
  static const smallPhotoBytes = 300 * 1000;

  /// Video: 720p, 30 fps, H.264 at ~2.5 Mbit/s (Telegram caps 720p at
  /// 2.6 Mbit/s). About 19–20 MB per minute.
  static const videoMaxSide = 1280;
  static const videoMaxFps = 30;
  static const videoBitrate = 2500 * 1000;

  /// The compressor reserves room for (passed-through) audio itself; this
  /// estimate only sizes the target.
  static const videoAudioBitrate = 128 * 1000;

  /// A source already this lean is sent as is (re-encoding only loses).
  static const videoSkipBitrate = 3500 * 1000;
  static const videoSkipFps = 31.0;

  /// Videos up to this size are never worth a re-encode (a few seconds).
  static const videoSmallBytes = 2 * 1000 * 1000;

  /// Voice notes: 64 kbit/s mono Opus at 48 kHz (J, 2026-10-31). Telegram
  /// records about 30 kbit/s, but a voice note is often forwarded again by a
  /// bridge (Signal re-encodes it to AAC), so the source keeps headroom;
  /// a minute is about 480 KB. High quality: 96 kbit/s.
  static const voiceOpusBitrate = 64000;
  static const voiceOpusHighQualityBitrate = 96000;

  /// AAC-LC needs about twice Opus's rate for the same speech quality: mono
  /// 44.1 kHz at 64 kbit/s (Messenger/Instagram, macOS), 128 with high
  /// quality.
  static const voiceAacBitrate = 64000;
  static const voiceAacHighQualityBitrate = 128000;

  /// HD (Telegram's "HD" toggle): photos up to 2560 px at JPEG q85.
  static const photoHdMaxSide = 2560;
  static const photoHdJpegQuality = 85;

  /// HD video: 1080p (long side 1920), ≤ 30 fps, H.264 at ~5 Mbit/s
  /// (about 38 MB per minute).
  static const videoHdMaxSide = 1920;
  static const videoHdBitrate = 5000 * 1000;

  /// An HD source already this lean (1080p30 at ≤ 6.5 Mbit/s, MP4) is sent
  /// as is.
  static const videoHdSkipBitrate = 6500 * 1000;
}

/// How strongly one send compresses its photos and videos. There is no
/// "uncompressed" profile: the original file is sent as a document through
/// the attach menu's "File" entry instead.
enum MediaProfile {
  /// The automatic sweet spot (the default of every send).
  standard(
    photoMaxSide: MediaQuality.photoMaxSide,
    photoJpegQuality: MediaQuality.photoJpegQuality,
    videoMaxSide: MediaQuality.videoMaxSide,
    videoBitrate: MediaQuality.videoBitrate,
    videoSkipBitrate: MediaQuality.videoSkipBitrate,
  ),

  /// The "HD" chip in the send preview: per send, never remembered.
  hd(
    photoMaxSide: MediaQuality.photoHdMaxSide,
    photoJpegQuality: MediaQuality.photoHdJpegQuality,
    videoMaxSide: MediaQuality.videoHdMaxSide,
    videoBitrate: MediaQuality.videoHdBitrate,
    videoSkipBitrate: MediaQuality.videoHdSkipBitrate,
  );

  const MediaProfile({
    required this.photoMaxSide,
    required this.photoJpegQuality,
    required this.videoMaxSide,
    required this.videoBitrate,
    required this.videoSkipBitrate,
  });

  final int photoMaxSide;
  final int photoJpegQuality;
  final int videoMaxSide;
  final int videoBitrate;
  final int videoSkipBitrate;

  int get videoMaxFps => MediaQuality.videoMaxFps;

  /// The profile a photo send used, from the long side it was given. The
  /// SDK hands the resizer only this number (and the outbox stores only
  /// it for Retry), so the JPEG quality is derived from it.
  static MediaProfile ofPhotoMaxSide(int maxSide) =>
      maxSide >= MediaQuality.photoHdMaxSide ? hd : standard;
}

/// The encoded format of a still image, sniffed from its header.
enum PhotoFormat { jpeg, png, webp, gif, heif, other }

/// What the photo encoder does with one image.
enum PhotoAction {
  /// Send the original bytes (metadata stripped where the format allows).
  keep,

  /// Re-encode as JPEG at [PhotoPlan.width] × [PhotoPlan.height].
  jpeg,

  /// Re-encode as PNG (keeps transparency).
  png,
}

class PhotoPlan {
  final PhotoAction action;
  final int width, height;
  final int quality;

  /// JPEG without chroma subsampling (text and sharp edges).
  final bool fullChroma;

  const PhotoPlan._(
    this.action,
    this.width,
    this.height, {
    this.quality = MediaQuality.photoJpegQuality,
    this.fullChroma = false,
  });

  /// The sweet-spot decision for an image of [width] × [height] (as shown,
  /// i.e. after EXIF orientation), [bytes] long, for a long side of at most
  /// [maxSide] (the photo size, or the thumbnail size).
  ///
  /// - never upscales;
  /// - an animated image is kept whole (resizing would drop frames);
  /// - a transparent image is never turned into JPEG;
  /// - an image already small and efficient is not re-encoded, unless its
  ///   pixels still need rotating ([orientation] other than 1) or the
  ///   format is one receivers cannot rely on (HEIF and others).
  factory PhotoPlan.decide({
    required PhotoFormat format,
    required int width,
    required int height,
    required int bytes,
    required int maxSide,
    bool hasAlpha = false,
    bool animated = false,
    int? orientation,
  }) {
    final longSide = math.max(width, height);
    final scale = longSide <= maxSide ? 1.0 : maxSide / longSide;
    final w = math.max(1, (width * scale).round());
    final h = math.max(1, (height * scale).round());
    final shrink = scale < 1;
    final thumbnail = maxSide <= MediaQuality.thumbnailMaxSide;
    final jpegQuality = thumbnail
        ? MediaQuality.thumbnailJpegQuality
        : MediaProfile.ofPhotoMaxSide(maxSide).photoJpegQuality;
    if (animated) return PhotoPlan._(PhotoAction.keep, width, height);
    final alpha =
        hasAlpha ||
        // GIF transparency is per frame; never risk a black background.
        format == PhotoFormat.gif;
    if (alpha) {
      return shrink
          ? PhotoPlan._(PhotoAction.png, w, h)
          : PhotoPlan._(PhotoAction.keep, width, height);
    }
    final upright = orientation == null || orientation == 1;
    final efficient =
        bytes <= MediaQuality.smallPhotoBytes ||
        bytes <= width * height * MediaQuality.efficientBytesPerPixel;
    switch (format) {
      case PhotoFormat.jpeg:
        if (!shrink && upright && efficient) {
          return PhotoPlan._(PhotoAction.keep, width, height);
        }
        return PhotoPlan._(PhotoAction.jpeg, w, h, quality: jpegQuality);
      case PhotoFormat.webp:
        if (!shrink && efficient) {
          return PhotoPlan._(PhotoAction.keep, width, height);
        }
        return PhotoPlan._(PhotoAction.jpeg, w, h, quality: jpegQuality);
      case PhotoFormat.png:
        if (!shrink &&
            (thumbnail || bytes <= MediaQuality.screenshotKeepBytes)) {
          return PhotoPlan._(PhotoAction.keep, width, height);
        }
        return PhotoPlan._(
          PhotoAction.jpeg,
          w,
          h,
          quality: thumbnail ? jpegQuality : MediaQuality.screenshotJpegQuality,
          fullChroma: !thumbnail,
        );
      case PhotoFormat.gif:
      case PhotoFormat.heif:
      case PhotoFormat.other:
        return PhotoPlan._(PhotoAction.jpeg, w, h, quality: jpegQuality);
    }
  }

  @override
  String toString() =>
      'PhotoPlan(${action.name} ${width}x$height q$quality'
      '${fullChroma ? ' 444' : ''})';
}

/// What the video step does with one video.
class VideoPlan {
  /// Send the source unchanged.
  final bool skip;

  /// Encoder input: the size in the stored (unrotated) frame, even numbers.
  final int width, height;

  /// Frame-rate cap (frames above it are dropped).
  int get fps => MediaQuality.videoMaxFps;

  /// The profile this plan was made for.
  final MediaProfile profile;

  /// Whole megabytes (the plugin's unit): the bitrate solver lands at
  /// about [MediaQuality.videoBitrate] for the clip's duration.
  final int targetSizeMb;

  const VideoPlan._({
    required this.skip,
    this.width = 0,
    this.height = 0,
    this.targetSizeMb = 0,
    this.profile = MediaProfile.standard,
  });

  static const keep = VideoPlan._(skip: true);

  /// [width] × [height] are the stored frame (`MediaInfo.width/height`,
  /// before [rotation]); [bitrate] in bit/s; [bytes] the file size;
  /// [profile] the send's quality (720p by default, 1080p for HD).
  factory VideoPlan.decide({
    required int? width,
    required int? height,
    required int? durationMs,
    required int bytes,
    int? bitrate,
    double? frameRate,
    String? mimeType,
    MediaProfile profile = MediaProfile.standard,
  }) {
    if (width == null || height == null || width <= 0 || height <= 0) {
      // Nothing to plan with: the compressor's own defaults would guess.
      return keep;
    }
    final seconds = (durationMs ?? 0) / 1000;
    final totalBitrate = seconds > 0 ? bytes * 8 / seconds : null;
    final rate = bitrate ?? totalBitrate?.round();
    final longSide = math.max(width, height);
    final mp4 =
        mimeType == null ||
        mimeType == 'video/mp4' ||
        mimeType == 'video/x-m4v';
    final fpsOk = frameRate == null || frameRate <= MediaQuality.videoSkipFps;
    if (bytes <= MediaQuality.videoSmallBytes && mp4 && fpsOk) return keep;
    if (longSide <= profile.videoMaxSide &&
        fpsOk &&
        mp4 &&
        rate != null &&
        rate <= profile.videoSkipBitrate) {
      return keep;
    }
    final scale = longSide <= profile.videoMaxSide
        ? 1.0
        : profile.videoMaxSide / longSide;
    int even(double v) => math.max(2, (v / 2).round() * 2);
    final w = even(width * scale);
    final h = even(height * scale);
    final budget = seconds > 0
        ? seconds *
              (profile.videoBitrate + MediaQuality.videoAudioBitrate) /
              8e6
        : 0.0;
    var target = math.max(1, budget.ceil());
    // Never ask for more than the source holds (a very short or lean clip).
    final sourceMb = (bytes / 1e6).ceil();
    if (target > sourceMb) target = math.max(1, sourceMb);
    return VideoPlan._(
      skip: false,
      width: w,
      height: h,
      targetSizeMb: target,
      profile: profile,
    );
  }

  @override
  String toString() => skip
      ? 'VideoPlan(skip)'
      : 'VideoPlan(${profile.name} ${width}x$height ${fps}fps ${targetSizeMb}MB)';
}

/// The size receivers lay a video out with: the stored frame turned by
/// its rotation (a portrait phone video is stored landscape, rotated 90°).
(int?, int?) displaySize(int? width, int? height, int? rotation) {
  final turned = rotation != null && (rotation % 180).abs() == 90;
  return turned ? (height, width) : (width, height);
}

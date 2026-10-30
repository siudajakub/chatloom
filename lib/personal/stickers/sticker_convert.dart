// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:chatloom/utils/client_download_content_extension.dart';
import 'package:chatloom/widgets/lottie_sticker_data.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show BoxFit;
import 'package:image/image.dart' as img;
import 'package:lottie/lottie.dart';
import 'package:matrix/matrix.dart';

import 'sticker_media_cache.dart';
import 'sticker_models.dart';
import 'sticker_send_plan.dart';

/// Limits of a converted sticker. Static stickers are the 512 px square
/// every sticker network uses (WhatsApp shows them square); animated ones
/// are smaller, shorter and slower so an APNG stays a few hundred KB and
/// converts in a second or two on a phone.
@immutable
class StickerConvertLimits {
  const StickerConvertLimits({
    this.staticSide = 512,
    this.animatedSide = 320,
    this.maxFps = 15,
    this.maxDurationMs = 3000,
    this.maxAnimatedBytes = 1024 * 1024,
  });

  final int staticSide;
  final int animatedSide;
  final int maxFps;
  final int maxDurationMs;

  /// An APNG above this is retried at half the frame rate, then sent as a
  /// still.
  final int maxAnimatedBytes;
}

/// A converted sticker: PNG bytes (animated when [animated]) on a square,
/// transparent canvas.
@immutable
class ConvertedSticker {
  const ConvertedSticker({
    required this.bytes,
    required this.side,
    required this.animated,
  });

  final Uint8List bytes;
  final int side;
  final bool animated;
}

/// Thrown when a source cannot be converted (undecodable, empty).
class StickerConvertException implements Exception {
  const StickerConvertException(this.message);
  final String message;
  @override
  String toString() => 'StickerConvertException: $message';
}

/// Converts sticker media on this device into the formats bridges take as
/// native stickers: animated PNG (Signal) and square static PNG (WhatsApp,
/// Messenger). There is no WebP encoder in Dart, so animated stickers can
/// not be made for WhatsApp; they become stills there.
abstract final class StickerConverter {
  /// Converts raster media (GIF, WebP, PNG/APNG, JPEG). With [animate] an
  /// animated source becomes an APNG, else the first frame a still. With
  /// [onlyIfAnimated] a still source returns null (send the original).
  /// Decoding and encoding run on a background isolate.
  static Future<ConvertedSticker?> raster(
    Uint8List source, {
    required bool animate,
    bool onlyIfAnimated = false,
    StickerConvertLimits limits = const StickerConvertLimits(),
  }) => compute(
    _rasterJob,
    _RasterJob(source, animate, onlyIfAnimated, limits),
    debugLabel: 'sticker-convert',
  );

  /// Converts a Lottie sticker (TGS or Lottie JSON). Frames are drawn on
  /// this isolate (the `lottie` renderer needs `dart:ui`), bounded by
  /// [limits]; the PNG encoding runs on a background isolate.
  static Future<ConvertedSticker> lottie(
    Uint8List source, {
    required bool animate,
    StickerConvertLimits limits = const StickerConvertLimits(),
  }) async {
    final composition = await LottieStickerData.decode(source);
    if (composition == null) {
      throw const StickerConvertException('Not a Lottie sticker');
    }
    final drawable = LottieDrawable(composition);
    final totalMs = math.max(1, composition.duration.inMilliseconds);
    final side = animate ? limits.animatedSide : limits.staticSide;
    final frames = <Uint8List>[];
    final durations = <int>[];
    if (animate) {
      final fps = math.min(
        limits.maxFps,
        math.max(1, composition.frameRate.round()),
      );
      final step = (1000 / fps).round();
      final span = math.min(totalMs, limits.maxDurationMs);
      for (var t = 0; t < span; t += step) {
        frames.add(await _drawLottie(drawable, t / totalMs, side));
        durations.add(math.min(step, span - t));
      }
    } else {
      frames.add(await _drawLottie(drawable, 0, side));
      durations.add(0);
    }
    return compute(
      _framesJob,
      _FramesJob(frames, durations, side, limits),
      debugLabel: 'sticker-convert',
    );
  }

  static Future<Uint8List> _drawLottie(
    LottieDrawable drawable,
    double progress,
    int side,
  ) async {
    drawable.setProgress(progress.clamp(0, 1));
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    drawable.draw(
      canvas,
      ui.Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
      fit: BoxFit.contain,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(side, side);
    picture.dispose();
    try {
      final data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (data == null) {
        throw const StickerConvertException('Lottie frame not drawn');
      }
      return data.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }
}

class _RasterJob {
  const _RasterJob(this.source, this.animate, this.onlyIfAnimated, this.limits);
  final Uint8List source;
  final bool animate;
  final bool onlyIfAnimated;
  final StickerConvertLimits limits;
}

class _FramesJob {
  const _FramesJob(this.frames, this.durations, this.side, this.limits);

  /// Straight-alpha RGBA, [side] × [side] each.
  final List<Uint8List> frames;
  final List<int> durations;
  final int side;
  final StickerConvertLimits limits;
}

ConvertedSticker? _rasterJob(_RasterJob job) {
  final decoded = img.decodeImage(job.source);
  if (decoded == null || decoded.width == 0 || decoded.height == 0) {
    throw const StickerConvertException('Undecodable sticker');
  }
  final animated = decoded.numFrames > 1;
  if (job.onlyIfAnimated && !animated) return null;
  final limits = job.limits;
  if (!(job.animate && animated)) {
    final side = limits.staticSide;
    return ConvertedSticker(
      bytes: img.encodePng(_square(decoded.frames.first, side)),
      side: side,
      animated: false,
    );
  }
  // Resample to at most maxFps over at most maxDurationMs: the source frame
  // showing at each tick.
  final starts = <int>[];
  var total = 0;
  for (final frame in decoded.frames) {
    starts.add(total);
    // GIF and WebP use 0 for "as fast as possible"; browsers show 100 ms.
    total += frame.frameDuration > 10 ? frame.frameDuration : 100;
  }
  final step = (1000 / limits.maxFps).round();
  final span = math.min(total, limits.maxDurationMs);
  final side = limits.animatedSide;
  final squares = <int, img.Image>{};
  final frames = <img.Image>[];
  final durations = <int>[];
  var index = 0;
  for (var t = 0; t < span; t += step) {
    while (index + 1 < starts.length && starts[index + 1] <= t) {
      index++;
    }
    final square = squares[index] ??= _square(decoded.frames[index], side);
    // Consecutive ticks on the same source frame are one longer frame.
    if (frames.isNotEmpty && identical(frames.last, square)) {
      durations[durations.length - 1] += math.min(step, span - t);
    } else {
      frames.add(square);
      durations.add(math.min(step, span - t));
    }
  }
  return _encode(frames, durations, side, limits);
}

ConvertedSticker _framesJob(_FramesJob job) {
  final frames = [
    for (final rgba in job.frames)
      img.Image.fromBytes(
        width: job.side,
        height: job.side,
        bytes: rgba.buffer,
        bytesOffset: rgba.offsetInBytes,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      ),
  ];
  return _encode(frames, job.durations, job.side, job.limits);
}

/// A still for one frame, else an APNG within the byte budget: at half the
/// frame rate when too large, a still of the first frame when still too
/// large.
ConvertedSticker _encode(
  List<img.Image> frames,
  List<int> durations,
  int side,
  StickerConvertLimits limits,
) {
  if (frames.isEmpty) throw const StickerConvertException('No frames');
  if (frames.length > 1) {
    var currentFrames = frames;
    var currentDurations = durations;
    for (var attempt = 0; attempt < 2 && currentFrames.length > 1; attempt++) {
      final bytes = _apng(currentFrames, currentDurations);
      if (bytes.length <= limits.maxAnimatedBytes) {
        return ConvertedSticker(bytes: bytes, side: side, animated: true);
      }
      final halfFrames = <img.Image>[];
      final halfDurations = <int>[];
      for (var i = 0; i < currentFrames.length; i += 2) {
        halfFrames.add(currentFrames[i]);
        halfDurations.add(
          currentDurations[i] +
              (i + 1 < currentDurations.length ? currentDurations[i + 1] : 0),
        );
      }
      currentFrames = halfFrames;
      currentDurations = halfDurations;
    }
  }
  return ConvertedSticker(
    bytes: img.encodePng(frames.first),
    side: side,
    animated: false,
  );
}

Uint8List _apng(List<img.Image> frames, List<int> durations) {
  final animation = img.Image.from(frames.first, noAnimation: true)
    ..frameDuration = durations.first
    ..loopCount = 0;
  for (var i = 1; i < frames.length; i++) {
    animation.addFrame(
      img.Image.from(frames[i], noAnimation: true)
        ..frameDuration = durations[i],
    );
  }
  return img.PngEncoder().encode(animation);
}

/// [frame] fitted (up or down, aspect kept) and centred on a transparent
/// [side] × [side] RGBA canvas.
img.Image _square(img.Image frame, int side) {
  final rgba = img.Image.from(
    frame,
    noAnimation: true,
  ).convert(format: img.Format.uint8, numChannels: 4);
  final scale = side / math.max(rgba.width, rgba.height);
  final width = math.max(1, (rgba.width * scale).round());
  final height = math.max(1, (rgba.height * scale).round());
  final resized = width == rgba.width && height == rgba.height
      ? rgba
      : img.copyResize(
          rgba,
          width: width,
          height: height,
          interpolation: scale < 1
              ? img.Interpolation.average
              : img.Interpolation.linear,
        );
  final canvas = img.Image(width: side, height: side, numChannels: 4);
  return img.compositeImage(
    canvas,
    resized,
    dstX: (side - width) ~/ 2,
    dstY: (side - height) ~/ 2,
    blend: img.BlendMode.direct,
  );
}

/// Fetches a sticker's media (decrypting encrypted media in memory). The
/// one place conversion downloads, so a persistent sticker cache can back
/// it later.
typedef StickerMediaLoader =
    Future<Uint8List> Function(
      Client client,
      Uri mxc,
      Map<String, Object?>? encryptedFile,
    );

/// Uploads converted media to [room] (encrypted in encrypted rooms) and
/// returns the content's media part: `url` or `file`.
typedef StickerMediaUploader =
    Future<Map<String, Object?>> Function(Room room, MatrixFile file);

/// Prepares converted stickers for [StickerSendPlan.conversion]: load,
/// convert, upload, with a session cache so a second send is instant.
abstract final class StickerConvertedMedia {
  @visibleForTesting
  static StickerMediaLoader loader = _download;

  @visibleForTesting
  static StickerMediaUploader uploader = _upload;

  static const _maxConverted = 12;
  static const _maxUploaded = 64;

  /// Converted bytes per (account, sticker, conversion), newest last.
  static final _converted = <String, ConvertedSticker>{};

  /// Uploaded media parts per (account, sticker, conversion, encrypted).
  /// Re-sending an attachment reference (and its key) is what forwarding
  /// does as well.
  static final _uploaded = <String, Map<String, Object?>>{};

  /// Stickers found still for an [StickerConversion.onlyIfAnimated]
  /// upgrade: sent as they are without another download.
  static final _still = <String>{};

  @visibleForTesting
  static void clear() {
    _converted.clear();
    _uploaded.clear();
    _still.clear();
  }

  /// The sticker content for [plan]'s conversion of [item] in [room]
  /// (`body`, `url`/`file`, `info`), or null when the conversion is not
  /// worth it ([StickerConversion.onlyIfAnimated] with a still source).
  /// Throws when the source cannot be loaded, converted or uploaded.
  static Future<Map<String, Object?>?> prepare(
    Room room,
    StickerItem item,
    StickerConversion conversion,
    Map<String, Object?> content,
  ) async {
    final client = room.client;
    final key = '${client.userID}\n${item.key}\n${conversion.cacheKey}';
    final encrypted = room.encrypted && client.fileEncryptionEnabled;
    final uploadKey = '$key\n$encrypted';

    if (_still.contains(key)) return null;
    var converted = _take(_converted, key);
    final cachedMedia = _take(_uploaded, uploadKey);
    if (cachedMedia != null && converted != null) {
      return _content(content, conversion, converted, cachedMedia);
    }
    if (converted == null) {
      converted = await _convert(client, item, conversion);
      if (converted == null) {
        if (_still.length > _maxUploaded) _still.clear();
        _still.add(key);
        return null;
      }
      _put(_converted, key, converted, _maxConverted);
    }
    final mime = _mime(conversion, converted);
    final media =
        cachedMedia ??
        await uploader(
          room,
          MatrixFile(
            bytes: converted.bytes,
            name: 'sticker.png',
            mimeType: mime,
          ),
        );
    _put(_uploaded, uploadKey, media, _maxUploaded);
    return _content(content, conversion, converted, media);
  }

  static String _mime(StickerConversion conversion, ConvertedSticker c) =>
      (c.animated ? conversion.animatedMime : conversion.staticMime) ??
      conversion.animatedMime ??
      conversion.staticMime!;

  static Map<String, Object?> _content(
    Map<String, Object?> content,
    StickerConversion conversion,
    ConvertedSticker converted,
    Map<String, Object?> media,
  ) => {
    'body': content['body'],
    ...media,
    // A fresh file: none of the source's bridge tags (another network's
    // sticker id) or thumbnails apply.
    'info': {
      'mimetype': _mime(conversion, converted),
      'w': converted.side,
      'h': converted.side,
      'size': converted.bytes.length,
    },
  };

  static Future<ConvertedSticker?> _convert(
    Client client,
    StickerItem item,
    StickerConversion conversion,
  ) async {
    final Uint8List source;
    if (conversion.fromThumbnail) {
      final thumbFile = item.info['thumbnail_file'];
      final thumb = item.thumbnailUri;
      if (thumb != null) {
        source = await loader(client, thumb, null);
      } else if (thumbFile is Map && thumbFile['url'] is String) {
        source = await loader(
          client,
          Uri.parse(thumbFile['url'] as String),
          thumbFile.cast<String, Object?>(),
        );
      } else {
        throw const StickerConvertException('No poster');
      }
    } else {
      final file = item.file;
      final uri = item.uri ?? Uri.tryParse(file?['url'] as String? ?? '');
      if (uri == null) throw const StickerConvertException('No media');
      source = await loader(client, uri, item.encrypted ? file : null);
    }
    final animate = conversion.animatedMime != null;
    if (!conversion.fromThumbnail &&
        (LottieStickerData.isLottieMime(item.mimetype) ||
            LottieStickerData.jsonBytes(source) != null)) {
      return StickerConverter.lottie(source, animate: animate);
    }
    return StickerConverter.raster(
      source,
      animate: animate,
      onlyIfAnimated: conversion.onlyIfAnimated,
    );
  }

  static V? _take<V>(Map<String, V> cache, String key) {
    final hit = cache.remove(key);
    if (hit != null) cache[key] = hit;
    return hit;
  }

  static void _put<V>(Map<String, V> cache, String key, V value, int max) {
    cache
      ..remove(key)
      ..[key] = value;
    while (cache.length > max) {
      cache.remove(cache.keys.first);
    }
  }

  static Future<Uint8List> _download(
    Client client,
    Uri mxc,
    Map<String, Object?>? encryptedFile,
  ) async {
    // Unencrypted pack media is usually on disk already: the grid loads
    // and keeps the same original ([StickerMediaCache.loadOriginal]).
    if (encryptedFile == null) {
      return StickerMediaCache.loadOriginal(
        client,
        mxc,
        isThumbnail: false,
        animated: false,
        thumbnailMethod: ThumbnailMethod.scale,
      );
    }
    final data = await client.downloadMxcCached(mxc);
    final key = encryptedFile.tryGetMap<String, Object?>('key');
    final iv = encryptedFile.tryGet<String>('iv');
    final k = key?.tryGet<String>('k');
    final sha256 = encryptedFile
        .tryGetMap<String, Object?>('hashes')
        ?.tryGet<String>('sha256');
    if (key?.tryGetList<String>('key_ops')?.contains('decrypt') != true ||
        iv == null ||
        k == null ||
        sha256 == null) {
      throw const StickerConvertException('Attachment key cannot decrypt');
    }
    final decrypted = await client.nativeImplementations.decryptFile(
      EncryptedFile(data: data, iv: iv, k: k, sha256: sha256),
    );
    if (decrypted == null) {
      throw const StickerConvertException('Unable to decrypt attachment');
    }
    return decrypted;
  }

  /// The SDK's file path, without the timeline echo: encrypted in an
  /// encrypted room (the ciphertext is uploaded), plain otherwise.
  static Future<Map<String, Object?>> _upload(
    Room room,
    MatrixFile file,
  ) async {
    final client = room.client;
    if (!(room.encrypted && client.fileEncryptionEnabled)) {
      final uri = await client.uploadContent(
        file.bytes,
        filename: file.name,
        contentType: file.mimeType,
      );
      return {'url': uri.toString()};
    }
    final encrypted = await file.encrypt();
    final upload = encrypted.toMatrixFile();
    final uri = await client.uploadContent(
      upload.bytes,
      filename: upload.name,
      contentType: upload.mimeType,
    );
    return {
      'file': {
        'url': uri.toString(),
        'mimetype': file.mimeType,
        'v': 'v2',
        'key': {
          'alg': 'A256CTR',
          'ext': true,
          'k': encrypted.k,
          'key_ops': ['encrypt', 'decrypt'],
          'kty': 'oct',
        },
        'iv': encrypted.iv,
        'hashes': {'sha256': encrypted.sha256},
      },
    };
  }
}

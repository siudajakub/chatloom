// SPDX-License-Identifier: AGPL-3.0-or-later

/// The one photo encoder of Android and macOS (MD-01), installed as the
/// SDK's `customImageResizer`. It applies [PhotoPlan] (the
/// [MediaQuality] sweet spot):
///
/// - the header is read first (format, transparency, EXIF orientation); an
///   image that needs no change goes out as its original bytes with its
///   metadata (EXIF incl. GPS, XMP, text chunks) removed losslessly;
/// - otherwise the engine decodes it **at the target size**
///   (`ImageDescriptor.instantiateCodec(targetWidth:, targetHeight:)`, off
///   the UI thread and honouring EXIF orientation), so no full-resolution
///   RGBA copy exists in Dart;
/// - JPEG is encoded (and the blurhash computed) in a background isolate;
///   a transparent image becomes PNG through the engine, never JPEG, so it
///   never gets a black background;
/// - the output never carries EXIF: the pixels are written without it.
library;

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:blurhash_dart/blurhash_dart.dart';
import 'package:image/image.dart' as img;
import 'package:matrix/matrix.dart';

import 'media_quality.dart';

/// What the header of an encoded image says, without decoding it.
class PhotoHeader {
  final PhotoFormat format;
  final bool hasAlpha;
  final bool animated;

  /// EXIF orientation (1–8) of a JPEG, null when absent.
  final int? orientation;

  /// The stored size, when the header has it (before orientation).
  final int? width, height;

  const PhotoHeader(
    this.format, {
    this.hasAlpha = false,
    this.animated = false,
    this.orientation,
    this.width,
    this.height,
  });

  String? get mimeType => switch (format) {
    PhotoFormat.jpeg => 'image/jpeg',
    PhotoFormat.png => 'image/png',
    PhotoFormat.webp => 'image/webp',
    PhotoFormat.gif => 'image/gif',
    PhotoFormat.heif => null,
    PhotoFormat.other => null,
  };

  /// Reads the format, transparency, animation and orientation from the
  /// first bytes of [bytes]. Unknown or malformed input is [PhotoFormat.other].
  static PhotoHeader sniff(Uint8List bytes) {
    try {
      if (_startsWith(bytes, const [0xFF, 0xD8, 0xFF])) return _jpeg(bytes);
      if (_startsWith(bytes, _pngSignature)) return _png(bytes);
      if (bytes.length >= 16 &&
          _ascii(bytes, 0, 4) == 'RIFF' &&
          _ascii(bytes, 8, 4) == 'WEBP') {
        return _webp(bytes);
      }
      if (bytes.length >= 6 && _ascii(bytes, 0, 4) == 'GIF8') {
        return const PhotoHeader(PhotoFormat.gif, hasAlpha: true);
      }
      if (bytes.length >= 12 && _ascii(bytes, 4, 4) == 'ftyp') {
        const brands = {
          'heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', //
          'mif1', 'msf1', 'avif', 'avis',
        };
        if (brands.contains(_ascii(bytes, 8, 4))) {
          return const PhotoHeader(PhotoFormat.heif);
        }
      }
    } on RangeError {
      // Truncated header: treated as unknown below.
    }
    return const PhotoHeader(PhotoFormat.other);
  }

  static PhotoHeader _jpeg(Uint8List b) {
    int? orientation, width, height;
    var i = 2;
    while (i + 4 <= b.length) {
      if (b[i] != 0xFF) break;
      final marker = b[i + 1];
      if (marker == 0xFF) {
        i++;
        continue;
      }
      if (marker == 0xD8 ||
          marker == 0x01 ||
          (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2;
        continue;
      }
      if (marker == 0xDA || marker == 0xD9) break;
      final length = (b[i + 2] << 8) | b[i + 3];
      final data = i + 4;
      final end = i + 2 + length;
      if (length < 2 || end > b.length) break;
      if (marker == 0xE1 &&
          orientation == null &&
          end - data > 14 &&
          _ascii(b, data, 4) == 'Exif') {
        orientation = _exifOrientation(b, data + 6, end);
      }
      final sof =
          marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (sof && end - data >= 5) {
        height = (b[data + 1] << 8) | b[data + 2];
        width = (b[data + 3] << 8) | b[data + 4];
      }
      i = end;
    }
    return PhotoHeader(
      PhotoFormat.jpeg,
      orientation: orientation,
      width: width,
      height: height,
    );
  }

  static int? _exifOrientation(Uint8List b, int tiff, int end) {
    if (tiff + 8 > end) return null;
    final little = b[tiff] == 0x49;
    int u16(int at) =>
        little ? b[at] | (b[at + 1] << 8) : (b[at] << 8) | b[at + 1];
    int u32(int at) => little
        ? b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24)
        : (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
    final ifd = tiff + u32(tiff + 4);
    if (ifd + 2 > end) return null;
    final count = u16(ifd);
    for (var n = 0; n < count; n++) {
      final entry = ifd + 2 + n * 12;
      if (entry + 12 > end) return null;
      if (u16(entry) == 0x0112) {
        final value = u16(entry + 8);
        return value >= 1 && value <= 8 ? value : null;
      }
    }
    return null;
  }

  static PhotoHeader _png(Uint8List b) {
    if (b.length < 33 || _ascii(b, 12, 4) != 'IHDR') {
      return const PhotoHeader(PhotoFormat.png);
    }
    final width = _u32be(b, 16);
    final height = _u32be(b, 20);
    final colorType = b[25];
    var alpha = colorType == 4 || colorType == 6;
    var animated = false;
    var i = 8;
    while (i + 8 <= b.length) {
      final length = _u32be(b, i);
      final type = _ascii(b, i + 4, 4);
      if (type == 'IDAT' || type == 'IEND') break;
      if (type == 'tRNS') alpha = true;
      if (type == 'acTL') animated = true;
      i += 12 + length;
    }
    return PhotoHeader(
      PhotoFormat.png,
      hasAlpha: alpha,
      animated: animated,
      width: width,
      height: height,
    );
  }

  static PhotoHeader _webp(Uint8List b) {
    final chunk = _ascii(b, 12, 4);
    if (chunk == 'VP8X' && b.length >= 30) {
      final flags = b[20];
      return PhotoHeader(
        PhotoFormat.webp,
        hasAlpha: flags & 0x10 != 0,
        animated: flags & 0x02 != 0,
        width: 1 + (b[24] | (b[25] << 8) | (b[26] << 16)),
        height: 1 + (b[27] | (b[28] << 8) | (b[29] << 16)),
      );
    }
    if (chunk == 'VP8L' && b.length >= 25) {
      final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
      return PhotoHeader(
        PhotoFormat.webp,
        hasAlpha: (bits >> 28) & 1 == 1,
        width: 1 + (bits & 0x3FFF),
        height: 1 + ((bits >> 14) & 0x3FFF),
      );
    }
    return const PhotoHeader(PhotoFormat.webp);
  }
}

const _pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

bool _startsWith(Uint8List b, List<int> prefix) {
  if (b.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (b[i] != prefix[i]) return false;
  }
  return true;
}

String _ascii(Uint8List b, int at, int length) =>
    String.fromCharCodes(b.sublist(at, at + length));

int _u32be(Uint8List b, int at) =>
    (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];

/// [bytes] without the metadata that can identify where or with what it was
/// taken, losslessly (the pixels are untouched):
///
/// - JPEG: APP1 (EXIF incl. GPS, XMP), APP12, APP13 (IPTC) and comments go;
///   JFIF, ICC profile/MPF (APP2) and Adobe (APP14) stay;
/// - PNG: `eXIf`, `tEXt`, `zTXt`, `iTXt` and `tIME` go;
/// - WebP: `EXIF` and `XMP ` go (and their VP8X flags).
///
/// Other formats, and input it cannot parse, are returned unchanged.
Uint8List stripPhotoMetadata(Uint8List bytes, [PhotoFormat? format]) {
  try {
    switch (format ?? PhotoHeader.sniff(bytes).format) {
      case PhotoFormat.jpeg:
        return _stripJpeg(bytes) ?? bytes;
      case PhotoFormat.png:
        return _stripPng(bytes) ?? bytes;
      case PhotoFormat.webp:
        return _stripWebp(bytes) ?? bytes;
      case PhotoFormat.gif:
      case PhotoFormat.heif:
      case PhotoFormat.other:
        return bytes;
    }
  } on RangeError {
    return bytes;
  }
}

Uint8List? _stripJpeg(Uint8List b) {
  final out = BytesBuilder(copy: false)..add(Uint8List.sublistView(b, 0, 2));
  var changed = false;
  var i = 2;
  while (i + 2 <= b.length) {
    if (b[i] != 0xFF) return null;
    final marker = b[i + 1];
    if (marker == 0xFF) {
      i++;
      continue;
    }
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      out.add(Uint8List.sublistView(b, i, i + 2));
      i += 2;
      continue;
    }
    if (marker == 0xDA || marker == 0xD9) {
      // Start of scan: the entropy-coded data and everything after it are
      // copied as they are.
      out.add(Uint8List.sublistView(b, i));
      return changed ? out.takeBytes() : b;
    }
    if (i + 4 > b.length) return null;
    final end = i + 2 + ((b[i + 2] << 8) | b[i + 3]);
    if (end > b.length) return null;
    final drop =
        marker == 0xE1 || marker == 0xEC || marker == 0xED || marker == 0xFE;
    if (drop) {
      changed = true;
    } else {
      out.add(Uint8List.sublistView(b, i, end));
    }
    i = end;
  }
  return null;
}

Uint8List? _stripPng(Uint8List b) {
  const drop = {'eXIf', 'tEXt', 'zTXt', 'iTXt', 'tIME'};
  final out = BytesBuilder(copy: false)..add(Uint8List.sublistView(b, 0, 8));
  var changed = false;
  var i = 8;
  while (i + 12 <= b.length) {
    final end = i + 12 + _u32be(b, i);
    if (end > b.length) return null;
    final type = _ascii(b, i + 4, 4);
    if (drop.contains(type)) {
      changed = true;
    } else {
      out.add(Uint8List.sublistView(b, i, end));
    }
    i = end;
    if (type == 'IEND') break;
  }
  return changed ? out.takeBytes() : b;
}

Uint8List? _stripWebp(Uint8List b) {
  final chunks = <Uint8List>[];
  var changed = false;
  var i = 12;
  while (i + 8 <= b.length) {
    final size =
        b[i + 4] | (b[i + 5] << 8) | (b[i + 6] << 16) | (b[i + 7] << 24);
    final end = i + 8 + size + (size & 1);
    if (end > b.length) return null;
    final type = _ascii(b, i, 4);
    if (type == 'EXIF' || type == 'XMP ') {
      changed = true;
    } else if (type == 'VP8X') {
      final copy = Uint8List.fromList(b.sublist(i, end));
      copy[8] &= ~0x0C; // EXIF and XMP flags
      chunks.add(copy);
    } else {
      chunks.add(Uint8List.sublistView(b, i, end));
    }
    i = end;
  }
  if (!changed) return b;
  final body = chunks.fold<int>(0, (sum, c) => sum + c.length);
  final riff = 4 + body;
  final out = BytesBuilder(copy: false)
    ..add(Uint8List.fromList('RIFF'.codeUnits))
    ..add(Uint8List(4)..buffer.asByteData().setUint32(0, riff, Endian.little))
    ..add(Uint8List.fromList('WEBP'.codeUnits));
  for (final chunk in chunks) {
    out.add(chunk);
  }
  return out.takeBytes();
}

/// Encodes straight (non-premultiplied) RGBA pixels as JPEG in a background
/// isolate; optionally computes the blurhash of the same pixels there.
Future<(Uint8List, String?)> encodeJpegRgba(
  Uint8List rgba,
  int width,
  int height, {
  required int quality,
  bool fullChroma = false,
  bool blurhash = false,
}) => Isolate.run(
  () => _encodeJpegJob(rgba, width, height, quality, fullChroma, blurhash),
  debugName: 'chatloom-jpeg',
);

(Uint8List, String?) _encodeJpegJob(
  Uint8List rgba,
  int width,
  int height,
  int quality,
  bool fullChroma,
  bool blurhash,
) {
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    bytesOffset: rgba.offsetInBytes,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  final jpeg = img.encodeJpg(
    image,
    quality: quality,
    chroma: fullChroma ? img.JpegChroma.yuv444 : img.JpegChroma.yuv420,
  );
  return (jpeg, blurhash ? _blurhashOf(image) : null);
}

String _blurhashOf(img.Image image) {
  final long = math.max(image.width, image.height);
  final small = long <= 64
      ? image
      : img.copyResize(
          image,
          width: image.width >= image.height ? 64 : null,
          height: image.height > image.width ? 64 : null,
          interpolation: img.Interpolation.average,
        );
  return BlurHash.encode(small, numCompX: 4, numCompY: 3).hash;
}

/// Decodes [bytes] with the engine at [width] × [height] (or the natural
/// size when null). Returns the frame count with the first frame.
Future<(ui.Image, int)> _decode(
  Uint8List bytes, {
  int? width,
  int? height,
}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final codec = await descriptor.instantiateCodec(
      targetWidth: width,
      targetHeight: height,
    );
    try {
      final frames = codec.frameCount;
      final frame = await codec.getNextFrame();
      return (frame.image, frames);
    } finally {
      codec.dispose();
    }
  } finally {
    descriptor?.dispose();
    buffer.dispose();
  }
}

/// The displayed size of [bytes] (after EXIF orientation), from the header.
Future<(int, int)> _probe(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return (descriptor.width, descriptor.height);
  } finally {
    descriptor?.dispose();
    buffer.dispose();
  }
}

Future<String?> _blurhashFromBytes(
  Uint8List bytes,
  int width,
  int height,
) async {
  final long = math.max(width, height);
  final scale = long <= 32 ? 1.0 : 32 / long;
  final (image, _) = await _decode(
    bytes,
    width: math.max(1, (width * scale).round()),
    height: math.max(1, (height * scale).round()),
  );
  try {
    return await _blurhashOfImage(image);
  } finally {
    image.dispose();
  }
}

Future<String?> _blurhashOfImage(ui.Image image) async {
  final data = await image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );
  if (data == null) return null;
  final pixels = img.Image.fromBytes(
    width: image.width,
    height: image.height,
    bytes: data.buffer,
    bytesOffset: data.offsetInBytes,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return _blurhashOf(pixels);
}

/// The SDK's `customImageResizer` (photos and their thumbnails; see the
/// library comment). Returns null only when the image cannot be read at
/// all; the SDK then sends the original.
Future<MatrixImageFileResizedResponse?> encodePhoto(
  MatrixImageFileResizeArguments arguments,
) async {
  final bytes = arguments.bytes;
  final header = PhotoHeader.sniff(bytes);
  int width, height;
  try {
    (width, height) = await _probe(bytes);
  } catch (e) {
    Logs().w('Photo could not be read for sending', e.runtimeType);
    // Undecodable here (e.g. a format the engine lacks): still never send
    // its location when the container is one we can clean.
    final w = header.width, h = header.height;
    if (w == null || h == null) return null;
    final turned = (header.orientation ?? 1) >= 5;
    return MatrixImageFileResizedResponse(
      bytes: stripPhotoMetadata(bytes, header.format),
      width: turned ? h : w,
      height: turned ? w : h,
      originalWidth: turned ? h : w,
      originalHeight: turned ? w : h,
      mimeType: header.mimeType,
    );
  }
  final plan = PhotoPlan.decide(
    format: header.format,
    width: width,
    height: height,
    bytes: bytes.length,
    maxSide: arguments.maxDimension,
    hasAlpha: header.hasAlpha,
    animated: header.animated,
    orientation: header.orientation,
  );

  Future<MatrixImageFileResizedResponse> keep() async =>
      MatrixImageFileResizedResponse(
        bytes: stripPhotoMetadata(bytes, header.format),
        width: width,
        height: height,
        originalWidth: width,
        originalHeight: height,
        mimeType: header.mimeType,
        blurhash: arguments.calcBlurhash && !header.hasAlpha
            ? await _safeBlurhash(bytes, width, height)
            : null,
      );

  if (plan.action == PhotoAction.keep) return await keep();
  final (image, frames) = await _decode(
    bytes,
    width: plan.width,
    height: plan.height,
  );
  try {
    // Animated: resizing would keep only the first frame.
    if (frames > 1) return await keep();
    final outWidth = image.width, outHeight = image.height;
    if (plan.action == PhotoAction.png) {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) return await keep();
      return MatrixImageFileResizedResponse(
        bytes: png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        width: outWidth,
        height: outHeight,
        originalWidth: width,
        originalHeight: height,
        mimeType: 'image/png',
      );
    }
    final rgba = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    if (rgba == null) return await keep();
    final (jpeg, blurhash) = await encodeJpegRgba(
      rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes),
      outWidth,
      outHeight,
      quality: plan.quality,
      fullChroma: plan.fullChroma,
      blurhash: arguments.calcBlurhash,
    );
    return MatrixImageFileResizedResponse(
      bytes: jpeg,
      width: outWidth,
      height: outHeight,
      originalWidth: width,
      originalHeight: height,
      mimeType: 'image/jpeg',
      blurhash: blurhash,
    );
  } finally {
    image.dispose();
  }
}

Future<String?> _safeBlurhash(Uint8List bytes, int width, int height) async {
  try {
    return await _blurhashFromBytes(bytes, width, height);
  } catch (_) {
    return null;
  }
}

/// Whether [bytes] may hold transparent pixels (from the header only): such
/// an image must never become JPEG.
bool photoHasAlpha(Uint8List bytes) {
  final header = PhotoHeader.sniff(bytes);
  return header.hasAlpha || header.format == PhotoFormat.gif;
}

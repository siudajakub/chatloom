// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:chatloom/personal/media/editor/media_edit_plan.dart';
import 'package:chatloom/personal/media/photo_encoder.dart';
import 'package:flutter/foundation.dart';

/// The photo the editor works on: [bytes] themselves when their longest
/// side is at most [maxSide], otherwise a copy scaled down to it.
///
/// The edited photo is never larger than [editedPhotoMaxSide], while the
/// editor decodes its source in full several times (the stage, its size
/// probe on open and on every undo, each tool). A 48 MP photo is 192 MB per
/// decode; scaled to 4096 px it is 50 MB, at the same output. The copy is
/// decoded by the engine at the target size (off the UI thread, EXIF
/// orientation applied) and stored as an uncompressed bitmap, which costs a
/// copy instead of an encode and decodes as fast as it is read.
///
/// Anything unexpected (an undecodable or animated source) returns [bytes].
Future<Uint8List> preparePhotoForEditing(
  Uint8List bytes, {
  double maxSide = editedPhotoMaxSide,
}) async {
  if (photoFitsEditing(bytes, maxSide: maxSide)) return bytes;
  final header = PhotoHeader.sniff(bytes);
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final long = math.max(descriptor.width, descriptor.height);
    if (long <= maxSide) return bytes;
    final scale = maxSide / long;
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (descriptor.width * scale).round()),
      targetHeight: math.max(1, (descriptor.height * scale).round()),
    );
    if (codec.frameCount > 1) return bytes;
    image = (await codec.getNextFrame()).image;
    final (outWidth, outHeight) = (image.width, image.height);
    final pixels = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    // Freed before the bitmap is built: at most two copies of the pixels
    // (about 100 MB at 4096 × 3072) exist at once, never three.
    image.dispose();
    image = null;
    codec.dispose();
    codec = null;
    if (pixels == null) return bytes;
    return rgbaBitmap(
      pixels.buffer.asUint8List(pixels.offsetInBytes, pixels.lengthInBytes),
      outWidth,
      outHeight,
      alpha: header.hasAlpha,
    );
  } catch (_) {
    return bytes;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// Whether [bytes] can go to the editor as they are: their header says they
/// are within [maxSide] (or animated, which the editor keeps whole). When
/// it does not say (HEIF), [preparePhotoForEditing] finds out.
bool photoFitsEditing(Uint8List bytes, {double maxSide = editedPhotoMaxSide}) {
  final header = PhotoHeader.sniff(bytes);
  if (header.animated) return true;
  final width = header.width, height = header.height;
  return width != null && height != null && math.max(width, height) <= maxSide;
}

/// Wraps straight RGBA pixels, row by row from the top, in a 32-bit BMP
/// (BITMAPV4HEADER with bit-field masks for that byte order), so the engine
/// decodes them without a conversion. Without [alpha] the alpha channel is
/// ignored and the bitmap is opaque.
@visibleForTesting
Uint8List rgbaBitmap(
  Uint8List rgba,
  int width,
  int height, {
  bool alpha = false,
}) {
  assert(rgba.length == width * height * 4, 'RGBA of width × height');
  const fileHeader = 14, infoHeader = 108;
  const offset = fileHeader + infoHeader;
  final out = Uint8List(offset + rgba.length);
  final data = ByteData.sublistView(out);
  data
    // 'BM'.
    ..setUint16(0, 0x4D42, Endian.little)
    ..setUint32(2, out.length, Endian.little)
    ..setUint32(10, offset, Endian.little)
    ..setUint32(14, infoHeader, Endian.little)
    ..setInt32(18, width, Endian.little)
    // Negative: the rows are stored top-down.
    ..setInt32(22, -height, Endian.little)
    ..setUint16(26, 1, Endian.little)
    ..setUint16(28, 32, Endian.little)
    // BI_BITFIELDS.
    ..setUint32(30, 3, Endian.little)
    ..setUint32(34, rgba.length, Endian.little)
    ..setInt32(38, 2835, Endian.little)
    ..setInt32(42, 2835, Endian.little)
    ..setUint32(54, 0x000000FF, Endian.little)
    ..setUint32(58, 0x0000FF00, Endian.little)
    ..setUint32(62, 0x00FF0000, Endian.little)
    ..setUint32(66, alpha ? 0xFF000000 : 0, Endian.little)
    // LCS_sRGB.
    ..setUint32(70, 0x73524742, Endian.little);
  out.setRange(offset, out.length, rgba);
  return out;
}

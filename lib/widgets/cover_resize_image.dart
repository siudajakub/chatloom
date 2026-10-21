// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Decodes [imageProvider] at the smallest size that still covers a
/// [width] × [height] (physical pixels) box with [BoxFit.cover], keeping the
/// aspect ratio and never upscaling. [ResizeImage] can only fit inside a box,
/// which leaves a covering image soft; decoding a full-resolution photo for
/// a phone-sized background wastes memory and upload bandwidth to the GPU.
@immutable
class CoverResizeImage extends ImageProvider<CoverResizeImageKey> {
  final ImageProvider imageProvider;
  final int width;
  final int height;

  const CoverResizeImage(
    this.imageProvider, {
    required this.width,
    required this.height,
  }) : assert(width > 0 && height > 0);

  /// Target decode size for an [intrinsicWidth] × [intrinsicHeight] image.
  static ui.TargetImageSize coverSize(
    int intrinsicWidth,
    int intrinsicHeight,
    int width,
    int height,
  ) {
    if (intrinsicWidth <= 0 || intrinsicHeight <= 0) {
      return const ui.TargetImageSize();
    }
    final scale = math.max(width / intrinsicWidth, height / intrinsicHeight);
    if (scale >= 1) return const ui.TargetImageSize();
    return ui.TargetImageSize(
      width: math.max(1, (intrinsicWidth * scale).ceil()),
      height: math.max(1, (intrinsicHeight * scale).ceil()),
    );
  }

  @override
  Future<CoverResizeImageKey> obtainKey(ImageConfiguration configuration) =>
      imageProvider
          .obtainKey(configuration)
          .then((key) => CoverResizeImageKey._(key, width, height));

  @override
  ImageStreamCompleter loadImage(
    CoverResizeImageKey key,
    ImageDecoderCallback decode,
  ) {
    Future<ui.Codec> decodeCover(
      ui.ImmutableBuffer buffer, {
      ui.TargetImageSizeCallback? getTargetSize,
    }) => decode(
      buffer,
      getTargetSize: (intrinsicWidth, intrinsicHeight) =>
          coverSize(intrinsicWidth, intrinsicHeight, width, height),
    );
    return imageProvider.loadImage(key._providerKey, decodeCover);
  }
}

@immutable
class CoverResizeImageKey {
  final Object _providerKey;
  final int _width;
  final int _height;
  const CoverResizeImageKey._(this._providerKey, this._width, this._height);

  @override
  bool operator ==(Object other) =>
      other is CoverResizeImageKey &&
      other._providerKey == _providerKey &&
      other._width == _width &&
      other._height == _height;

  @override
  int get hashCode => Object.hash(_providerKey, _width, _height);
}

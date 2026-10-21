// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;

import 'package:blurhash_dart/blurhash_dart.dart' as b;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;
import 'package:material_ui/material_ui.dart';

class BlurHash extends StatefulWidget {
  final double width;
  final double height;
  final String blurhash;
  final BoxFit fit;

  const BlurHash({
    super.key,
    String? blurhash,
    required this.width,
    required this.height,
    this.fit = BoxFit.cover,
  }) : blurhash = blurhash ?? 'LEHV6nWB2yk8pyo0adR*.7kCMdnj';

  @override
  State<BlurHash> createState() => _BlurHashState();

  @visibleForTesting
  static int get cachedCount => _BlurHashState._cache.length;

  @visibleForTesting
  static void clearCache() => _BlurHashState._cache.clear();

  /// Replaces the isolate decode in tests; production decodes off the UI
  /// thread with `compute`.
  @visibleForTesting
  static set decoder(Future<Uint8List> Function(BlurhashData data) decode) =>
      _BlurHashState.decoder = decode;

  @visibleForTesting
  static Future<Uint8List> decodeInline(BlurhashData data) =>
      _BlurHashState.getBlurhashData(data);
}

class _BlurHashState extends State<BlurHash> {
  /// Decoded placeholders shared across mounts: scrolling an image-heavy
  /// chat back and forth must not spawn a decode isolate per row each time.
  static const _cacheSize = 64;
  static final _cache = <(String, int, int), _Decoded>{};

  Future<Uint8List>? _future;
  Uint8List? _data;

  static Future<Uint8List> Function(BlurhashData data) decoder = (data) =>
      compute(getBlurhashData, data);

  static Future<Uint8List> getBlurhashData(BlurhashData blurhashData) async {
    final blurhash = b.BlurHash.decode(blurhashData.hsh);
    final img = blurhash.toImage(blurhashData.w, blurhashData.h);
    return Uint8List.fromList(image.encodePng(img));
  }

  static (int, int) _size(double width, double height) {
    final ratio = width / height;
    var w = 32;
    var h = 32;
    if (!ratio.isFinite || ratio <= 0) return (w, h);
    if (ratio > 1.0) {
      h = math.max(1, (w / ratio).round());
    } else {
      w = math.max(1, (h * ratio).round());
    }
    return (w, h);
  }

  static _Decoded _decode(String hash, int w, int h) {
    final key = (hash, w, h);
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached; // most recently used last
      return cached;
    }
    final entry = _Decoded(decoder(BlurhashData(hsh: hash, w: w, h: h)));
    _cache[key] = entry;
    entry.future.then<void>(
      (data) => entry.data = data,
      // A failed decode is not remembered, so a later mount can retry.
      onError: (Object _) {
        if (identical(_cache[key], entry)) _cache.remove(key);
      },
    );
    while (_cache.length > _cacheSize) {
      _cache.remove(_cache.keys.first);
    }
    return entry;
  }

  void _resolve() {
    final (w, h) = _size(widget.width, widget.height);
    final entry = _decode(widget.blurhash, w, h);
    final future = _future = entry.future;
    // A decoded placeholder shows on the first frame, without a flash.
    _data = entry.data;
    if (_data != null) return;
    future.then((data) {
      if (mounted && identical(_future, future)) {
        setState(() => _data = data);
      }
    }, onError: (Object _) {});
  }

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(BlurHash oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.blurhash != widget.blurhash ||
        _size(oldWidget.width, oldWidget.height) !=
            _size(widget.width, widget.height)) {
      _resolve();
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data == null) {
      return Container(
        width: widget.width,
        height: widget.height,
        color: Theme.of(context).colorScheme.onInverseSurface,
      );
    }
    return Image.memory(
      data,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      gaplessPlayback: true,
      errorBuilder: (context, _, _) =>
          SizedBox(width: widget.width, height: widget.height),
    );
  }
}

class _Decoded {
  final Future<Uint8List> future;
  Uint8List? data;
  _Decoded(this.future);
}

class BlurhashData {
  final String hsh;
  final int w;
  final int h;

  const BlurhashData({required this.hsh, required this.w, required this.h});

  factory BlurhashData.fromJson(Map<String, dynamic> json) =>
      BlurhashData(hsh: json['hsh'], w: json['w'], h: json['h']);

  Map<String, dynamic> toJson() => {'hsh': hsh, 'w': w, 'h': h};
}

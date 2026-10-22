// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:lottie/lottie.dart';

/// Lottie stickers as the bridges send them: Telegram's TGS (gzip-compressed
/// Lottie JSON, `application/x-tgsticker`) and plain Lottie JSON
/// (`video/lottie+json`, used by mautrix-telegram with `animated_sticker`
/// conversion off and by WhatsApp's `application/was`).
abstract final class LottieStickerData {
  /// Mimetypes that announce Lottie content.
  static const mimeTypes = {
    'application/x-tgsticker',
    'video/lottie+json',
    'application/json',
    'application/was',
  };

  /// Compressed data above this size is decoded on a background isolate.
  static const isolateThreshold = 32 * 1024;

  static bool isLottieMime(String? mimeType) =>
      mimeType != null && mimeTypes.contains(mimeType.toLowerCase());

  static bool _gzip(Uint8List data) =>
      data.length > 2 && data[0] == 0x1f && data[1] == 0x8b;

  /// The Lottie JSON bytes of [data] (gunzipped when needed), or null when
  /// [data] is neither a TGS nor a Lottie JSON document. Plain JSON is only
  /// taken when it looks like Lottie (an object with `layers`), so ordinary
  /// images and files never reach the parser.
  static Uint8List? jsonBytes(Uint8List data) {
    Uint8List json;
    if (_gzip(data)) {
      try {
        json = Uint8List.fromList(GZipDecoder().decodeBytes(data));
      } catch (_) {
        return null;
      }
    } else {
      json = data;
    }
    var start = 0;
    while (start < json.length && _whitespace(json[start])) {
      start++;
    }
    if (start >= json.length || json[start] != 0x7b /* { */ ) return null;
    if (!_contains(json, _layersKey)) return null;
    return json;
  }

  static bool _whitespace(int byte) =>
      byte == 0x20 || byte == 0x0a || byte == 0x0d || byte == 0x09;

  static final _layersKey = Uint8List.fromList('"layers"'.codeUnits);

  static bool _contains(Uint8List haystack, Uint8List needle) {
    final last = haystack.length - needle.length;
    outer:
    for (var i = 0; i <= last; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  /// Parses [data] (TGS or Lottie JSON) into a composition, or null.
  static LottieComposition? parse(Uint8List data) {
    final json = jsonBytes(data);
    if (json == null) return null;
    try {
      return LottieComposition.parseJsonBytes(json);
    } catch (_) {
      return null;
    }
  }

  /// [parse], on a background isolate for large data. A composition that
  /// cannot cross isolates is parsed here instead.
  static Future<LottieComposition?> decode(Uint8List data) async {
    if (data.length <= isolateThreshold) return parse(data);
    try {
      return await compute(parse, data, debugLabel: 'lottie-sticker');
    } catch (_) {
      return parse(data);
    }
  }
}

/// A small LRU of parsed compositions, so a sticker scrolled back into view
/// (or shown twice) is not gunzipped and parsed again.
class LottieCompositionCache<K> {
  LottieCompositionCache({this.capacity = 48});

  final int capacity;
  final _entries = <K, LottieComposition>{};

  LottieComposition? get(K key) {
    final hit = _entries.remove(key);
    if (hit != null) _entries[key] = hit;
    return hit;
  }

  void put(K key, LottieComposition composition) {
    _entries
      ..remove(key)
      ..[key] = composition;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  void clear() => _entries.clear();

  int get length => _entries.length;
}

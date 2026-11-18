// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatloom/personal/stickers/sticker_media_cache.dart';
import 'package:chatloom/utils/client_download_content_extension.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/flutter_matrix_dart_sdk_database/cipher.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';

import 'cache_budget.dart';

/// Long-lived disk cache of avatars (rooms, people, bridged contacts).
///
/// Avatars used to go through the SQLCipher media cache: shared with every
/// photo (pushed out by them), reads queued behind sync, one request per
/// widget size and no sharing between rows asking at the same time. Bridged
/// avatars (Instagram through the Meta bridge's direct media) are fetched
/// from the network service on demand and sometimes time out or 404 for a
/// moment; once stored here they never depend on that again.
///
/// Storage is a [StickerMediaCache] (AES-256-GCM sealed files, private
/// folder, LRU) of its own folder and key. Every avatar is kept in a few
/// physical size buckets ([bucketFor]), so the inbox row, the chat header
/// and the details page share one file. mxc URIs are immutable: a changed
/// avatar is a new URI, so nothing goes stale.
class AvatarCache {
  static const String folderName = 'chatloom_avatar_cache';
  static const String keyStorageName = 'avatar_cache_key_v1';
  static const int maxBytes = 96 * 1024 * 1024;
  static const Duration retention = Duration(days: 120);

  /// A row must never fetch an unbounded original when a bridge has no
  /// thumbnail. The full viewer is an explicit action with a larger cap.
  static const previewDownloadMaxBytes = 2 * 1024 * 1024;
  static const fullDownloadMaxBytes = 64 * 1024 * 1024;

  /// Physical thumbnail sizes asked of the server.
  static const List<int> buckets = [96, 256, 640];

  static Future<StickerMediaCache?>? _shared;
  static int _generation = 0;
  static final _loads =
      <(Client, String?, Uri, int, bool), Future<Uint8List>>{};

  static Future<StickerMediaCache?> shared() => _shared ??= _open();

  static Future<StickerMediaCache?> _open() async {
    if (kIsWeb) return null;
    try {
      final raw = base64Url.decode(
        await getProtectedStorageCipher(keyStorageName),
      );
      final base = await getApplicationSupportDirectory();
      final budget = await MediaCacheBudget.read();
      return await StickerMediaCache.open(
        Directory('${base.path}/$folderName'),
        key: raw,
        maxBytes: budget.avatarBytes,
        retention: retention,
        trimOnOpen: false,
      );
    } catch (error) {
      Logs().w('avatar_cache_unavailable', error.runtimeType.toString());
      return null;
    }
  }

  @visibleForTesting
  static void debugSetShared(StickerMediaCache? cache) =>
      _shared = Future.value(cache);

  @visibleForTesting
  static void debugResetShared() {
    _shared = null;
    _resetPending();
  }

  /// Logout / "clear cache".
  static Future<void> clearShared() async {
    _resetPending();
    if (kIsWeb) return;
    try {
      final cache = await _shared;
      if (cache != null) return await cache.clear();
      final base = await getApplicationSupportDirectory();
      final folder = Directory('${base.path}/$folderName');
      if (!await folder.exists()) return;
      await StickerMediaCache.open(
        folder,
        key: base64Url.decode(await getProtectedStorageCipher(keyStorageName)),
      ).then((cache) => cache.clear());
    } catch (error) {
      Logs().w('avatar_cache_clear_failed', error.runtimeType.toString());
    }
  }

  /// The smallest bucket covering [physicalSide] (the largest beyond it).
  static int bucketFor(num? physicalSide) {
    final side = physicalSide ?? buckets.first;
    for (final bucket in buckets) {
      if (side <= bucket) return bucket;
    }
    return buckets.last;
  }

  /// [MxcBytesLoader] for avatars: a crop thumbnail of the bucket covering
  /// the requested size, from disk when known; a missing thumbnail falls
  /// back to the original (kept under the bucket too).
  static Future<Uint8List> loadAvatar(
    Client client,
    Uri uri, {
    num? width,
    num? height,
    required bool isThumbnail,
    required bool animated,
    required ThumbnailMethod thumbnailMethod,
  }) {
    final side = bucketFor(
      width == null || height == null
          ? (width ?? height)
          : (width > height ? width : height),
    );
    final account = client.userID;
    final key = (client, account, uri, side, isThumbnail);
    final pending = _loads[key];
    if (pending != null) return pending;
    final generation = _generation;
    final load = _load(client, uri, side, isThumbnail, account, generation);
    _loads[key] = load;
    void remove() {
      if (identical(_loads[key], load)) _loads.remove(key);
    }

    unawaited(
      load.then<void>((_) => remove(), onError: (Object _) => remove()),
    );
    return load;
  }

  static Future<Uint8List> _load(
    Client client,
    Uri uri,
    int side,
    bool isThumbnail,
    String? account,
    int generation,
  ) async {
    void checkCurrent() {
      if (generation != _generation || client.userID != account) {
        throw StateError('avatar_load_cancelled');
      }
    }

    Future<Uint8List> download() async {
      checkCurrent();
      if (!isThumbnail) {
        final bytes = await client.downloadMxcCached(
          uri,
          databaseCache: false,
          maxBytes: fullDownloadMaxBytes,
        );
        checkCurrent();
        return bytes;
      }
      try {
        final bytes = await client.downloadMxcCached(
          uri,
          width: side,
          height: side,
          thumbnailMethod: ThumbnailMethod.crop,
          isThumbnail: true,
          animated: false,
          databaseCache: false,
          maxBytes: previewDownloadMaxBytes,
        );
        checkCurrent();
        if (looksLikeImage(bytes)) return bytes;
        // A thumbnail the device cannot decode (an error page served as
        // 200, an unknown format) falls through to the original below.
        throw const _UndecodableThumbnail();
      } on _UndecodableThumbnail {
        checkCurrent();
      } on MatrixException catch (e) {
        // Missing bridge thumbnails may fall back to a bounded original.
        // A server outage or rate limit must not fan out into another GET.
        if (e.error == MatrixError.M_LIMIT_EXCEEDED ||
            e.response?.statusCode == 429 ||
            (e.response?.statusCode ?? 0) >= 500) {
          rethrow;
        }
        checkCurrent();
      }
      final bytes = await client.downloadMxcCached(
        uri,
        databaseCache: false,
        maxBytes: previewDownloadMaxBytes,
      );
      checkCurrent();
      if (!looksLikeImage(bytes)) {
        throw const FormatException('avatar_not_an_image');
      }
      return bytes;
    }

    final cache = await shared();
    checkCurrent();
    if (cache == null || account == null) return download();
    final key = StickerMediaCache.keyFor(
      account,
      uri,
      isThumbnail ? 'avatar:$side' : 'avatar:original',
    );
    final bytes = await cache.fetch(key, download);
    checkCurrent();
    if (!isThumbnail || looksLikeImage(bytes)) return bytes;
    // Undecodable bytes stored by an older build would otherwise be served
    // for 120 days and every retry would show the same broken avatar.
    await cache.remove(key);
    checkCurrent();
    return cache.fetch(key, download);
  }

  /// Signature check for formats the platform decoders handle. Bytes that
  /// are none of these are never stored, so a later retry asks again.
  @visibleForTesting
  static bool looksLikeImage(Uint8List b) {
    bool at(int offset, List<int> sig) {
      if (b.length < offset + sig.length) return false;
      for (var i = 0; i < sig.length; i++) {
        if (b[offset + i] != sig[i]) return false;
      }
      return true;
    }

    return at(0, const [0xFF, 0xD8, 0xFF]) || // JPEG
        at(0, const [0x89, 0x50, 0x4E, 0x47]) || // PNG
        at(0, const [0x47, 0x49, 0x46, 0x38]) || // GIF
        (at(0, const [0x52, 0x49, 0x46, 0x46]) &&
            at(8, const [0x57, 0x45, 0x42, 0x50])) || // WebP
        at(4, const [0x66, 0x74, 0x79, 0x70]) || // HEIC/AVIF (ftyp)
        at(0, const [0x42, 0x4D]) || // BMP
        at(0, const [0x00, 0x00, 0x01, 0x00]); // ICO
  }

  /// Keys already queued or stored by [prefetch] in this run.
  static final _prefetched = <String>{};
  static final _pending = <String>{};
  static final _queue = <(Client, String, Uri, int, int)>[];
  static int _running = 0;
  static const int _parallel = 2;
  static const int maxQueued = 64;
  static const int maxRemembered = 512;

  @visibleForTesting
  static int get queuedCount => _queue.length;
  @visibleForTesting
  static int get rememberedCount => _prefetched.length;

  static String _prefetchKey(String account, Uri uri, int side) =>
      '$account\n$uri\n$side';

  static void _resetPending() {
    _generation++;
    _queue.clear();
    _pending.clear();
    _prefetched.clear();
    _loads.clear();
  }

  /// Storage settings revoke both queued prefetch and in-progress loads.
  static void cancelPending() => _resetPending();

  /// Warms the disk cache for [uris] at [physicalSide] (inbox rows beyond
  /// the screen), a couple at a time, so a scroll shows them from disk.
  /// Repeated calls with the same avatars cost nothing; failures are
  /// silent (the row asks again when built).
  static void prefetch(Client client, Iterable<Uri> uris, num physicalSide) {
    final account = client.userID;
    if (kIsWeb || account == null) return;
    final side = bucketFor(physicalSide);
    for (final uri in uris) {
      if (!uri.isScheme('mxc')) continue;
      final key = _prefetchKey(account, uri, side);
      if (_pending.contains(key)) continue;
      if (_prefetched.remove(key)) {
        _prefetched.add(key);
        continue;
      }
      if (_queue.length == maxQueued) {
        final (_, droppedAccount, droppedUri, droppedSide, _) = _queue.removeAt(
          0,
        );
        _pending.remove(_prefetchKey(droppedAccount, droppedUri, droppedSide));
      }
      _pending.add(key);
      _queue.add((client, account, uri, side, _generation));
    }
    _pump();
  }

  static void _pump() {
    while (_running < _parallel && _queue.isNotEmpty) {
      final (client, account, uri, side, generation) = _queue.removeAt(0);
      final key = _prefetchKey(account, uri, side);
      if (client.userID != account || generation != _generation) {
        _pending.remove(key);
        continue;
      }
      _running++;
      unawaited(
        loadAvatar(
              client,
              uri,
              width: side,
              height: side,
              isThumbnail: true,
              animated: false,
              thumbnailMethod: ThumbnailMethod.crop,
            )
            .then<void>((_) {
              if (generation != _generation) return;
              _prefetched.add(key);
              if (_prefetched.length > maxRemembered) {
                _prefetched.remove(_prefetched.first);
              }
            })
            .catchError((Object _) {})
            .whenComplete(() {
              if (generation == _generation) _pending.remove(key);
              _running--;
              _pump();
            }),
      );
    }
  }
}

class _UndecodableThumbnail implements Exception {
  const _UndecodableThumbnail();
}

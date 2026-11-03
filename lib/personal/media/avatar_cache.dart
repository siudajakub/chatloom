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

  /// Physical thumbnail sizes asked of the server.
  static const List<int> buckets = [96, 256, 640];

  static Future<StickerMediaCache?>? _shared;

  static Future<StickerMediaCache?> shared() => _shared ??= _open();

  static Future<StickerMediaCache?> _open() async {
    if (kIsWeb) return null;
    try {
      final raw = base64Url.decode(
        await getProtectedStorageCipher(keyStorageName),
      );
      final base = await getApplicationSupportDirectory();
      return await StickerMediaCache.open(
        Directory('${base.path}/$folderName'),
        key: raw,
        maxBytes: maxBytes,
        retention: retention,
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
  static void debugResetShared() => _shared = null;

  /// Logout / "clear cache".
  static Future<void> clearShared() async {
    if (kIsWeb) return;
    try {
      _queue.clear();
      _prefetched.clear();
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
  }) async {
    final side = bucketFor(
      width == null || height == null
          ? (width ?? height)
          : (width > height ? width : height),
    );
    Future<Uint8List> download() async {
      if (!isThumbnail) {
        return client.downloadMxcCached(uri, databaseCache: false);
      }
      try {
        return await client.downloadMxcCached(
          uri,
          width: side,
          height: side,
          thumbnailMethod: ThumbnailMethod.crop,
          isThumbnail: true,
          animated: false,
          databaseCache: false,
        );
      } on MatrixException catch (e) {
        // Bridge direct media may serve originals while thumbnail generation
        // fails (including 5xx). A rate limit still backs off immediately.
        if (e.error == MatrixError.M_LIMIT_EXCEEDED) rethrow;
        return client.downloadMxcCached(uri, databaseCache: false);
      }
    }

    final cache = await shared();
    final account = client.userID;
    if (cache == null || account == null) return download();
    return cache.fetch(
      StickerMediaCache.keyFor(
        account,
        uri,
        isThumbnail ? 'avatar:$side' : 'avatar:original',
      ),
      download,
    );
  }

  /// Keys already queued or stored by [prefetch] in this run.
  static final _prefetched = <String>{};
  static final _queue = <(Client, Uri, int)>[];
  static int _running = 0;
  static const int _parallel = 2;

  /// Warms the disk cache for [uris] at [physicalSide] (inbox rows beyond
  /// the screen), a couple at a time, so a scroll shows them from disk.
  /// Repeated calls with the same avatars cost nothing; failures are
  /// silent (the row asks again when built).
  static void prefetch(Client client, Iterable<Uri> uris, num physicalSide) {
    final account = client.userID;
    if (kIsWeb || account == null) return;
    final side = bucketFor(physicalSide);
    for (final uri in uris) {
      if (!_prefetched.add('$account\n$uri\n$side')) continue;
      _queue.add((client, uri, side));
    }
    _pump();
  }

  static void _pump() {
    while (_running < _parallel && _queue.isNotEmpty) {
      final (client, uri, side) = _queue.removeAt(0);
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
            .then<void>((_) {})
            .catchError((Object _) {
              _prefetched.remove('${client.userID}\n$uri\n$side');
            })
            .whenComplete(() {
              _running--;
              _pump();
            }),
      );
    }
  }
}

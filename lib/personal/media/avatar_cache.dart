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

  static bool _retriable(MatrixException e) {
    final status = e.response?.statusCode ?? 0;
    return e.error == MatrixError.M_LIMIT_EXCEEDED || status >= 500;
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
        if (_retriable(e)) rethrow;
        return client.downloadMxcCached(uri, databaseCache: false);
      }
    }

    final cache = await shared();
    final account = client.userID;
    if (cache == null || account == null) return download();
    return cache.fetch(
      StickerMediaCache.keyFor(account, uri, 'avatar:$side'),
      download,
    );
  }
}

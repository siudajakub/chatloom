// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:chatloom/personal/media/media_prefetcher.dart'
    show ClientMediaPrefetchPorts;
import 'package:chatloom/utils/client_download_content_extension.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/flutter_matrix_dart_sdk_database/cipher.dart';
import 'package:chatloom/utils/power_saving.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webcrypto/webcrypto.dart';

import '../media/private_directories_stub.dart'
    if (dart.library.ffi) '../media/private_directories_native.dart'
    as native;
import 'sticker_models.dart';

/// Long-lived disk cache of sticker panel media (stickers, pack icons, GIF
/// posters): the panel opens with its stickers at once instead of asking
/// the server again (Telegram keeps stickers for good too).
///
/// The SQLCipher media cache (`EncryptedMediaCache`) was the only store
/// before: 128 MB shared with every photo and avatar (stickers were pushed
/// out by ordinary media) and every read queued behind sync statements.
///
/// At-rest posture (J, 2026-10-24): pack media is mostly unencrypted mxc,
/// so every file is sealed here with AES-256-GCM (a random nonce per file,
/// its name as associated data) under a key in protected storage
/// ([keyStorageName]); nothing readable reaches the disk. The GCM tag is the
/// integrity check: a tampered, truncated or foreign file (another key, a
/// renamed file) is a miss and is deleted.
///
/// Layout: a private (0700, no symlink) folder of the app support directory
/// (not the purgeable cache directory), one file per account, mxc and
/// variant named by a SHA-256 of them (no server, media id or account on
/// disk). The file time is the last use (updated at most hourly); past
/// [maxBytes] the least recently used files go, files unused for
/// [retention] too. Cleared on logout and with "clear cache"
/// (`clearPrivateFileCaches`). Any problem (no key, folder not private, web)
/// turns the cache off: media then loads from the network as before, never
/// in plaintext.
class StickerMediaCache {
  static const int defaultMaxBytes = 256 * 1024 * 1024;
  static const Duration defaultRetention = Duration(days: 365);
  static const String folderName = 'chatloom_sticker_cache';
  static const String keyStorageName = 'sticker_cache_key_v1';

  /// Larger files (a big GIF original) are not kept.
  static const int maxEntryBytes = 8 * 1024 * 1024;

  /// Stickers whose announced size is above this load the server thumbnail
  /// in grids (Matrix stickers are ≤ 512 px; this catches odd uploads).
  static const int maxOriginalBytes = 1024 * 1024;

  /// The last-use time is written at most this often per file.
  static const Duration touchInterval = Duration(hours: 1);

  static final _magic = ascii.encode('CLS1');
  static const _nonceLength = 12;
  static final _entryName = RegExp(r'^[0-9a-f]{64}\.enc$');
  static final _partialName = RegExp(r'^\.partial_[A-Za-z0-9_-]{16}$');

  final Directory directory;
  final int maxBytes;
  final Duration retention;
  final AesGcmSecretKey _key;
  final DateTime Function() _now;
  final _inflight = <String, Future<Uint8List>>{};

  /// Bytes on disk as of the last scan plus later writes (an estimate: an
  /// overwrite counts twice until the next eviction recounts).
  int _total = 0;

  StickerMediaCache._(
    this.directory,
    this.maxBytes,
    this.retention,
    this._key,
    this._now,
  );

  /// Opens (creating owner-only) [directory] with the 32-byte [key]. Throws
  /// when the folder is not a private real directory or the key is not
  /// usable; callers then skip the cache.
  static Future<StickerMediaCache> open(
    Directory directory, {
    required List<int> key,
    int maxBytes = defaultMaxBytes,
    Duration retention = defaultRetention,
    DateTime Function()? now,
  }) async {
    if (key.length != 32) throw ArgumentError.value('<key>', 'key');
    await directory.parent.create(recursive: true);
    // Resolve system aliases of the parent once (Android `/data/user/0`),
    // but never follow the cache folder itself.
    final parent = await directory.parent.resolveSymbolicLinks();
    final name = directory.absolute.uri.pathSegments
        .where((part) => part.isNotEmpty)
        .last;
    final root = Directory('$parent/$name');
    if (await FileSystemEntity.type(root.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      native.PrivateDirectories.create(root);
    }
    final cache = StickerMediaCache._(
      root,
      maxBytes,
      retention,
      await AesGcmSecretKey.importRawKey(key),
      now ?? DateTime.now,
    );
    await cache._validate();
    // Drops expired files and counts the rest.
    await cache.evict();
    return cache;
  }

  static Future<StickerMediaCache?>? _shared;

  /// The app-wide cache, or null (web, no protected storage key, folder not
  /// private): then nothing is cached here.
  static Future<StickerMediaCache?> shared() => _shared ??= openShared(
    base: getApplicationSupportDirectory,
    key: () => getProtectedStorageCipher(keyStorageName),
  );

  /// Opens the cache in `<base>/[folderName]` with the base64url [key];
  /// null on any failure.
  @visibleForTesting
  static Future<StickerMediaCache?> openShared({
    required Future<Directory> Function() base,
    required Future<String> Function() key,
    DateTime Function()? now,
  }) async {
    if (kIsWeb) return null;
    try {
      // A lost key only orphans ciphertext: those files fail their tag
      // and go on first read or with the LRU.
      final raw = base64Url.decode(await key());
      final folder = Directory('${(await base()).path}/$folderName');
      return await open(folder, key: raw, now: now);
    } catch (error) {
      Logs().w('sticker_cache_unavailable', error.runtimeType.toString());
      return null;
    }
  }

  /// Uses [cache] as the app-wide cache (null: off).
  @visibleForTesting
  static void debugSetShared(StickerMediaCache? cache) =>
      _shared = Future.value(cache);

  @visibleForTesting
  static void debugResetShared() => _shared = null;

  /// Logout / "clear cache": removes the sticker media of every account.
  /// Needs no key: a cache that was never opened is cleared by its folder.
  static Future<void> clearShared() async {
    if (kIsWeb) return;
    try {
      final cache = await _shared;
      if (cache != null) return await cache.clear();
      final base = await getApplicationSupportDirectory();
      final folder = Directory('${base.path}/$folderName');
      if (await FileSystemEntity.type(folder.path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return;
      }
      await _clearFolder(folder);
    } catch (error) {
      Logs().w('sticker_cache_clear_failed', error.runtimeType.toString());
    }
  }

  /// File name for [variant] of [mxc] of [account]: a hash, so neither the
  /// server, the media id nor the account appears on disk.
  static String keyFor(String account, Uri mxc, String variant) => sha256
      .convert(
        utf8.encode('chatloom-sticker-cache-v1\n$account\n$mxc\n$variant'),
      )
      .toString();

  /// Variant of the full file.
  static const original = 'original';

  /// Variant of a server thumbnail of that request.
  static String thumbnailVariant({
    num? width,
    num? height,
    required ThumbnailMethod method,
    required bool animated,
  }) =>
      'thumbnail:${width?.round()}x${height?.round()}:${method.name}:$animated';

  File _entry(String key) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(key)) {
      throw ArgumentError.value(key, 'key');
    }
    return File('${directory.path}/$key.enc');
  }

  /// Whether [key] has a fresh file (not decrypted; prefetch uses it to skip).
  Future<bool> contains(String key) async {
    try {
      final stat = await FileStat.stat(_entry(key).path);
      return stat.type == FileSystemEntityType.file &&
          _now().difference(stat.modified) <= retention;
    } catch (_) {
      return false;
    }
  }

  /// The bytes of [key], or null (missing, expired, tampered, other key).
  /// A hit marks the file recently used. Never throws.
  Future<Uint8List?> read(String key) async {
    try {
      await _validate();
      final file = _entry(key);
      final stat = await FileStat.stat(file.path);
      if (stat.type != FileSystemEntityType.file) return null;
      final now = _now();
      if (now.difference(stat.modified) > retention) {
        await _delete(file);
        return null;
      }
      final sealed = await file.readAsBytes();
      final plain = await _open(key, sealed);
      if (plain == null) {
        await _delete(file);
        return null;
      }
      // The file time is the LRU order.
      if (now.difference(stat.modified) > touchInterval) {
        await file.setLastModified(now);
      }
      return plain;
    } catch (_) {
      return null;
    }
  }

  /// Seals and stores [bytes] for [key] (atomically: a partial file is
  /// renamed once complete), then trims the cache to [maxBytes] when it is
  /// over. Empty or too large ([maxEntryBytes]) bytes are not kept. Never
  /// throws.
  Future<bool> write(String key, Uint8List bytes) async {
    if (bytes.isEmpty ||
        bytes.lengthInBytes > maxEntryBytes ||
        bytes.lengthInBytes > maxBytes) {
      return false;
    }
    File? partial;
    try {
      await _validate();
      final target = _entry(key);
      final sealed = await _seal(key, bytes);
      final random = Random.secure();
      final suffix = base64UrlEncode(
        List<int>.generate(12, (_) => random.nextInt(256)),
      );
      partial = File('${directory.path}/.partial_$suffix');
      await partial.writeAsBytes(sealed);
      await partial.rename(target.path);
      await target.setLastModified(_now());
      _total += sealed.length;
    } catch (_) {
      if (partial != null) await _delete(partial);
      return false;
    }
    if (_total > maxBytes) {
      try {
        await evict(keep: key);
      } catch (_) {
        // The next write tries again.
      }
    }
    return true;
  }

  /// The bytes of [key] from disk, or from [download] (then stored). One
  /// download per key at a time: concurrent callers (two cells of the same
  /// sticker, the prefetch) share it. A failed download is not cached.
  Future<Uint8List> fetch(String key, Future<Uint8List> Function() download) {
    final pending = _inflight[key];
    if (pending != null) return pending;
    final result = Completer<Uint8List>();
    _inflight[key] = result.future;
    () async {
      try {
        final cached = await read(key);
        if (cached != null) {
          result.complete(cached);
          return;
        }
        final bytes = await download();
        // Callers draw now; the write finishes under the same flight, so a
        // second request meanwhile does not download again.
        result.complete(bytes);
        await write(key, bytes);
      } catch (error, stackTrace) {
        if (!result.isCompleted) result.completeError(error, stackTrace);
      } finally {
        if (identical(_inflight[key], result.future)) _inflight.remove(key);
      }
    }();
    return result.future;
  }

  Future<void> remove(String key) => _delete(_entry(key));

  /// Deletes expired files, then the least recently used ones until the
  /// cache fits [maxBytes]. [keep] (the file just stored) always stays.
  /// Returns the bytes left.
  Future<int> evict({String? keep}) async {
    await _validate();
    final now = _now();
    final entries = <(File, int, DateTime)>[];
    await for (final item in directory.list(followLinks: false)) {
      final name = item.uri.pathSegments.last;
      if (item is! File) continue;
      final stat = await item.stat();
      if (_partialName.hasMatch(name)) {
        // Left by a crash mid-write: gone after an hour.
        if (now.difference(stat.modified) > const Duration(hours: 1)) {
          await _delete(item);
        }
        continue;
      }
      if (!_entryName.hasMatch(name)) continue;
      if (now.difference(stat.modified) > retention) {
        await _delete(item);
        continue;
      }
      entries.add((item, stat.size, stat.modified));
    }
    // Most recently used first.
    entries.sort((a, b) => b.$3.compareTo(a.$3));
    final keepName = keep == null ? null : '$keep.enc';
    var total = 0;
    for (final (file, size, _) in entries) {
      if (file.uri.pathSegments.last == keepName) total += size;
    }
    for (final (file, size, _) in entries) {
      if (file.uri.pathSegments.last == keepName) continue;
      if (total + size <= maxBytes) {
        total += size;
      } else {
        await _delete(file);
      }
    }
    return _total = total;
  }

  /// Removes every cached file (only this cache's own names).
  Future<void> clear() async {
    await _clearFolder(directory);
    _total = 0;
  }

  static Future<void> _clearFolder(Directory directory) async {
    await _validateFolder(directory);
    await for (final item in directory.list(followLinks: false)) {
      final name = item.uri.pathSegments.last;
      if (item is File &&
          (_entryName.hasMatch(name) || _partialName.hasMatch(name))) {
        await _delete(item);
      }
    }
  }

  /// `magic | nonce | ciphertext+tag`, the file name as associated data.
  Future<Uint8List> _seal(String key, Uint8List bytes) async {
    final random = Random.secure();
    final nonce = Uint8List.fromList(
      List<int>.generate(_nonceLength, (_) => random.nextInt(256)),
    );
    final sealed = await _key.encryptBytes(
      bytes,
      nonce,
      additionalData: utf8.encode(key),
    );
    return (BytesBuilder(copy: false)
          ..add(_magic)
          ..add(nonce)
          ..add(sealed))
        .takeBytes();
  }

  Future<Uint8List?> _open(String key, Uint8List sealed) async {
    final header = _magic.length + _nonceLength;
    if (sealed.length <= header + 16) return null;
    for (var i = 0; i < _magic.length; i++) {
      if (sealed[i] != _magic[i]) return null;
    }
    try {
      return await _key.decryptBytes(
        Uint8List.sublistView(sealed, header),
        Uint8List.sublistView(sealed, _magic.length, header),
        additionalData: utf8.encode(key),
      );
    } catch (_) {
      // Wrong key, tampered or truncated: the tag does not verify.
      return null;
    }
  }

  Future<void> _validate() => _validateFolder(directory);

  static Future<void> _validateFolder(Directory directory) async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await directory.resolveSymbolicLinks() != directory.path) {
      throw const FileSystemException('sticker cache folder');
    }
    final mode = (await directory.stat()).mode;
    // Owner rwx, nothing for group and others.
    if (mode & 0x1c0 != 0x1c0 || mode & 0x3f != 0) {
      throw const FileSystemException('sticker cache folder');
    }
  }

  static Future<void> _delete(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Already gone, or retried by the next eviction.
    }
  }

  // -----------------------------------------------------------------------
  // Loaders for `MxcImage.loadBytes`.

  /// Whether a grid shows [item] from its original file rather than a
  /// server thumbnail: an unencrypted, non-video sticker of a sane size.
  /// Matrix stickers are ≤ 512 px and many bridged ones (WebP, TGS) have no
  /// thumbnail, so asking for one first costs a failed round trip; the
  /// original also stays the same file whatever the cell size.
  static bool prefersOriginal(StickerItem item) {
    final size = item.size;
    return item.kind == StickerKind.sticker &&
        !item.isVideo &&
        item.uri != null &&
        (size == null || size <= maxOriginalBytes);
  }

  /// [MxcBytesLoader] through the shared cache: the request as asked (a
  /// server thumbnail, or the original), a missing thumbnail falling back
  /// to the original (stored under both). Without the cache, the default
  /// download path.
  static Future<Uint8List> loadMxc(
    Client client,
    Uri uri, {
    num? width,
    num? height,
    required bool isThumbnail,
    required bool animated,
    required ThumbnailMethod thumbnailMethod,
  }) async {
    final cache = await shared();
    final account = client.userID;
    if (cache == null || account == null) {
      if (!isThumbnail) return client.downloadMxcCached(uri);
      try {
        return await client.downloadMxcCached(
          uri,
          width: width,
          height: height,
          thumbnailMethod: thumbnailMethod,
          isThumbnail: true,
          animated: animated,
        );
      } on MatrixException catch (e) {
        if (_retriable(e)) rethrow;
        return client.downloadMxcCached(uri);
      }
    }
    Future<Uint8List> original() => cache.fetch(
      keyFor(account, uri, StickerMediaCache.original),
      () => client.downloadMxcCached(uri, databaseCache: false),
    );
    if (!isThumbnail) return original();
    final variant = thumbnailVariant(
      width: width,
      height: height,
      method: thumbnailMethod,
      animated: animated,
    );
    return cache.fetch(keyFor(account, uri, variant), () async {
      try {
        return await client.downloadMxcCached(
          uri,
          width: width,
          height: height,
          thumbnailMethod: thumbnailMethod,
          isThumbnail: true,
          animated: animated,
          databaseCache: false,
        );
      } on MatrixException catch (e) {
        if (_retriable(e)) rethrow;
        // Some bridge and remote media has no thumbnail (404/unrecognized):
        // the original, kept under this request too, so the next opening
        // does not ask for the thumbnail again.
        return original();
      }
    });
  }

  /// [MxcBytesLoader] that always loads the original (sticker cells; the
  /// image decodes it at the cell size).
  static Future<Uint8List> loadOriginal(
    Client client,
    Uri uri, {
    num? width,
    num? height,
    required bool isThumbnail,
    required bool animated,
    required ThumbnailMethod thumbnailMethod,
  }) => loadMxc(
    client,
    uri,
    isThumbnail: false,
    animated: false,
    thumbnailMethod: thumbnailMethod,
  );

  /// Rate limits and server errors are worth another try (as in MxcImage).
  static bool _retriable(MatrixException e) {
    final status = e.response?.statusCode ?? 0;
    return e.error == MatrixError.M_LIMIT_EXCEEDED || status >= 500;
  }

  @override
  String toString() => 'StickerMediaCache(private)';
}

/// Warms [StickerMediaCache] with the originals of stickers the panel is
/// about to show (recents, the first rows of each pack), so scrolling finds
/// them on disk. At most [concurrency] downloads at a time; files already
/// cached are skipped without decrypting; every failure is ignored (the
/// cell loads it again). Stops at [cancel] (the panel closed), when the app
/// leaves the foreground or locks, on battery saver, or with the Wi-Fi-only
/// download setting off Wi-Fi (the voice/round prefetch policy).
class StickerPrefetch {
  StickerPrefetch(
    this.client, {
    this.concurrency = 4,
    @visibleForTesting Future<bool> Function()? allowed,
  }) : _allowed = allowed ?? _defaultAllowed(client);

  final Client client;
  final int concurrency;
  final Future<bool> Function() _allowed;
  bool _cancelled = false;

  /// Upper bound of one run.
  static const maxItems = 240;

  bool get cancelled => _cancelled;

  void cancel() => _cancelled = true;

  static Future<bool> Function() _defaultAllowed(Client client) {
    final ports = ClientMediaPrefetchPorts(client);
    return () async =>
        !PowerSaving.active.value &&
        ports.surfaceActive &&
        await ports.networkAllowed();
  }

  /// Downloads the originals of [items] that qualify
  /// ([StickerMediaCache.prefersOriginal]) and are not cached yet, in
  /// order. Completes when done or cancelled.
  Future<void> run(Iterable<StickerItem> items) async {
    final cache = await StickerMediaCache.shared();
    final account = client.userID;
    if (cache == null || account == null || _cancelled) return;
    if (!await _allowed()) return;
    final seen = <String>{};
    final queue = <Uri>[
      for (final item in items)
        if (StickerMediaCache.prefersOriginal(item) && seen.add(item.key))
          item.uri!,
    ].take(maxItems).iterator;
    Future<void> worker() async {
      while (!_cancelled && queue.moveNext()) {
        final uri = queue.current;
        final key = StickerMediaCache.keyFor(
          account,
          uri,
          StickerMediaCache.original,
        );
        if (await cache.contains(key)) continue;
        if (_cancelled || !await _allowed()) {
          _cancelled = true;
          return;
        }
        try {
          await cache.fetch(
            key,
            () => client.downloadMxcCached(uri, databaseCache: false),
          );
        } catch (_) {
          // The cell retries on its own when it is built.
        }
      }
    }

    await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
  }
}

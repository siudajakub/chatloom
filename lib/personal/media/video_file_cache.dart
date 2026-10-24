// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:personal_core/personal_core.dart';

import 'private_directories_stub.dart'
    if (dart.library.ffi) 'private_directories_native.dart'
    as native;

/// Disk cache of large E2EE videos (MD-11): reopening a video over 10 MB
/// does not download it again (Telegram keeps a media cache too).
///
/// At-rest posture (J, 2026-10-24): the cache holds **only the downloaded
/// ciphertext** of encrypted attachments, never decrypted bytes. The key,
/// IV and hash stay in the event inside the SQLCipher database, and the SDK
/// checks the SHA-256 on every read before it decrypts, so a cached file is
/// worthless without the account's database and a tampered one is rejected.
/// Unencrypted-room media would be plaintext on disk and is not cached.
/// Smaller files stay in the SQLCipher media cache
/// (`EncryptedMediaCache`, up to [minBytes] each).
///
/// Layout: one file per attachment in a private (0700, no symlink) folder of
/// the app's cache directory, named by a SHA-256 of the account and the mxc
/// URI (no server name, media id, room or file name on disk). The file time
/// is the last access; past [maxBytes] the least recently used files go,
/// files older than [retention] too. Cleared on logout and with the SDK's
/// "clear cache" (`ProtectedMatrixDatabase`). Any storage problem disables
/// the cache for the call (the video is then downloaded as before); it never
/// deletes anything outside its own folder.
class VideoFileCache {
  /// Attachments up to this size live in the SQLCipher media cache.
  static const int minBytes = 10 * 1000 * 1000;
  static const int defaultMaxBytes = 512 * 1024 * 1024;
  static const Duration defaultRetention = Duration(days: 30);
  static const String folderName = 'chatloom_video_cache';

  static final _entryName = RegExp(r'^[0-9a-f]{64}\.enc$');
  static final _partialName = RegExp(r'^\.partial_[A-Za-z0-9_-]{16}$');

  final Directory directory;
  final int maxBytes;
  final Duration retention;
  final DateTime Function() _now;

  VideoFileCache._(this.directory, this.maxBytes, this.retention, this._now);

  /// Opens (creating owner-only) [directory]. Throws when it is not a
  /// private real directory; callers then skip the cache.
  static Future<VideoFileCache> open(
    Directory directory, {
    int maxBytes = defaultMaxBytes,
    Duration retention = defaultRetention,
    DateTime Function()? now,
  }) async {
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
    final cache = VideoFileCache._(
      root,
      maxBytes,
      retention,
      now ?? DateTime.now,
    );
    await cache._validate();
    return cache;
  }

  static Future<VideoFileCache?>? _shared;

  /// The app-wide cache under the app cache directory, or null (web, or the
  /// folder is not private): then nothing is cached.
  static Future<VideoFileCache?> shared() => _shared ??= _openShared();

  static Future<VideoFileCache?> _openShared() async {
    if (kIsWeb) return null;
    try {
      final base = await getApplicationCacheDirectory();
      return await open(Directory('${base.path}/$folderName'));
    } catch (error) {
      Logs().w('video_cache_unavailable', error.runtimeType.toString());
      return null;
    }
  }

  /// Logout / "clear cache": removes every cached video of every account.
  static Future<void> clearShared() async {
    try {
      await (await shared())?.clear();
    } catch (error) {
      Logs().w('video_cache_clear_failed', error.runtimeType.toString());
    }
  }

  /// Whether [event]'s attachment may use this cache: a playable, storable
  /// (not protected, not disappearing) **encrypted** video whose announced
  /// size is over [minBytes] (or unknown: the stored length decides).
  static bool appliesTo(Event event) {
    if (kIsWeb || event.redacted || !event.isAttachmentEncrypted) {
      return false;
    }
    final video =
        event.messageType == MessageTypes.Video ||
        (event.attachmentMimetype.toLowerCase().startsWith('video/'));
    if (!video) return false;
    if (!RoundMediaPolicy.fromContent(event.content).canPersist) return false;
    final size = event.infoMap.tryGet<int>('size');
    return size == null || size > minBytes;
  }

  /// File name for [mxc] of [account]: a hash, so neither the server, the
  /// media id nor the account appears on disk.
  static String keyFor(String account, Uri mxc) => sha256
      .convert(utf8.encode('chatloom-video-cache-v1\n$account\n$mxc'))
      .toString();

  File _entry(String key) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(key)) {
      throw ArgumentError.value(key, 'key');
    }
    return File('${directory.path}/$key.enc');
  }

  /// The cached ciphertext of [key], or null. A hit marks it recently used.
  Future<Uint8List?> read(String key) async {
    await _validate();
    final file = _entry(key);
    final FileStat stat;
    try {
      stat = await FileStat.stat(file.path);
    } on FileSystemException {
      return null;
    }
    if (stat.type != FileSystemEntityType.file) return null;
    final now = _now();
    if (now.difference(stat.modified) > retention) {
      await _delete(file);
      return null;
    }
    try {
      final bytes = await file.readAsBytes();
      // The file time is the LRU order.
      await file.setLastModified(now);
      return bytes;
    } on FileSystemException {
      return null;
    }
  }

  /// Stores [ciphertext] for [key] (atomically: a partial file is renamed
  /// once complete), then trims the cache to [maxBytes]. Bytes that are not
  /// over [minBytes] or larger than the whole cache are not stored.
  Future<bool> write(String key, Uint8List ciphertext) async {
    if (ciphertext.lengthInBytes <= minBytes ||
        ciphertext.lengthInBytes > maxBytes) {
      return false;
    }
    await _validate();
    final target = _entry(key);
    final random = Random.secure();
    final suffix = base64UrlEncode(
      List<int>.generate(12, (_) => random.nextInt(256)),
    );
    final partial = File('${directory.path}/.partial_$suffix');
    try {
      await partial.writeAsBytes(ciphertext, flush: true);
      await partial.rename(target.path);
      await target.setLastModified(_now());
    } catch (_) {
      await _delete(partial);
      return false;
    }
    await evict(keep: key);
    return true;
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
        // Left by a crash or another isolate mid-write: gone after an hour.
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
    return total;
  }

  /// Removes every cached file (only this cache's own names).
  Future<void> clear() async {
    await _validate();
    await for (final item in directory.list(followLinks: false)) {
      final name = item.uri.pathSegments.last;
      if (item is File &&
          (_entryName.hasMatch(name) || _partialName.hasMatch(name))) {
        await _delete(item);
      }
    }
  }

  Future<void> _validate() async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await directory.resolveSymbolicLinks() != directory.path) {
      throw const FileSystemException('video cache folder');
    }
    final mode = (await directory.stat()).mode;
    // Owner rwx, nothing for group and others.
    if (mode & 0x1c0 != 0x1c0 || mode & 0x3f != 0) {
      throw const FileSystemException('video cache folder');
    }
  }

  static Future<void> _delete(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Already gone, or retried by the next eviction.
    }
  }

  @override
  String toString() => 'VideoFileCache(private)';
}

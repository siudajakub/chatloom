// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../storage/database_policy.dart';

/// Bounded BLOB cache. Production must pass an authenticated SQLCipher DB.
///
/// The table shares the Matrix database, whose statements run one at a time:
/// every statement here delays sync processing, timeline and avatar reads.
/// `saved_at` and `accessed_at` are stored after the BLOB, so reading them
/// for every row walks each file's overflow pages (decrypting them). Such
/// work therefore runs only when it can change something (2026-10-21):
///
/// * expiry ([deleteOldFiles], which the SDK calls after every sync) uses an
///   index and runs at most once per [pruneInterval];
/// * reads refresh `accessed_at` (a write transaction) only when it is older
///   than [touchInterval];
/// * a store scans for eviction only when the cached bytes may exceed
///   [maxCacheBytes], and then trims to [evictToBytes], so a full cache does
///   not scan again on the next store.
class EncryptedMediaCache {
  final Database _cacheDatabase;
  final int maxFileSize;
  final int maxCacheBytes;
  final Duration retention;
  final Duration pruneInterval;
  final Duration touchInterval;
  final DateTime Function() _now;

  /// Size the cache is trimmed to once it exceeds [maxCacheBytes].
  int get evictToBytes => maxCacheBytes - maxCacheBytes ~/ 10;

  /// An upper bound of the cached bytes (null until the first store of this
  /// instance computed it). Deletions only lower the real size, so the bound
  /// stays safe until the next eviction scan recomputes it. Another instance
  /// on the same file (a short-lived notification isolate) is corrected by
  /// that scan.
  int? _cachedBytesBound;
  DateTime? _lastPrune;

  /// Statement counters for performance tests. No Flutter import here: the
  /// pure-Dart storage harness (`scripts/verify-personal.py`) compiles this
  /// file, so `@visibleForTesting` is not available.
  int debugEvictionScans = 0, debugTouches = 0, debugPrunes = 0;

  /// Key prefix of the SDK's copies of unsent files (`cache://file/<txid>`,
  /// `cache://thumbnail/<txid>`), kept out of the least-recently-used
  /// eviction. They still expire after [retention].
  static const outgoingPrefix = 'cache://';

  EncryptedMediaCache(
    this._cacheDatabase, {
    this.maxFileSize = 10 * 1000 * 1000,
    this.maxCacheBytes = 128 * 1024 * 1024,
    this.retention = const Duration(days: 30),
    this.pruneInterval = const Duration(hours: 1),
    this.touchInterval = const Duration(hours: 12),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  Future<void> initialize() => preserveOnStorageFailure(() async {
    await _cacheDatabase.execute(
      'CREATE TABLE IF NOT EXISTS personal_media_cache '
      '(media_key TEXT PRIMARY KEY NOT NULL, bytes BLOB NOT NULL, '
      'saved_at INTEGER NOT NULL, accessed_at INTEGER NOT NULL)',
    );
    // Lets expiry find old rows without reading every BLOB's overflow pages.
    // Built once (one scan) on the first start of this version.
    await _cacheDatabase.execute(
      'CREATE INDEX IF NOT EXISTS personal_media_cache_saved_at '
      'ON personal_media_cache (saved_at)',
    );
    await _prune();
  });

  Future<void> clear() => preserveOnStorageFailure(() async {
    await _cacheDatabase.delete('personal_media_cache');
    _cachedBytesBound = 0;
  });

  Future<void> storeFile(Uri mxcUri, Uint8List bytes, int time) =>
      preserveOnStorageFailure(() async {
        if (bytes.length > maxFileSize || bytes.length > maxCacheBytes) return;
        final now = _now().millisecondsSinceEpoch;
        final key = mxcUri.toString();
        await _cacheDatabase.transaction((tx) async {
          await tx.insert('personal_media_cache', {
            'media_key': key,
            'bytes': bytes,
            'saved_at': now,
            'accessed_at': now,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          final bound = _cachedBytesBound;
          // A replaced row's old size is still counted: an overestimate only
          // brings the next scan forward.
          if (bound != null && bound + bytes.length <= maxCacheBytes) {
            _cachedBytesBound = bound + bytes.length;
            return;
          }
          debugEvictionScans++;
          // length() of a BLOB comes from the record header; accessed_at
          // (stored after the BLOB) is what makes this a full read.
          final sizes = await tx.rawQuery(
            'SELECT media_key, length(bytes) AS size FROM personal_media_cache '
            'ORDER BY accessed_at DESC, media_key ASC',
          );
          var total = 0;
          for (final row in sizes) {
            total += row['size']! as int;
          }
          if (total <= maxCacheBytes) {
            _cachedBytesBound = total;
            return;
          }
          // This device's copies of unsent files ([outgoingPrefix]) are
          // never evicted: they are the only source for Retry, and the send
          // (or a Delete) removes them.
          var retained = 0;
          for (final row in sizes) {
            if ((row['media_key']! as String).startsWith(outgoingPrefix)) {
              retained += row['size']! as int;
            }
          }
          for (final row in sizes) {
            final size = row['size']! as int;
            final rowKey = row['media_key']! as String;
            if (rowKey.startsWith(outgoingPrefix)) continue;
            // The file just stored is never evicted to make room for itself.
            if (rowKey == key || retained + size <= evictToBytes) {
              retained += size;
              continue;
            }
            await tx.delete(
              'personal_media_cache',
              where: 'media_key = ?',
              whereArgs: [rowKey],
            );
          }
          _cachedBytesBound = retained;
        });
      });

  Future<Uint8List?> getFile(Uri mxcUri) => preserveOnStorageFailure(() async {
    final now = _now();
    final rows = await _cacheDatabase.query(
      'personal_media_cache',
      columns: ['bytes', 'accessed_at'],
      where: 'media_key = ? AND saved_at > ?',
      whereArgs: [
        mxcUri.toString(),
        now.subtract(retention).millisecondsSinceEpoch,
      ],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    final accessedAt = row['accessed_at'];
    // Least-recently-used order needs hours, not milliseconds: re-reading a
    // hot avatar or thumbnail must not cost a write transaction each time.
    if (accessedAt is! int ||
        now.millisecondsSinceEpoch - accessedAt >=
            touchInterval.inMilliseconds) {
      debugTouches++;
      await _cacheDatabase.update(
        'personal_media_cache',
        {'accessed_at': now.millisecondsSinceEpoch},
        where: 'media_key = ?',
        whereArgs: [mxcUri.toString()],
      );
    }
    return row['bytes']! as Uint8List;
  });

  /// Presence probe for prefetch: no BLOB read and no access-time write.
  /// Uses the same retention window as [getFile], so a hit is playable.
  Future<bool> hasFile(Uri mxcUri) => preserveOnStorageFailure(() async {
    final rows = await _cacheDatabase.rawQuery(
      'SELECT 1 FROM personal_media_cache '
      'WHERE media_key = ? AND saved_at > ? LIMIT 1',
      [mxcUri.toString(), _now().subtract(retention).millisecondsSinceEpoch],
    );
    return rows.isNotEmpty;
  });

  Future<bool> deleteFile(Uri mxcUri) => preserveOnStorageFailure(() async {
    return await _cacheDatabase.delete(
          'personal_media_cache',
          where: 'media_key = ?',
          whereArgs: [mxcUri.toString()],
        ) >
        0;
  });

  /// Removes files older than [retention]. The SDK calls this after every
  /// sync; it runs at most once per [pruneInterval]. Expired files are never
  /// returned in between: [getFile] and [hasFile] check the age themselves.
  Future<void> deleteOldFiles(int savedAt) =>
      preserveOnStorageFailure(() async {
        final last = _lastPrune;
        final now = _now();
        if (last != null &&
            !now.isBefore(last) &&
            now.difference(last) < pruneInterval) {
          return;
        }
        await _prune();
      });

  Future<void> _prune() async {
    final now = _now();
    debugPrunes++;
    await _cacheDatabase.delete(
      'personal_media_cache',
      where: 'saved_at <= ?',
      whereArgs: [now.subtract(retention).millisecondsSinceEpoch],
    );
    _lastPrune = now;
  }
}

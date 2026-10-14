// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../storage/database_policy.dart';

/// Bounded BLOB cache. Production must pass an authenticated SQLCipher DB.
class EncryptedMediaCache {
  final Database _cacheDatabase;
  final int maxFileSize;
  final int maxCacheBytes;
  final Duration retention;
  final DateTime Function() _now;

  EncryptedMediaCache(
    this._cacheDatabase, {
    this.maxFileSize = 10 * 1000 * 1000,
    this.maxCacheBytes = 128 * 1024 * 1024,
    this.retention = const Duration(days: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  Future<void> initialize() => preserveOnStorageFailure(() async {
    await _cacheDatabase.execute(
      'CREATE TABLE IF NOT EXISTS personal_media_cache '
      '(media_key TEXT PRIMARY KEY NOT NULL, bytes BLOB NOT NULL, '
      'saved_at INTEGER NOT NULL, accessed_at INTEGER NOT NULL)',
    );
    await deleteOldFiles(_now().millisecondsSinceEpoch);
  });

  Future<void> clear() => preserveOnStorageFailure(() async {
    await _cacheDatabase.delete('personal_media_cache');
  });

  Future<void> storeFile(Uri mxcUri, Uint8List bytes, int time) =>
      preserveOnStorageFailure(() async {
        if (bytes.length > maxFileSize || bytes.length > maxCacheBytes) return;
        final now = _now().millisecondsSinceEpoch;
        await _cacheDatabase.transaction((tx) async {
          await tx.insert('personal_media_cache', {
            'media_key': mxcUri.toString(),
            'bytes': bytes,
            'saved_at': now,
            'accessed_at': now,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          final sizes = await tx.rawQuery(
            'SELECT media_key, length(bytes) AS size FROM personal_media_cache '
            'ORDER BY accessed_at DESC, media_key ASC',
          );
          var retained = 0;
          for (final row in sizes) {
            retained += row['size']! as int;
            if (retained > maxCacheBytes) {
              await tx.delete(
                'personal_media_cache',
                where: 'media_key = ?',
                whereArgs: [row['media_key']],
              );
            }
          }
        });
      });

  Future<Uint8List?> getFile(Uri mxcUri) => preserveOnStorageFailure(() async {
    final rows = await _cacheDatabase.query(
      'personal_media_cache',
      columns: ['bytes'],
      where: 'media_key = ? AND saved_at > ?',
      whereArgs: [
        mxcUri.toString(),
        _now().subtract(retention).millisecondsSinceEpoch,
      ],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    await _cacheDatabase.update(
      'personal_media_cache',
      {'accessed_at': _now().millisecondsSinceEpoch},
      where: 'media_key = ?',
      whereArgs: [mxcUri.toString()],
    );
    return rows.single['bytes']! as Uint8List;
  });

  Future<bool> deleteFile(Uri mxcUri) => preserveOnStorageFailure(() async {
    return await _cacheDatabase.delete(
          'personal_media_cache',
          where: 'media_key = ?',
          whereArgs: [mxcUri.toString()],
        ) >
        0;
  });

  Future<void> deleteOldFiles(int savedAt) =>
      preserveOnStorageFailure(() async {
        await _cacheDatabase.delete(
          'personal_media_cache',
          where: 'saved_at <= ?',
          whereArgs: [_now().subtract(retention).millisecondsSinceEpoch],
        );
      });
}

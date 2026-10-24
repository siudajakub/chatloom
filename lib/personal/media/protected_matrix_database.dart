// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../storage/database_policy.dart';
import 'encrypted_media_cache.dart';

/// Keeps media inside the existing SQLCipher DB rather than plaintext files.
class ProtectedMatrixDatabase extends MatrixSdkDatabase {
  final EncryptedMediaCache _media;

  /// Clears media kept outside this database (the ciphertext video cache,
  /// opened-file copies) on logout and "clear cache". Its failure never
  /// blocks clearing the database.
  final Future<void> Function()? clearFileCaches;

  ProtectedMatrixDatabase(
    super.name, {
    required Database database,
    required DatabaseFactory factory,
    super.maxFileSize = 10 * 1000 * 1000,
    int maxCacheBytes = 128 * 1024 * 1024,
    Duration retention = const Duration(days: 30),
    this.clearFileCaches,
  }) : _media = EncryptedMediaCache(
         database,
         maxFileSize: maxFileSize,
         maxCacheBytes: maxCacheBytes,
         retention: retention,
       ),
       super.buildWithoutOpen(
         database: database,
         sqfliteFactory: factory,
         fileStorageLocation: null,
       );

  @override
  bool get supportsFileStoring => true;

  @override
  Future<void> open() => preserveOnStorageFailure(() async {
    await _media.initialize();
    await super.open();
  });

  @override
  Future<void> storeFile(Uri mxcUri, Uint8List bytes, int time) =>
      _media.storeFile(mxcUri, bytes, time);

  @override
  Future<Uint8List?> getFile(Uri mxcUri) => _media.getFile(mxcUri);

  /// Cheap presence check used by the media prefetcher (no BLOB read).
  Future<bool> hasFile(Uri mxcUri) => _media.hasFile(mxcUri);

  @override
  Future<bool> deleteFile(Uri mxcUri) => _media.deleteFile(mxcUri);

  @override
  Future<void> deleteOldFiles(int savedAt) => _media.deleteOldFiles(savedAt);

  @override
  Future<void> clearCache() => preserveOnStorageFailure(() async {
    await _clearFileCaches();
    await _media.clear();
    await super.clearCache();
  });

  @override
  Future<void> clear() => preserveOnStorageFailure(() async {
    await _clearFileCaches();
    await _media.clear();
    await super.clear();
  });

  Future<void> _clearFileCaches() async {
    try {
      await clearFileCaches?.call();
    } catch (_) {
      // Best effort: the files are ciphertext or short-lived copies.
    }
  }
}

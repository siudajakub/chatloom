// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../storage/database_policy.dart';
import '../storage/storage_failure.dart';

class PendingMediaFailure implements Exception {
  final String code;
  const PendingMediaFailure(this.code);
  @override
  String toString() => 'PendingMediaFailure($code)';
}

class PendingMediaRecord {
  final String actionId;
  final Map<String, dynamic> metadata;
  final Uint8List bytes;
  final Uint8List? thumbnailBytes, encryptedBytes, encryptedThumbnailBytes;
  PendingMediaRecord({
    required this.actionId,
    required Map<String, dynamic> metadata,
    required Uint8List bytes,
    Uint8List? thumbnailBytes,
    Uint8List? encryptedBytes,
    Uint8List? encryptedThumbnailBytes,
  }) : metadata = _copyJson(metadata),
       bytes = _copyBytes(bytes)!,
       thumbnailBytes = _copyBytes(thumbnailBytes),
       encryptedBytes = _copyBytes(encryptedBytes),
       encryptedThumbnailBytes = _copyBytes(encryptedThumbnailBytes);
  int get storedBytes =>
      bytes.length +
      (thumbnailBytes?.length ?? 0) +
      (encryptedBytes?.length ?? 0) +
      (encryptedThumbnailBytes?.length ?? 0);
  PendingMediaRecord withMetadata(Map<String, dynamic> value) =>
      PendingMediaRecord(
        actionId: actionId,
        metadata: value,
        bytes: bytes,
        thumbnailBytes: thumbnailBytes,
        encryptedBytes: encryptedBytes,
        encryptedThumbnailBytes: encryptedThumbnailBytes,
      );
  static Uint8List? _copyBytes(Uint8List? value) =>
      value == null ? null : Uint8List.fromList(value).asUnmodifiableView();
  static Map<String, dynamic> _copyJson(Map<String, dynamic> value) =>
      _freeze(jsonDecode(jsonEncode(value))) as Map<String, dynamic>;
  static Object? _freeze(Object? value) {
    if (value is Map)
      return Map<String, dynamic>.unmodifiable(
        value.map((k, v) => MapEntry(k as String, _freeze(v))),
      );
    if (value is List) return List<dynamic>.unmodifiable(value.map(_freeze));
    return value;
  }

  @override
  String toString() => 'PendingMediaRecord(redacted)';
}

/// Metadata projection intentionally has no raw/cipher BLOB fields.
class PendingMediaSummary {
  final String actionId;
  final Map<String, dynamic> metadata;
  final int storedBytes;
  PendingMediaSummary({
    required this.actionId,
    required Map<String, dynamic> metadata,
    required this.storedBytes,
  }) : metadata = PendingMediaRecord._copyJson(metadata);
  @override
  String toString() => 'PendingMediaSummary(redacted)';
}

abstract interface class PendingMediaSummaryRepository {
  Future<List<PendingMediaSummary>> listSummaries({
    required String accountId,
    required String deviceId,
  });
}

abstract interface class PendingMediaRepository {
  Future<void> stage(PendingMediaRecord record);
  Future<PendingMediaRecord?> get(String actionId);
  Future<void> put(PendingMediaRecord record);
  Future<List<PendingMediaRecord>> list({
    required String accountId,
    required String deviceId,
  });
  Future<void> remove(String actionId);
}

/// Durable staging, not a playback cache. No eviction, retention, or clearCache.
/// Each atomic row includes raw/encrypted BLOBs, hashes and its operation ledger.
class PendingMediaStore
    implements PendingMediaRepository, PendingMediaSummaryRepository {
  final Database _database;
  final int maxFileBytes, maxThumbnailBytes, maxStoreBytes;
  PendingMediaStore(
    this._database, {
    this.maxFileBytes = 64 * 1024 * 1024,
    this.maxThumbnailBytes = 2 * 1024 * 1024,
    this.maxStoreBytes = 512 * 1024 * 1024,
  });

  static Future<PendingMediaStore> open({
    required String path,
    required String cipher,
    DatabaseFactory? factory,
    int maxFileBytes = 64 * 1024 * 1024,
    int maxStoreBytes = 512 * 1024 * 1024,
  }) => preserveOnStorageFailure(() async {
    if (!RegExp(r'^[A-Za-z0-9_-]{43}=?$').hasMatch(cipher) ||
        base64Url.decode(cipher).length != 32) {
      throw const StorageFailure(StorageFailureCode.keyUnavailable);
    }
    await requireEncryptedDatabaseFile(path);
    final database = await (factory ?? createDatabaseFactoryFfi()).openDatabase(
      path,
      options: OpenDatabaseOptions(
        onConfigure: (db) async {
          if ((await db.rawQuery('PRAGMA cipher_version')).isEmpty) {
            throw const StorageFailure(
              StorageFailureCode.encryptionUnavailable,
            );
          }
          await db.execute("PRAGMA key = '$cipher'");
          await db.rawQuery('SELECT count(*) FROM sqlite_master');
          await db.execute('PRAGMA secure_delete = ON');
          await db.execute('PRAGMA temp_store = MEMORY');
        },
      ),
    );
    final store = PendingMediaStore(
      database,
      maxFileBytes: maxFileBytes,
      maxStoreBytes: maxStoreBytes,
    );
    try {
      await store.initialize();
    } catch (_) {
      await database.close();
      rethrow;
    }
    return store;
  });

  Future<void> initialize() => _protected(() async {
    if (maxFileBytes <= 0 || maxThumbnailBytes <= 0 || maxStoreBytes <= 0) {
      throw const PendingMediaFailure('invalidQuota');
    }
    if ((await _database.rawQuery('PRAGMA cipher_version')).isEmpty) {
      throw const StorageFailure(StorageFailureCode.encryptionUnavailable);
    }
    // SQLCipher can also operate as plain SQLite when no key was applied.
    // cipher_version alone only proves the library, not an active cipher context.
    final cipherPages = await _database.rawQuery('PRAGMA cipher_page_size');
    final plainHeader = await _database.rawQuery(
      'PRAGMA cipher_plaintext_header_size',
    );
    if (cipherPages.isEmpty ||
        plainHeader.isEmpty ||
        (int.tryParse(cipherPages.single.values.single.toString()) ?? 0) <= 0 ||
        int.tryParse(plainHeader.single.values.single.toString()) != 0) {
      throw const StorageFailure(StorageFailureCode.encryptionUnavailable);
    }
    await _database.rawQuery('SELECT count(*) FROM sqlite_master');
    await _database.execute(
      'CREATE TABLE IF NOT EXISTS personal_pending_media '
      '(action_id TEXT PRIMARY KEY NOT NULL, account_id TEXT NOT NULL, '
      'device_id TEXT NOT NULL, metadata TEXT NOT NULL, '
      'media BLOB NOT NULL, thumbnail BLOB, encrypted BLOB, encrypted_thumbnail BLOB, '
      'media_hash TEXT NOT NULL, thumbnail_hash TEXT, encrypted_hash TEXT, '
      'encrypted_thumbnail_hash TEXT)',
    );
    await _database.execute(
      'CREATE INDEX IF NOT EXISTS pending_media_owner '
      'ON personal_pending_media(account_id, device_id)',
    );
    await _database.execute(
      'CREATE TABLE IF NOT EXISTS personal_round_media_state '
      '(account_id TEXT NOT NULL, room_id TEXT NOT NULL, event_id TEXT NOT NULL, '
      'revision INTEGER NOT NULL, content TEXT NOT NULL, '
      'PRIMARY KEY(account_id, room_id, event_id))',
    );
  });

  /// Own Matrix account is the storage namespace; content account_id is the
  /// bridge login. The caller authenticates both before passing reverse state.
  Future<Map<String, dynamic>?> getMediaState(
    String accountId,
    String roomId,
    String eventId,
  ) => _protected(() async {
    final rows = await _database.query(
      'personal_round_media_state',
      columns: ['content'],
      where: 'account_id = ? AND room_id = ? AND event_id = ?',
      whereArgs: [accountId, roomId, eventId],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : Map<String, dynamic>.from(
            jsonDecode(rows.single['content'] as String) as Map,
          );
  });

  Future<bool> applyMediaState(
    String accountId,
    String roomId,
    String eventId,
    int revision,
    Map<String, dynamic> content,
  ) => _protected(() async {
    if (accountId.isEmpty ||
        roomId.isEmpty ||
        !eventId.startsWith(r'$') ||
        revision <= 0 ||
        content['version'] != 1 ||
        content['revision'] != revision ||
        content['room_id'] != roomId ||
        content['source_event_id'] != eventId ||
        content['account_id'] is! String ||
        (content['account_id'] as String).isEmpty ||
        content['bridge_state_key'] is! String ||
        [
          'media_unread',
          'expired',
        ].any((key) => content.containsKey(key) && content[key] is! bool))
      return false;
    return _database.transaction((tx) async {
      final rows = await tx.query(
        'personal_round_media_state',
        where: 'account_id = ? AND room_id = ? AND event_id = ?',
        whereArgs: [accountId, roomId, eventId],
        limit: 1,
      );
      Map<String, dynamic>? old;
      if (rows.isNotEmpty) {
        if ((rows.single['revision'] as int) >= revision) return false;
        old = Map<String, dynamic>.from(
          jsonDecode(rows.single['content'] as String) as Map,
        );
        if (old['account_id'] != content['account_id'] ||
            old['bridge_state_key'] != content['bridge_state_key'])
          return false;
      }
      final next = <String, dynamic>{...?old, ...content};
      // Consumption and expiry cannot be undone by a later reordered status.
      if (old?['media_unread'] == false) next['media_unread'] = false;
      if (old?['expired'] == true) next['expired'] = true;
      await tx.insert('personal_round_media_state', {
        'account_id': accountId,
        'room_id': roomId,
        'event_id': eventId,
        'revision': revision,
        'content': jsonEncode(next),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return true;
    });
  });

  @override
  Future<void> stage(PendingMediaRecord record) => _write(record, true);
  @override
  Future<void> put(PendingMediaRecord record) => _write(record, false);

  Future<void> _write(
    PendingMediaRecord record,
    bool first,
  ) => _protected(() async {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(record.actionId) ||
        record.metadata['accountId'] is! String ||
        record.metadata['deviceId'] is! String ||
        (record.metadata['accountId'] as String).isEmpty ||
        (record.metadata['deviceId'] as String).isEmpty) {
      throw const PendingMediaFailure('invalidRecord');
    }
    if ((first && record.bytes.isEmpty) ||
        record.bytes.length > maxFileBytes ||
        (record.thumbnailBytes?.length ?? 0) > maxThumbnailBytes ||
        (record.encryptedBytes?.length ?? 0) > maxFileBytes + 1024 ||
        (record.encryptedThumbnailBytes?.length ?? 0) >
            maxThumbnailBytes + 1024) {
      throw const PendingMediaFailure('fileQuota');
    }
    await _database.transaction((tx) async {
      final existing = await tx.query(
        'personal_pending_media',
        where: 'action_id = ?',
        whereArgs: [record.actionId],
        limit: 1,
      );
      if (first && existing.isNotEmpty) {
        throw const PendingMediaFailure('actionIdAlreadyUsed');
      }
      if (!first && existing.isEmpty) {
        throw const PendingMediaFailure('actionUnavailable');
      }
      if (existing.isNotEmpty) {
        final old = existing.single;
        final oldMetadata = jsonDecode(old['metadata'] as String) as Map;
        final releasing =
            record.metadata['state'] == 'completed' &&
            record.metadata['bytesReleased'] == true &&
            record.bytes.isEmpty &&
            record.thumbnailBytes == null &&
            record.encryptedBytes == null &&
            record.encryptedThumbnailBytes == null &&
            {'matrixAccepted', 'completed'}.contains(oldMetadata['state']);
        if (old['account_id'] != record.metadata['accountId'] ||
            old['device_id'] != record.metadata['deviceId'] ||
            (!releasing &&
                (old['media_hash'] != _hash(record.bytes) ||
                    old['thumbnail_hash'] != _hash(record.thumbnailBytes) ||
                    (old['encrypted_hash'] != null &&
                        old['encrypted_hash'] !=
                            _hash(record.encryptedBytes)) ||
                    (old['encrypted_thumbnail_hash'] != null &&
                        old['encrypted_thumbnail_hash'] !=
                            _hash(record.encryptedThumbnailBytes)))) ||
            _canonical(oldMetadata['target']) !=
                _canonical(record.metadata['target']) ||
            oldMetadata['transactionId'] != record.metadata['transactionId'] ||
            _canonical(oldMetadata['descriptor']) !=
                _canonical(record.metadata['descriptor']) ||
            (oldMetadata['fileDescriptor'] != null &&
                _canonical(oldMetadata['fileDescriptor']) !=
                    _canonical(record.metadata['fileDescriptor'])) ||
            (oldMetadata['thumbnailDescriptor'] != null &&
                _canonical(oldMetadata['thumbnailDescriptor']) !=
                    _canonical(record.metadata['thumbnailDescriptor'])) ||
            (oldMetadata['finalContent'] != null &&
                _canonical(oldMetadata['finalContent']) !=
                    _canonical(record.metadata['finalContent']))) {
          throw const PendingMediaFailure('immutableRecordMismatch');
        }
      }
      final sizes = await tx.rawQuery(
        'SELECT COALESCE(SUM(length(media) + '
        'COALESCE(length(thumbnail),0) + COALESCE(length(encrypted),0) + '
        'COALESCE(length(encrypted_thumbnail),0)),0) AS bytes '
        'FROM personal_pending_media WHERE action_id != ?',
        [record.actionId],
      );
      if ((sizes.single['bytes'] as int) + record.storedBytes > maxStoreBytes) {
        throw const PendingMediaFailure('storeQuota');
      }
      final row = <String, Object?>{
        'action_id': record.actionId,
        'account_id': record.metadata['accountId'],
        'device_id': record.metadata['deviceId'],
        'metadata': jsonEncode(record.metadata),
        'media': record.bytes,
        'thumbnail': record.thumbnailBytes,
        'encrypted': record.encryptedBytes,
        'encrypted_thumbnail': record.encryptedThumbnailBytes,
        'media_hash': _hash(record.bytes),
        'thumbnail_hash': _hash(record.thumbnailBytes),
        'encrypted_hash': _hash(record.encryptedBytes),
        'encrypted_thumbnail_hash': _hash(record.encryptedThumbnailBytes),
      };
      await tx.insert(
        'personal_pending_media',
        row,
        conflictAlgorithm: first
            ? ConflictAlgorithm.abort
            : ConflictAlgorithm.replace,
      );
      final verified = await tx.query(
        'personal_pending_media',
        where: 'action_id = ?',
        whereArgs: [record.actionId],
        limit: 1,
      );
      _decode(
        verified.single,
      ); // read-back and all hashes before commit/network.
    });
  });

  @override
  Future<PendingMediaRecord?> get(String actionId) => _protected(() async {
    final rows = await _database.query(
      'personal_pending_media',
      where: 'action_id = ?',
      whereArgs: [actionId],
      limit: 1,
    );
    return rows.isEmpty ? null : _decode(rows.single);
  });
  @override
  Future<List<PendingMediaRecord>> list({
    required String accountId,
    required String deviceId,
  }) => _protected(() async {
    final rows = await _database.query(
      'personal_pending_media',
      where: 'account_id = ? AND device_id = ?',
      whereArgs: [accountId, deviceId],
      orderBy: 'action_id',
    );
    return rows.map(_decode).toList(growable: false);
  });

  @override
  Future<List<PendingMediaSummary>> listSummaries({
    required String accountId,
    required String deviceId,
  }) => _protected(() async {
    final rows = await _database.rawQuery(
      'SELECT action_id, metadata, length(media) + COALESCE(length(thumbnail),0) + '
      'COALESCE(length(encrypted),0) + COALESCE(length(encrypted_thumbnail),0) '
      'AS stored_bytes FROM personal_pending_media '
      'WHERE account_id = ? AND device_id = ? ORDER BY action_id',
      [accountId, deviceId],
    );
    return rows
        .map((row) {
          final metadata = Map<String, dynamic>.from(
            jsonDecode(row['metadata'] as String) as Map,
          );
          if (metadata['accountId'] != accountId ||
              metadata['deviceId'] != deviceId ||
              row['stored_bytes'] is! int ||
              (row['stored_bytes'] as int) < 0) {
            throw const PendingMediaFailure('integrityFailure');
          }
          return PendingMediaSummary(
            actionId: row['action_id'] as String,
            metadata: metadata,
            storedBytes: row['stored_bytes'] as int,
          );
        })
        .toList(growable: false);
  });
  @override
  Future<void> remove(String actionId) => _protected(() async {
    await _database.delete(
      'personal_pending_media',
      where: 'action_id = ?',
      whereArgs: [actionId],
    );
  });
  Future<void> close() => _protected(_database.close);
  PendingMediaRecord _decode(Map<String, Object?> row) {
    for (final field in [
      'media',
      'thumbnail',
      'encrypted',
      'encrypted_thumbnail',
    ]) {
      final value = row[field];
      if ((value != null && value is! Uint8List) ||
          _hash(value as Uint8List?) != row['${field}_hash']) {
        throw const PendingMediaFailure('integrityFailure');
      }
    }
    final metadata = Map<String, dynamic>.from(
      jsonDecode(row['metadata'] as String) as Map,
    );
    if (metadata['accountId'] != row['account_id'] ||
        metadata['deviceId'] != row['device_id']) {
      throw const PendingMediaFailure('integrityFailure');
    }
    return PendingMediaRecord(
      actionId: row['action_id'] as String,
      metadata: metadata,
      bytes: row['media'] as Uint8List,
      thumbnailBytes: row['thumbnail'] as Uint8List?,
      encryptedBytes: row['encrypted'] as Uint8List?,
      encryptedThumbnailBytes: row['encrypted_thumbnail'] as Uint8List?,
    );
  }

  static String? _hash(Uint8List? value) =>
      value == null ? null : sha256.convert(value).toString();
  static String _canonical(Object? value) {
    Object? sorted(Object? v) {
      if (v is Map) {
        final keys = v.keys.cast<String>().toList()..sort();
        return {for (final k in keys) k: sorted(v[k])};
      }
      if (v is List) return v.map(sorted).toList();
      return v;
    }

    return jsonEncode(sorted(value));
  }

  static Future<T> _protected<T>(Future<T> Function() operation) async {
    PendingMediaFailure? failure;
    final result = await preserveOnStorageFailure(() async {
      try {
        return await operation();
      } on PendingMediaFailure catch (e) {
        failure = e;
        return null;
      }
    });
    if (failure != null) throw failure!;
    return result as T;
  }

  @override
  String toString() => 'PendingMediaStore(protected)';
}

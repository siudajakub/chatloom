// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../storage/database_policy.dart';
import '../storage/storage_failure.dart';

/// Unmodifiable copies owned by this library. Their bytes can never change, so
/// they are never copied again and their SHA-256 is computed at most once.
final Expando<bool> _frozenViews = Expando<bool>('pending-media-frozen');
final Expando<String> _digests = Expando<String>('pending-media-sha256');

/// Payloads at least this large are hashed on a background isolate: a 5 MB
/// round took ~70 ms of pure-Dart SHA-256 on the calling (UI) isolate.
const pendingMediaIsolateDigestBytes = 512 * 1024;

/// An unmodifiable private copy of [value]; no copy when it already is one.
Uint8List freezePendingMediaBytes(Uint8List value) {
  if (_frozenViews[value] == true) return value;
  return _adoptPendingMediaBytes(Uint8List.fromList(value));
}

/// Freezes bytes nobody else references (fresh from storage) without copying.
Uint8List _adoptPendingMediaBytes(Uint8List owned) {
  final frozen = owned.asUnmodifiableView();
  _frozenViews[frozen] = true;
  return frozen;
}

/// Hex SHA-256 of [value], remembered for frozen payloads.
String pendingMediaDigest(Uint8List value) {
  final cached = _digests[value];
  if (cached != null) return cached;
  final digest = sha256.convert(value).toString();
  if (_frozenViews[value] == true) _digests[value] = digest;
  return digest;
}

/// [pendingMediaDigest] computed off the calling isolate for large payloads.
Future<String> pendingMediaDigestAsync(Uint8List value) async {
  final cached = _digests[value];
  if (cached != null) return cached;
  if (value.length < pendingMediaIsolateDigestBytes) {
    return pendingMediaDigest(value);
  }
  final transfer = TransferableTypedData.fromList([value]);
  final digest = await Isolate.run(
    () => sha256.convert(transfer.materialize().asUint8List()).toString(),
  );
  if (_frozenViews[value] == true) _digests[value] = digest;
  return digest;
}

Future<String?> _digestOrNull(Uint8List? value) async =>
    value == null ? null : pendingMediaDigestAsync(value);

/// Metadata is stored padded with JSON whitespace to a multiple of this many
/// UTF-8 bytes. A state transition then usually leaves the row size unchanged,
/// and SQLite overwrites the row in place, writing only pages whose bytes
/// differ: the multi-megabyte media BLOBs are not rewritten, journaled or
/// zeroed (secure_delete) for every checkpoint. Readers decode it unchanged.
const pendingMediaMetadataBucketBytes = 4096;

String _encodeMetadata(Map<String, dynamic> metadata) {
  final json = jsonEncode(metadata);
  final length = utf8.encode(json).length;
  final padded =
      (length ~/ pendingMediaMetadataBucketBytes + 1) *
      pendingMediaMetadataBucketBytes;
  return json.padRight(json.length + padded - length);
}

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
      value == null ? null : freezePendingMediaBytes(value);
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

/// Optional: persists a state transition whose payloads are unchanged without
/// re-sending, re-reading or re-hashing the media BLOBs. Implementations must
/// enforce the same identity/immutability rules as a full write.
abstract interface class PendingMediaMetadataRepository {
  Future<void> putMetadata(PendingMediaRecord record);
}

/// Optional: [PendingMediaRepository.stage] that returns the row it read back
/// and verified inside the write transaction, so the caller does not read and
/// hash the same payloads a second time.
abstract interface class PendingMediaVerifiedStaging {
  Future<PendingMediaRecord> stageVerified(PendingMediaRecord record);
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
    implements
        PendingMediaRepository,
        PendingMediaSummaryRepository,
        PendingMediaMetadataRepository,
        PendingMediaVerifiedStaging {
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

  /// Batched [getMediaState]: one query per [chunkSize] ids instead of one per
  /// visible round. Unknown ids are absent from the result (known-null).
  Future<Map<String, Map<String, dynamic>>> getMediaStates(
    String accountId,
    String roomId,
    Iterable<String> eventIds, {
    int chunkSize = 200,
  }) => _protected(() async {
    final ids = eventIds.toSet().toList();
    final result = <String, Map<String, dynamic>>{};
    if (ids.isEmpty) return result;
    final step = chunkSize.clamp(1, 900);
    for (var start = 0; start < ids.length; start += step) {
      final chunk = ids.sublist(start, (start + step).clamp(0, ids.length));
      final rows = await _database.query(
        'personal_round_media_state',
        columns: ['event_id', 'content'],
        where:
            'account_id = ? AND room_id = ? AND event_id IN '
            '(${List.filled(chunk.length, '?').join(', ')})',
        whereArgs: [accountId, roomId, ...chunk],
      );
      for (final row in rows) {
        result[row['event_id'] as String] = Map<String, dynamic>.from(
          jsonDecode(row['content'] as String) as Map,
        );
      }
    }
    return result;
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
  Future<PendingMediaRecord> stageVerified(PendingMediaRecord record) =>
      _write(record, true);
  @override
  Future<void> put(PendingMediaRecord record) => _write(record, false);

  static void _requireIdentity(PendingMediaRecord record) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(record.actionId) ||
        record.metadata['accountId'] is! String ||
        record.metadata['deviceId'] is! String ||
        (record.metadata['accountId'] as String).isEmpty ||
        (record.metadata['deviceId'] as String).isEmpty) {
      throw const PendingMediaFailure('invalidRecord');
    }
  }

  /// Frozen identity, routing and once-set descriptors never change in place.
  static bool _immutableChanged(
    Map oldMetadata,
    Map<String, dynamic> metadata,
  ) =>
      _canonical(oldMetadata['target']) != _canonical(metadata['target']) ||
      oldMetadata['transactionId'] != metadata['transactionId'] ||
      _canonical(oldMetadata['descriptor']) !=
          _canonical(metadata['descriptor']) ||
      (oldMetadata['fileDescriptor'] != null &&
          _canonical(oldMetadata['fileDescriptor']) !=
              _canonical(metadata['fileDescriptor'])) ||
      (oldMetadata['thumbnailDescriptor'] != null &&
          _canonical(oldMetadata['thumbnailDescriptor']) !=
              _canonical(metadata['thumbnailDescriptor'])) ||
      (oldMetadata['finalContent'] != null &&
          _canonical(oldMetadata['finalContent']) !=
              _canonical(metadata['finalContent']));

  /// Returns the row as read back (and hash-verified) before commit.
  Future<PendingMediaRecord> _write(
    PendingMediaRecord record,
    bool first,
  ) => _protected(() async {
    _requireIdentity(record);
    if ((first && record.bytes.isEmpty) ||
        record.bytes.length > maxFileBytes ||
        (record.thumbnailBytes?.length ?? 0) > maxThumbnailBytes ||
        (record.encryptedBytes?.length ?? 0) > maxFileBytes + 1024 ||
        (record.encryptedThumbnailBytes?.length ?? 0) >
            maxThumbnailBytes + 1024) {
      throw const PendingMediaFailure('fileQuota');
    }
    // One digest per payload (memoized for frozen views), outside the UI isolate.
    final mediaHash = await pendingMediaDigestAsync(record.bytes);
    final thumbnailHash = await _digestOrNull(record.thumbnailBytes);
    final encryptedHash = await _digestOrNull(record.encryptedBytes);
    final encryptedThumbnailHash = await _digestOrNull(
      record.encryptedThumbnailBytes,
    );
    return _database.transaction((tx) async {
      final existing = await tx.query(
        'personal_pending_media',
        columns: [
          'account_id',
          'device_id',
          'metadata',
          'media_hash',
          'thumbnail_hash',
          'encrypted_hash',
          'encrypted_thumbnail_hash',
        ],
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
                (old['media_hash'] != mediaHash ||
                    old['thumbnail_hash'] != thumbnailHash ||
                    (old['encrypted_hash'] != null &&
                        old['encrypted_hash'] != encryptedHash) ||
                    (old['encrypted_thumbnail_hash'] != null &&
                        old['encrypted_thumbnail_hash'] !=
                            encryptedThumbnailHash))) ||
            _immutableChanged(oldMetadata, record.metadata)) {
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
        'metadata': _encodeMetadata(record.metadata),
        'media': record.bytes,
        'thumbnail': record.thumbnailBytes,
        'encrypted': record.encryptedBytes,
        'encrypted_thumbnail': record.encryptedThumbnailBytes,
        'media_hash': mediaHash,
        'thumbnail_hash': thumbnailHash,
        'encrypted_hash': encryptedHash,
        'encrypted_thumbnail_hash': encryptedThumbnailHash,
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
      return _decode(
        verified.single,
      ); // read-back and all hashes before commit/network.
    });
  });

  /// Metadata-only transition: the stored payload hashes must equal the
  /// record's (memoized, so normally free), the same identity/immutability
  /// rules as [put] apply, and the written metadata is read back before
  /// commit. BLOBs are never sent, read or re-hashed. Releasing bytes still
  /// requires [put].
  @override
  Future<void> putMetadata(PendingMediaRecord record) => _protected(() async {
    _requireIdentity(record);
    final hashes = [
      await pendingMediaDigestAsync(record.bytes),
      await _digestOrNull(record.thumbnailBytes),
      await _digestOrNull(record.encryptedBytes),
      await _digestOrNull(record.encryptedThumbnailBytes),
    ];
    const hashColumns = [
      'media_hash',
      'thumbnail_hash',
      'encrypted_hash',
      'encrypted_thumbnail_hash',
    ];
    final metadata = _encodeMetadata(record.metadata);
    await _database.transaction((tx) async {
      Future<Map<String, Object?>?> row() async {
        final rows = await tx.query(
          'personal_pending_media',
          columns: ['account_id', 'device_id', 'metadata', ...hashColumns],
          where: 'action_id = ?',
          whereArgs: [record.actionId],
          limit: 1,
        );
        return rows.isEmpty ? null : rows.single;
      }

      bool sameOwnerAndPayload(Map<String, Object?> value) =>
          value['account_id'] == record.metadata['accountId'] &&
          value['device_id'] == record.metadata['deviceId'] &&
          [
            for (var i = 0; i < hashColumns.length; i++)
              value[hashColumns[i]] == hashes[i],
          ].every((same) => same);

      final old = await row();
      if (old == null) throw const PendingMediaFailure('actionUnavailable');
      final oldMetadata = jsonDecode(old['metadata'] as String) as Map;
      if (!sameOwnerAndPayload(old) ||
          _immutableChanged(oldMetadata, record.metadata)) {
        throw const PendingMediaFailure('immutableRecordMismatch');
      }
      await tx.update(
        'personal_pending_media',
        {'metadata': metadata},
        where: 'action_id = ? AND account_id = ? AND device_id = ?',
        whereArgs: [
          record.actionId,
          record.metadata['accountId'],
          record.metadata['deviceId'],
        ],
      );
      final verified = await row();
      if (verified == null ||
          !sameOwnerAndPayload(verified) ||
          _canonical(jsonDecode(verified['metadata'] as String)) !=
              _canonical(record.metadata)) {
        throw const PendingMediaFailure('integrityFailure');
      }
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
    return rows.isEmpty ? null : await _decode(rows.single);
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
    return [for (final row in rows) await _decode(row)];
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

  /// Every payload read from storage is verified against its stored hash.
  /// The bytes are adopted (frozen, not copied) and keep their digest, so the
  /// caller's later integrity checks and writes do not hash them again.
  Future<PendingMediaRecord> _decode(Map<String, Object?> row) async {
    final payloads = <String, Uint8List?>{};
    for (final field in [
      'media',
      'thumbnail',
      'encrypted',
      'encrypted_thumbnail',
    ]) {
      final value = row[field];
      if (value != null && value is! Uint8List) {
        throw const PendingMediaFailure('integrityFailure');
      }
      final adopted = value == null
          ? null
          : _adoptPendingMediaBytes(value as Uint8List);
      if (await _digestOrNull(adopted) != row['${field}_hash']) {
        throw const PendingMediaFailure('integrityFailure');
      }
      payloads[field] = adopted;
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
      bytes: payloads['media']!,
      thumbnailBytes: payloads['thumbnail'],
      encryptedBytes: payloads['encrypted'],
      encryptedThumbnailBytes: payloads['encrypted_thumbnail'],
    );
  }

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

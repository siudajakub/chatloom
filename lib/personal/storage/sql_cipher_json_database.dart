// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'database_policy.dart';
import 'storage_failure.dart';

/// Native SQLCipher implementation kept independent from Flutter UI/plugins.
class SqlCipherJsonDatabase {
  final Database _database;
  SqlCipherJsonDatabase._(this._database);

  static Future<SqlCipherJsonDatabase> open({
    required String path,
    required String cipher,
    DatabaseFactory? factory,
  }) => preserveOnStorageFailure(() async {
    // A constrained format is required because PRAGMA key cannot be bound.
    if (!RegExp(r'^[A-Za-z0-9_-]{43}=?$').hasMatch(cipher) ||
        base64Url.decode(cipher).length != 32) {
      throw const StorageFailure(StorageFailureCode.keyUnavailable);
    }
    await requireEncryptedDatabaseFile(path);
    final database = await (factory ?? createDatabaseFactoryFfi()).openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) async {
          final version = await db.rawQuery('PRAGMA cipher_version');
          if (version.isEmpty) {
            throw const StorageFailure(
              StorageFailureCode.encryptionUnavailable,
            );
          }
          await db.execute("PRAGMA key = '$cipher'");
          // Authenticate before creating/changing the schema.
          await db.rawQuery('SELECT count(*) FROM sqlite_master');
          await db.execute('PRAGMA secure_delete = ON');
          await db.execute('PRAGMA temp_store = MEMORY');
        },
        onCreate: (db, _) => db.execute(
          'CREATE TABLE personal_entries '
          '(entry_key TEXT PRIMARY KEY NOT NULL, json_value TEXT NOT NULL)',
        ),
      ),
    );
    return SqlCipherJsonDatabase._(database);
  });

  Future<Map<String, dynamic>?> get(String key) =>
      preserveOnStorageFailure(() async {
        final rows = await _database.query(
          'personal_entries',
          columns: ['json_value'],
          where: 'entry_key = ?',
          whereArgs: [key],
          limit: 1,
        );
        return rows.isEmpty ? null : _decode(rows.single['json_value']);
      });

  Future<void> put(String key, Map<String, dynamic> value) =>
      preserveOnStorageFailure(() async {
        late final String encoded;
        try {
          encoded = jsonEncode(value);
        } catch (_) {
          throw const StorageFailure(StorageFailureCode.invalidData);
        }
        await _database.insert('personal_entries', {
          'entry_key': key,
          'json_value': encoded,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });

  Future<void> delete(String key) => preserveOnStorageFailure(() async {
    await _database.delete(
      'personal_entries',
      where: 'entry_key = ?',
      whereArgs: [key],
    );
  });

  /// '%' and '_' are literal, and SQLite length handles Unicode code points.
  Future<Map<String, Map<String, dynamic>>> readPrefix(String prefix) =>
      preserveOnStorageFailure(() async {
        final rows = await _database.query(
          'personal_entries',
          where: 'substr(entry_key, 1, length(?)) = ?',
          whereArgs: [prefix, prefix],
          orderBy: 'entry_key',
        );
        return {
          for (final row in rows)
            row['entry_key']! as String: _decode(row['json_value']),
        };
      });

  Future<void> close() => preserveOnStorageFailure(_database.close);

  static Map<String, dynamic> _decode(Object? value) {
    try {
      return Map<String, dynamic>.from(jsonDecode(value! as String) as Map);
    } catch (_) {
      throw const StorageFailure(StorageFailureCode.invalidData);
    }
  }

  @override
  String toString() => 'SqlCipherJsonDatabase(protected)';
}

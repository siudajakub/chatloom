// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:fluffychat/utils/matrix_sdk_extensions/flutter_matrix_dart_sdk_database/cipher.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

import 'database_policy.dart';
import 'sql_cipher_json_database.dart';
import 'storage_failure.dart';

export 'storage_failure.dart';

/// Native encrypted JSON storage. Web is deliberately unsupported: the browser
/// database has different at-rest guarantees and is only a compatibility spike.
class PersonalStore {
  final SqlCipherJsonDatabase _database;
  PersonalStore._(this._database);

  static Future<PersonalStore> open({String? directory}) async {
    if (kIsWeb) {
      throw const StorageFailure(StorageFailureCode.unsupportedPlatform);
    }
    return preserveOnStorageFailure(() async {
      final root = Directory(
        directory ?? (await getApplicationSupportDirectory()).path,
      );
      await root.create(recursive: true);
      final path = join(root.path, 'personal_v1.sqlite');
      final lock = await File('$path.init.lock').open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.blockingExclusive);
        await requireEncryptedDatabaseFile(path);
        final cipher = await getProtectedStorageCipher(
          'personal_database_password_v1',
          requireExisting: await File(path).exists(),
        );
        return PersonalStore._(
          await SqlCipherJsonDatabase.open(path: path, cipher: cipher),
        );
      } finally {
        await lock.close();
      }
    });
  }

  Future<Map<String, dynamic>?> get(String key) => _database.get(key);
  Future<void> put(String key, Map<String, dynamic> value) =>
      _database.put(key, value);
  Future<void> delete(String key) => _database.delete(key);
  Future<Map<String, Map<String, dynamic>>> readPrefix(String prefix) =>
      _database.readPrefix(prefix);
  Future<void> close() => _database.close();

  @override
  String toString() => 'PersonalStore(protected)';
}

// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'storage_failure.dart';

/// Prevents upstream's destructive automatic plaintext migration. Existing
/// legacy files remain untouched until a separate explicit migration is used.
Future<void> requireEncryptedDatabaseFile(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return;
    final handle = await file.open();
    try {
      final header = await handle.read(16);
      const plainHeader = <int>[
        83,
        81,
        76,
        105,
        116,
        101,
        32,
        102,
        111,
        114,
        109,
        97,
        116,
        32,
        51,
        0,
      ];
      if (header.length == plainHeader.length &&
          List.generate(
            header.length,
            (i) => header[i] == plainHeader[i],
          ).every((equal) => equal)) {
        throw const StorageFailure(StorageFailureCode.legacyMigrationRequired);
      }
    } finally {
      await handle.close();
    }
  } on StorageFailure {
    rethrow;
  } catch (_) {
    throw const StorageFailure(StorageFailureCode.databaseUnavailable);
  }
}

/// Runs initialization once, with no retry, deletion or exception leakage.
Future<T> preserveOnStorageFailure<T>(Future<T> Function() initialize) async {
  try {
    // Sqflite prints entire open/rollback exceptions (including paths and SQL)
    // even when its configured log level is disabled. Suppress package prints
    // in this narrow boundary; callers report only StorageFailure.code.
    return await runZoned(
      initialize,
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) {},
      ),
    );
  } on StorageFailure {
    rethrow;
  } catch (_) {
    throw const StorageFailure(StorageFailureCode.databaseUnavailable);
  }
}

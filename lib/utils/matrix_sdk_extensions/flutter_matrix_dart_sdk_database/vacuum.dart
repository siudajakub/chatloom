// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Free pages an open keeps for reuse instead of releasing them.
///
/// Media cache evictions and limited-sync timeline deletions free pages that
/// the next downloads and syncs fill again. The SDK helper released all of
/// them on every open (`PRAGMA incremental_vacuum` without a limit), which
/// moves pages from the end of the file into the gaps (read, decrypt,
/// encrypt, journal, write) before the app, or a push that started it, can
/// read anything. Above this reserve the excess is still released.
const vacuumReserveBytes = 16 * 1024 * 1024;

/// Replaces `SQfLiteEncryptionHelper.applyPragmaKey`'s
/// `ensureIncrementalAutoVacuum`: the one-time switch to incremental
/// auto-vacuum is unchanged; afterwards an open releases only the free pages
/// beyond [reserveBytes]. Call after the key was applied.
Future<void> prepareIncrementalAutoVacuum(
  Database database, {
  int reserveBytes = vacuumReserveBytes,
}) async {
  const incrementalAutoVacuum = 2;
  if (await _pragmaInt(database, 'auto_vacuum') != incrementalAutoVacuum) {
    Logs().i('Switching database to incremental auto_vacuum...');
    await database.rawQuery('PRAGMA auto_vacuum = $incrementalAutoVacuum');
    await database.rawQuery('VACUUM');
    return;
  }
  try {
    final free = await _pragmaInt(database, 'freelist_count') ?? 0;
    final pageSize = await _pragmaInt(database, 'page_size') ?? 4096;
    final excess = free - reserveBytes ~/ (pageSize > 0 ? pageSize : 4096);
    if (excess > 0) {
      await database.rawQuery('PRAGMA incremental_vacuum($excess)');
    }
  } catch (error) {
    // Space reclamation only; the database itself is open and usable.
    Logs().w('incremental_vacuum_skipped', error.runtimeType.toString());
  }
}

Future<int?> _pragmaInt(Database database, String pragma) async {
  final rows = await database.rawQuery('PRAGMA $pragma');
  final value = rows.isEmpty || rows.first.isEmpty
      ? null
      : rows.first.values.first;
  // SQLCipher reports some pragmas (page_size) as text.
  return value is int ? value : int.tryParse('$value');
}

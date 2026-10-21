// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatloom/utils/matrix_sdk_extensions/flutter_matrix_dart_sdk_database/vacuum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Opening the Matrix database (app start, and every push that starts the
/// app) releases only the free pages beyond a reserve (2026-10-21).
void main() {
  late Directory directory;
  final factory = createDatabaseFactoryFfi(noIsolate: true);
  final key = base64UrlEncode(List<int>.filled(32, 9));

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('database_vacuum_');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  Future<Database> open() => factory.openDatabase(
    '${directory.path}/matrix.sqlite',
    options: OpenDatabaseOptions(
      onConfigure: (db) => db.execute("PRAGMA key = '$key'"),
    ),
  );

  Future<int> pragma(Database db, String name) async =>
      int.parse('${(await db.rawQuery('PRAGMA $name')).first.values.first}');

  test('switches to incremental auto-vacuum once, as the SDK did', () async {
    final db = await open();
    await db.execute('CREATE TABLE t (v BLOB)');
    expect(await pragma(db, 'auto_vacuum'), isNot(2));
    await prepareIncrementalAutoVacuum(db);
    expect(await pragma(db, 'auto_vacuum'), 2);
    await db.close();
  });

  test('keeps a reserve of free pages and releases only the excess', () async {
    var db = await open();
    await prepareIncrementalAutoVacuum(db);
    await db.execute('CREATE TABLE t (v BLOB)');
    for (var i = 0; i < 64; i++) {
      await db.insert('t', {'v': Uint8List(16 * 1024)});
    }
    await db.delete('t');
    final pageSize = await pragma(db, 'page_size');
    final free = await pragma(db, 'freelist_count');
    expect(free * pageSize, greaterThan(512 * 1024));
    await db.close();

    // A reserve larger than the free space: nothing is moved on open.
    db = await open();
    await prepareIncrementalAutoVacuum(db, reserveBytes: 4 * 1024 * 1024);
    expect(await pragma(db, 'freelist_count'), free);
    await db.close();

    // Above the reserve, only the excess is released.
    db = await open();
    await prepareIncrementalAutoVacuum(db, reserveBytes: 64 * pageSize);
    expect(await pragma(db, 'freelist_count'), 64);
    await db.close();
  });
}

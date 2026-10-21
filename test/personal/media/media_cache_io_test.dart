// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatloom/personal/media/encrypted_media_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Statement budget of the media cache that shares the Matrix database
/// (2026-10-21): the SDK prunes after every sync, avatars and thumbnails are
/// read on every scroll, and every download is stored.
void main() {
  late Directory directory;
  final factory = createDatabaseFactoryFfi(noIsolate: true);
  late Database database;
  var now = DateTime.utc(2026, 10, 21, 8);

  setUp(() async {
    now = DateTime.utc(2026, 10, 21, 8);
    directory = await Directory.systemTemp.createTemp('media_cache_io_');
    database = await factory.openDatabase(
      '${directory.path}/cache.sqlite',
      options: OpenDatabaseOptions(
        onConfigure: (db) => db.execute(
          "PRAGMA key = '${base64UrlEncode(List<int>.filled(32, 7))}'",
        ),
      ),
    );
  });

  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  EncryptedMediaCache cache({int maxCacheBytes = 1000}) => EncryptedMediaCache(
    database,
    maxFileSize: 500,
    maxCacheBytes: maxCacheBytes,
    retention: const Duration(days: 30),
    now: () => now,
  );

  Uri mxc(String id) => Uri.parse('mxc://fixture/$id');

  test('expiry after every sync runs once an hour and uses an index', () async {
    final media = cache();
    await media.initialize();
    expect(media.debugPrunes, 1, reason: 'open prunes once');
    await media.storeFile(mxc('old'), Uint8List(10), 0);

    // The SDK calls this after every sync (every idle long-poll answer).
    for (var i = 0; i < 120; i++) {
      now = now.add(const Duration(seconds: 30));
      await media.deleteOldFiles(0);
    }
    expect(media.debugPrunes, 1 + 1, reason: 'one hour of syncs, one prune');

    // Expired files are never served while the prune is throttled.
    now = now.add(const Duration(days: 30));
    expect(await media.getFile(mxc('old')), isNull);
    expect(await media.hasFile(mxc('old')), isFalse);
    await media.deleteOldFiles(0);
    expect(
      await database.query('personal_media_cache'),
      isEmpty,
      reason: 'the next due prune removes it',
    );

    final plan = await database.rawQuery(
      'EXPLAIN QUERY PLAN DELETE FROM personal_media_cache '
      'WHERE saved_at <= ?',
      [0],
    );
    expect(
      plan.map((row) => row['detail']).join(' '),
      contains('personal_media_cache_saved_at'),
    );
  });

  test('an existing cache gets the expiry index on open', () async {
    await database.execute(
      'CREATE TABLE personal_media_cache '
      '(media_key TEXT PRIMARY KEY NOT NULL, bytes BLOB NOT NULL, '
      'saved_at INTEGER NOT NULL, accessed_at INTEGER NOT NULL)',
    );
    await database.insert('personal_media_cache', {
      'media_key': mxc('kept').toString(),
      'bytes': Uint8List(3),
      'saved_at': now.millisecondsSinceEpoch,
      'accessed_at': now.millisecondsSinceEpoch,
    });
    final media = cache();
    await media.initialize();
    final indexes = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index' "
      "AND tbl_name = 'personal_media_cache'",
    );
    expect(
      indexes.map((row) => row['name']),
      contains('personal_media_cache_saved_at'),
    );
    expect(await media.getFile(mxc('kept')), hasLength(3));
  });

  test('reads refresh the access time only when it is hours old', () async {
    final media = cache();
    await media.initialize();
    await media.storeFile(mxc('avatar'), Uint8List.fromList([1, 2, 3]), 0);
    Future<int> accessed() async =>
        (await database.query(
              'personal_media_cache',
              columns: ['accessed_at'],
            )).single['accessed_at']!
            as int;
    final stored = await accessed();

    // Scrolling the inbox back and forth for an hour: no write per read.
    for (var i = 0; i < 60; i++) {
      now = now.add(const Duration(minutes: 1));
      expect(await media.getFile(mxc('avatar')), [1, 2, 3]);
    }
    expect(media.debugTouches, 0);
    expect(await accessed(), stored);

    now = now.add(const Duration(hours: 12));
    expect(await media.getFile(mxc('avatar')), [1, 2, 3]);
    expect(media.debugTouches, 1);
    expect(await accessed(), now.millisecondsSinceEpoch);
  });

  test(
    'stores scan for eviction only near the budget, then trim to 90 %',
    () async {
      final media = cache();
      await media.initialize();
      // The first store of a process measures the cache once.
      for (var i = 0; i < 9; i++) {
        now = now.add(const Duration(minutes: 1));
        await media.storeFile(mxc('t$i'), Uint8List(100), 0);
      }
      expect(media.debugEvictionScans, 1);

      // A thumbnail read long ago is refreshed and so survives the trim.
      now = now.add(const Duration(hours: 13));
      expect(await media.getFile(mxc('t0')), hasLength(100));

      // 1000 bytes still fit; the next store exceeds the budget.
      now = now.add(const Duration(minutes: 1));
      await media.storeFile(mxc('t9'), Uint8List(100), 0);
      expect(media.debugEvictionScans, 1);
      now = now.add(const Duration(minutes: 1));
      await media.storeFile(mxc('t10'), Uint8List(100), 0);
      expect(media.debugEvictionScans, 2);

      final kept = {
        for (final row in await database.query(
          'personal_media_cache',
          columns: ['media_key'],
        ))
          row['media_key'],
      };
      expect(kept, hasLength(9), reason: 'trimmed to 900 of 1000 bytes');
      expect(kept, contains(mxc('t10').toString()), reason: 'newest kept');
      expect(kept, contains(mxc('t0').toString()), reason: 'recently read');
      expect(kept, isNot(contains(mxc('t1').toString())), reason: 'oldest');
      expect(kept, isNot(contains(mxc('t2').toString())));

      // The trim leaves room: the next store needs no scan.
      now = now.add(const Duration(minutes: 1));
      await media.storeFile(mxc('t11'), Uint8List(100), 0);
      expect(media.debugEvictionScans, 2);
    },
  );

  test('a file larger than the trim target is kept when just stored', () async {
    final media = EncryptedMediaCache(
      database,
      maxFileSize: 100,
      maxCacheBytes: 100,
      now: () => now,
    );
    await media.initialize();
    await media.storeFile(mxc('a'), Uint8List(60), 0);
    now = now.add(const Duration(seconds: 1));
    await media.storeFile(mxc('b'), Uint8List(95), 0);
    expect(await media.getFile(mxc('a')), isNull);
    expect(await media.getFile(mxc('b')), hasLength(95));
    await media.clear();
    expect(await media.getFile(mxc('b')), isNull);
    await media.storeFile(mxc('c'), Uint8List(10), 0);
    expect(await media.getFile(mxc('c')), hasLength(10));
  });
}

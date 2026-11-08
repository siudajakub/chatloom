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

  Uri instagram(String scheme, String id) =>
      Uri(scheme: scheme, host: 'instagram', path: '/$id');

  test('only internal Instagram keys receive the short media policy', () {
    expect(EncryptedMediaCache.instagramRetention, const Duration(days: 1));
    expect(EncryptedMediaCache.instagramMaxFileSize, 64 * 1024 * 1024);
    for (final scheme in ['chatloom-media', 'chatloom-link']) {
      expect(
        EncryptedMediaCache.isInstagramKey(instagram(scheme, 'fixture')),
        isTrue,
      );
    }
    for (final key in [
      'mxc://instagram/fixture',
      'https://instagram/fixture',
      'chatloom-media://instagram.evil/fixture',
      'chatloom-link://other/instagram/fixture',
      'chatloom-media://user@instagram/fixture',
      'chatloom-link://instagram:444/fixture',
    ]) {
      expect(EncryptedMediaCache.isInstagramKey(Uri.parse(key)), isFalse);
    }
  });

  test('Instagram files up to 64 MiB use the shared encrypted cache', () async {
    final media = EncryptedMediaCache(database, now: () => now);
    await media.initialize();
    final key = instagram('chatloom-media', 'large-video');
    final oversized = Uint8List(EncryptedMediaCache.instagramMaxFileSize + 1);
    final atLimit = Uint8List.sublistView(oversized, 0, oversized.length - 1);
    expect(atLimit.length, greaterThan(media.maxFileSize));
    await media.storeFile(key, atLimit, 0);
    expect(await media.hasFile(key), isTrue);
    final sizes = await database.rawQuery(
      'SELECT length(bytes) AS size FROM personal_media_cache',
    );
    expect(sizes.single['size'], EncryptedMediaCache.instagramMaxFileSize);

    final tooLarge = instagram('chatloom-media', 'too-large-video');
    await media.storeFile(tooLarge, oversized, 0);
    expect(await media.hasFile(tooLarge), isFalse);
    await media.storeFile(mxc('ordinary-video'), atLimit, 0);
    expect(await media.hasFile(mxc('ordinary-video')), isFalse);
  });

  test('Instagram files still respect the configured total budget', () async {
    final media = cache(maxCacheBytes: 1000);
    await media.initialize();
    final key = instagram('chatloom-media', 'video');
    await media.storeFile(key, Uint8List(800), 0);
    expect(await media.getFile(key), hasLength(800));
    await media.storeFile(
      instagram('chatloom-media', 'too-large-for-cache'),
      Uint8List(1001),
      0,
    );
    now = now.add(const Duration(seconds: 1));
    final newest = instagram('chatloom-media', 'newest');
    await media.storeFile(newest, Uint8List(800), 0);
    expect(await media.hasFile(key), isFalse);
    expect(await media.hasFile(newest), isTrue);
    final sizes = await database.rawQuery(
      'SELECT SUM(length(bytes)) AS size FROM personal_media_cache',
    );
    expect(sizes.single['size'], lessThanOrEqualTo(1000));
  });

  test('Instagram reads do not extend the absolute one-day lifetime', () async {
    final media = cache();
    await media.initialize();
    final keys = [
      instagram('chatloom-media', 'video'),
      instagram('chatloom-link', 'metadata'),
    ];
    for (final key in [...keys, mxc('ordinary')]) {
      await media.storeFile(key, Uint8List.fromList([1, 2, 3]), 0);
    }
    final savedAt = now.millisecondsSinceEpoch;
    now = now.add(const Duration(hours: 23, minutes: 59));
    for (final key in keys) {
      expect(await media.getFile(key), [1, 2, 3]);
      expect(await media.hasFile(key), isTrue);
    }
    final rows = await database.query(
      'personal_media_cache',
      columns: ['saved_at', 'accessed_at'],
      where: "media_key GLOB 'chatloom-*'",
    );
    for (final row in rows) {
      expect(row['saved_at'], savedAt);
      expect(row['accessed_at'], now.millisecondsSinceEpoch);
    }

    now = now.add(const Duration(minutes: 1));
    for (final key in keys) {
      expect(await media.getFile(key), isNull);
      expect(await media.hasFile(key), isFalse);
    }
    expect(await media.getFile(mxc('ordinary')), [1, 2, 3]);
  });

  test(
    'Instagram expiry is physically pruned within the hourly window',
    () async {
      final media = cache();
      await media.initialize();
      now = now.add(const Duration(minutes: 1));
      final key = instagram('chatloom-media', 'video');
      await media.storeFile(key, Uint8List(10), 0);
      now = now.add(const Duration(hours: 23, minutes: 59));
      await media.deleteOldFiles(0);
      expect(await media.hasFile(key), isTrue);
      now = now.add(const Duration(minutes: 1));
      expect(await media.hasFile(key), isFalse);
      await media.deleteOldFiles(0);
      expect(
        await database.query('personal_media_cache', columns: ['media_key']),
        hasLength(1),
        reason: 'physical prune is throttled, but expired files are not served',
      );
      now = now.add(const Duration(minutes: 59));
      await media.deleteOldFiles(0);
      expect(
        await database.query('personal_media_cache', columns: ['media_key']),
        isEmpty,
      );
    },
  );

  test(
    'opening prunes legacy Instagram rows while keeping ordinary media',
    () async {
      await database.execute(
        'CREATE TABLE personal_media_cache '
        '(media_key TEXT PRIMARY KEY NOT NULL, bytes BLOB NOT NULL, '
        'saved_at INTEGER NOT NULL, accessed_at INTEGER NOT NULL)',
      );
      for (final key in [
        instagram('chatloom-media', 'legacy-video'),
        instagram('chatloom-link', 'legacy-metadata'),
        mxc('ordinary'),
      ]) {
        await database.insert('personal_media_cache', {
          'media_key': key.toString(),
          'bytes': Uint8List(3),
          'saved_at': now
              .subtract(const Duration(days: 1))
              .millisecondsSinceEpoch,
          'accessed_at': now.millisecondsSinceEpoch,
        });
      }
      final media = cache();
      await media.initialize();
      final rows = await database.query(
        'personal_media_cache',
        columns: ['media_key'],
      );
      expect(rows.map((row) => row['media_key']), [mxc('ordinary').toString()]);
    },
  );

  test('a shorter configured retention still applies to Instagram', () async {
    final media = EncryptedMediaCache(
      database,
      retention: const Duration(hours: 2),
      now: () => now,
    );
    await media.initialize();
    final key = instagram('chatloom-media', 'video');
    await media.storeFile(key, Uint8List(3), 0);
    now = now.add(const Duration(hours: 2));
    expect(await media.getFile(key), isNull);
    expect(await media.hasFile(key), isFalse);
    await media.deleteOldFiles(0);
    expect(await database.query('personal_media_cache'), isEmpty);
  });

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

  test('copies of unsent files are never evicted for other media', () async {
    // CC-03: the copy is the only source for Retry of an unsent file.
    final media = cache();
    await media.initialize();
    final unsent = Uri(scheme: 'cache', host: 'file', path: 'fixture-txid');
    await media.storeFile(unsent, Uint8List(300), 0);
    for (var i = 0; i < 12; i++) {
      now = now.add(const Duration(minutes: 1));
      await media.storeFile(mxc('m$i'), Uint8List(100), 0);
    }
    expect(media.debugEvictionScans, greaterThan(1));
    expect(await media.getFile(unsent), hasLength(300));
    final total =
        (await database.rawQuery(
              'SELECT SUM(length(bytes)) AS size FROM personal_media_cache',
            )).single['size']!
            as int;
    expect(total, lessThanOrEqualTo(1000), reason: 'other media make room');
    // It still expires like everything else.
    now = now.add(const Duration(days: 31));
    expect(await media.getFile(unsent), isNull);
  });
}

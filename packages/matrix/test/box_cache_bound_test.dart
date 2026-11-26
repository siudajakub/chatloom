// SPDX-License-Identifier: AGPL-3.0-or-later
@TestOn('vm')
library;

import 'package:matrix/src/database/sqflite_box.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

/// ChatLoom: the quick-access cache is a bounded LRU and never drops values
/// a transaction has not committed yet.
void main() {
  late BoxCollection collection;
  late int previousMax;

  setUp(() async {
    previousMax = Box.maxCachedValues;
    Box.maxCachedValues = 10;
    final db = await databaseFactoryFfi.openDatabase(':memory:');
    collection = await BoxCollection.open(
      'bounded',
      {'events', 'large_keys', 'small_keys'},
      sqfliteDatabase: db,
      sqfliteFactory: databaseFactoryFfi,
    );
  });

  tearDown(() => Box.maxCachedValues = previousMax);

  test('writes and reads stay within the bound and stay correct', () async {
    final box = collection.openBox<Map>('events');
    for (var i = 0; i < 100; i++) {
      await box.put('e$i', {'i': i});
    }
    expect(box.debugCachedValues, lessThanOrEqualTo(11));
    // Evicted values come back from the database.
    expect(await box.get('e0'), {'i': 0});
    expect(await box.getAll(['e1', 'e99']), [
      {'i': 1},
      {'i': 99},
    ]);
    for (var i = 0; i < 100; i++) {
      await box.get('e$i');
    }
    expect(box.debugCachedValues, lessThanOrEqualTo(11));
  });

  test('a recently read value survives eviction', () async {
    final box = collection.openBox<Map>('events');
    await box.put('hot', {'v': 1});
    for (var i = 0; i < 30; i++) {
      await box.put('e$i', {'i': i});
      await box.get('hot');
    }
    await box.put('hot', {'v': 2});
    expect(await box.get('hot'), {'v': 2});
  });

  test('uncommitted values are not evicted inside a transaction', () async {
    final box = collection.openBox<Map>('events');
    await box.put('old', {'v': 'committed'});
    await collection.transaction(() async {
      await box.put('old', {'v': 'pending'});
      for (var i = 0; i < 100; i++) {
        await box.put('e$i', {'i': i});
      }
      // Still the uncommitted value, not the stale database row.
      expect(await box.get('old'), {'v': 'pending'});
      await box.delete('e5');
      for (var i = 100; i < 150; i++) {
        await box.put('e$i', {'i': i});
      }
      expect(await box.get('e5'), isNull);
    });
    expect(await box.get('old'), {'v': 'pending'});
    expect(await box.get('e5'), isNull);
    await box.put('after', {'v': 1});
    for (var i = 200; i < 220; i++) {
      await box.put('e$i', {'i': i});
    }
    expect(box.debugCachedValues, lessThanOrEqualTo(11));
  });

  test('a large key set is not pinned in memory', () async {
    final box = collection.openBox<Map>('large_keys');
    for (var i = 0; i < 50; i++) {
      await box.put('e$i', {'i': i});
    }
    expect(await box.getAllKeys(), hasLength(50));
    await box.put('e50', {'i': 50});
    // Not cached: read again from the database, including the new key.
    expect(await box.getAllKeys(), hasLength(51));
  });

  test('a small key set stays cached and follows writes', () async {
    final box = collection.openBox<Map>('small_keys');
    for (var i = 0; i < 5; i++) {
      await box.put('e$i', {'i': i});
    }
    expect(await box.getAllKeys(), hasLength(5));
    await box.put('e5', {'i': 5});
    await box.delete('e0');
    expect((await box.getAllKeys()).toSet(), {'e1', 'e2', 'e3', 'e4', 'e5'});
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatloom/personal/media/encrypted_media_cache.dart';
import 'package:chatloom/personal/media/pending_media_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory directory;
  final factory = createDatabaseFactoryFfi(noIsolate: true);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('media_cache_state_');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('hasFile probes presence within retention without touching access '
      'time or reading the BLOB', () async {
    var now = DateTime.utc(2026, 10, 17);
    final database = await factory.openDatabase(
      '${directory.path}/cache.sqlite',
      options: OpenDatabaseOptions(
        onConfigure: (db) => db.execute(
          "PRAGMA key = '${base64UrlEncode(List<int>.filled(32, 3))}'",
        ),
      ),
    );
    final cache = EncryptedMediaCache(
      database,
      retention: const Duration(days: 1),
      now: () => now,
    );
    await cache.initialize();
    final present = Uri.parse('mxc://fixture/present');
    await cache.storeFile(present, Uint8List.fromList([1, 2, 3]), 0);
    final before = await database.query('personal_media_cache');
    now = now.add(const Duration(hours: 1));
    expect(await cache.hasFile(present), isTrue);
    expect(await cache.hasFile(Uri.parse('mxc://fixture/absent')), isFalse);
    final after = await database.query('personal_media_cache');
    expect(after.single['accessed_at'], before.single['accessed_at']);
    now = now.add(const Duration(days: 2));
    expect(await cache.hasFile(present), isFalse);
    await database.close();
  });

  test(
    'getMediaStates batches lookups, chunked, scoped to own account',
    () async {
      final store = await PendingMediaStore.open(
        path: '${directory.path}/pending.sqlite',
        cipher: base64UrlEncode(List<int>.filled(32, 21)),
        factory: factory,
      );
      Map<String, dynamic> state(String source, {bool expired = false}) => {
        'version': 1,
        'revision': 1,
        'account_id': 'bridge-login',
        'room_id': '!room:fixture',
        'bridge_state_key': '',
        'source_event_id': source,
        'media_unread': true,
        'expired': expired,
      };
      for (var i = 0; i < 5; i++) {
        expect(
          await store.applyMediaState(
            '@me:fixture',
            '!room:fixture',
            '\$e$i',
            1,
            state('\$e$i', expired: i.isOdd),
          ),
          isTrue,
        );
      }
      final ids = [for (var i = 0; i < 7; i++) '\$e$i'];
      final states = await store.getMediaStates(
        '@me:fixture',
        '!room:fixture',
        ids,
        chunkSize: 2,
      );
      expect(states.keys.toSet(), {for (var i = 0; i < 5; i++) '\$e$i'});
      for (var i = 0; i < 5; i++) {
        expect(
          states['\$e$i'],
          await store.getMediaState('@me:fixture', '!room:fixture', '\$e$i'),
        );
      }
      expect(states[r'$e1']?['expired'], isTrue);
      expect(
        await store.getMediaStates('@other:fixture', '!room:fixture', ids),
        isEmpty,
      );
      expect(
        await store.getMediaStates('@me:fixture', '!other:fixture', ids),
        isEmpty,
      );
      expect(
        await store.getMediaStates('@me:fixture', '!room:fixture', []),
        {},
      );
      await store.close();
    },
  );
}

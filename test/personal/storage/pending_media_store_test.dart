// SPDX-License-Identifier: AGPL-3.0-or-later
// Run in SQLCipher-hook isolated harness.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../../lib/personal/media/pending_media_store.dart';
import '../../../lib/personal/storage/storage_failure.dart';

void check(bool condition, String reason) {
  if (!condition) throw StateError(reason);
}

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('round_pending_fixture_');
  final path = '${dir.path}/pending.sqlite';
  final key = base64UrlEncode(List<int>.filled(32, 21));
  final factory = createDatabaseFactoryFfi(noIsolate: true);
  Future<PendingMediaStore> open() => PendingMediaStore.open(
    path: path,
    cipher: key,
    factory: factory,
    maxStoreBytes: 24 * 1024 * 1024,
  );
  try {
    final unkeyed = await factory.openDatabase('${dir.path}/unkeyed.sqlite');
    try {
      await PendingMediaStore(unkeyed).initialize();
      throw StateError('Unkeyed SQLCipher accepted');
    } on StorageFailure catch (e) {
      check(
        e.code == StorageFailureCode.encryptionUnavailable,
        'Unkeyed failure code',
      );
    }
    check(
      (await unkeyed.rawQuery(
        "SELECT name FROM sqlite_master WHERE name = 'personal_pending_media'",
      )).isEmpty,
      'Unkeyed database modified',
    );
    await unkeyed.close();
    var store = await open();
    final bytes = Uint8List(11 * 1024 * 1024);
    bytes.setAll(0, utf8.encode('round_pending_protected_canary_20261012'));
    PendingMediaRecord record(String id, Uint8List b) => PendingMediaRecord(
      actionId: id,
      bytes: b,
      metadata: {
        'schema': 1,
        'accountId': 'a',
        'deviceId': 'd',
        'target': {'roomId': 'r'},
        'descriptor': {'size': b.length},
        'transactionId': 'round-$id',
        'state': 'staged',
      },
    );
    await store.stage(record('big', bytes));
    check(
      (await store.get('big'))!.bytes.length > 10000000,
      'Over-10MB media was silently omitted',
    );
    final initial = (await store.get('big'))!;
    try {
      initial.bytes[0] = 0;
      throw StateError('Mutable raw bytes');
    } on UnsupportedError {
      /* frozen */
    }
    try {
      await store.stage(record('big', bytes));
      throw StateError('Duplicate identity');
    } on PendingMediaFailure catch (e) {
      check(e.code == 'actionIdAlreadyUsed', 'Wrong duplicate reason');
    }
    await store.put(
      PendingMediaRecord(
        actionId: initial.actionId,
        metadata: {
          ...initial.metadata,
          'state': 'encrypted',
          'fileDescriptor': {'fixture': true},
        },
        bytes: initial.bytes,
        encryptedBytes: Uint8List.fromList(initial.bytes),
      ),
    );
    final summaries = await store.listSummaries(accountId: 'a', deviceId: 'd');
    check(
      summaries.length == 1 &&
          summaries.single.actionId == 'big' &&
          summaries.single.storedBytes == 2 * bytes.length,
      'Summary totals/identity diverged from BLOB storage',
    );
    check(
      jsonEncode(summaries.single.metadata).length < 4096,
      'Summary metadata contains media payload',
    );
    try {
      (summaries.single as dynamic).bytes;
      throw StateError('Summary exposes raw BLOB');
    } on NoSuchMethodError {
      /* summary intentionally has no bytes field */
    }
    try {
      (summaries.single as dynamic).encryptedBytes;
      throw StateError('Summary exposes cipher BLOB');
    } on NoSuchMethodError {
      /* summary intentionally has no cipher field */
    }
    check(
      (await store.listSummaries(accountId: 'a', deviceId: 'foreign')).isEmpty,
      'Summary device isolation failed',
    );
    try {
      await store.stage(record('extra', Uint8List(3 * 1024 * 1024)));
      throw StateError('Quota accepted');
    } on PendingMediaFailure catch (e) {
      check(e.code == 'storeQuota', 'Wrong quota reason');
    }
    check(
      await store.get('extra') == null && await store.get('big') != null,
      'Quota evicted pinned media',
    );
    check(
      (await store.list(accountId: 'foreign', deviceId: 'd')).isEmpty,
      'Account isolation failed',
    );
    final current = (await store.get('big'))!;
    try {
      await store.put(
        current.withMetadata({
          ...current.metadata,
          'target': {'roomId': 'retargeted'},
        }),
      );
      throw StateError('Retarget accepted');
    } on PendingMediaFailure catch (e) {
      check(e.code == 'immutableRecordMismatch', 'Wrong mutation reason');
    }
    await store.close();
    final disk = await File(path).readAsBytes();
    check(
      !latin1.decode(disk).contains('round_pending_protected_canary_20261012'),
      'Plaintext media on disk',
    );
    try {
      final wrong = await PendingMediaStore.open(
        path: path,
        cipher: base64UrlEncode(List<int>.filled(32, 22)),
        factory: factory,
      );
      await wrong.close();
      throw StateError('Wrong cipher accepted');
    } on StorageFailure {
      /* fail-closed */
    }
    check(
      base64Encode(await File(path).readAsBytes()) == base64Encode(disk),
      'Wrong key changed original',
    );
    store = await open();
    check(
      (await store.get('big'))!.bytes.length == bytes.length,
      'Restart lost media',
    );
    final accepted = (await store.get('big'))!;
    await store.put(
      accepted.withMetadata({
        ...accepted.metadata,
        'state': 'completed',
        'bridgeDelivery': 'delivered',
      }),
    );
    final completed = (await store.get('big'))!;
    await store.put(
      PendingMediaRecord(
        actionId: 'big',
        bytes: Uint8List(0),
        metadata: {...completed.metadata, 'bytesReleased': true},
      ),
    );
    check(
      (await store.get('big'))!.storedBytes == 0,
      'Known delivery cleanup failed',
    );
    check(
      (await store.listSummaries(
            accountId: 'a',
            deviceId: 'd',
          )).single.storedBytes ==
          0,
      'Tombstone summary retained stale quota',
    );
    await store.stage(record('extra', Uint8List(3 * 1024 * 1024)));
    Map<String, dynamic> state(
      int revision, {
      bool unread = false,
      bool expired = false,
    }) => {
      'version': 1,
      'revision': revision,
      'account_id': 'bridge-login',
      'room_id': '!room:fixture',
      'bridge_state_key': '',
      'source_event_id': r'$source',
      'media_unread': unread,
      'expired': expired,
    };
    check(
      await store.applyMediaState(
        'a',
        '!room:fixture',
        r'$source',
        2,
        state(2, expired: true),
      ),
      'Initial state not persisted',
    );
    check(
      !await store.applyMediaState(
        'a',
        '!room:fixture',
        r'$source',
        1,
        state(1),
      ),
      'Reordered revision accepted',
    );
    check(
      !await store.applyMediaState(
        'a',
        '!room:fixture',
        r'$source',
        2,
        state(2),
      ),
      'Duplicate revision accepted',
    );
    check(
      !await store.applyMediaState('a', '!room:fixture', r'$source', 3, {
        ...state(3),
        'account_id': 'foreign-login',
      }),
      'Source login retargeted',
    );
    check(
      await store.applyMediaState(
        'a',
        '!room:fixture',
        r'$source',
        3,
        state(3, unread: true),
      ),
      'New valid state rejected',
    );
    final consumed = await store.getMediaState(
      'a',
      '!room:fixture',
      r'$source',
    );
    check(
      consumed?['media_unread'] == false && consumed?['expired'] == true,
      'Played/expired state regressed',
    );
    check(
      await store.getMediaState('foreign', '!room:fixture', r'$source') == null,
      'Reverse state leaked across own accounts',
    );
    await store.close();
    store = await open();
    check(
      (await store.getMediaState(
            'a',
            '!room:fixture',
            r'$source',
          ))?['revision'] ==
          3,
      'Restart lost reverse played state',
    );
    // Corrupt one BLOB through the same authenticated fixture connection.
    final raw = await factory.openDatabase(path);
    await raw.update(
      'personal_pending_media',
      {
        'media': Uint8List.fromList([9]),
      },
      where: 'action_id = ?',
      whereArgs: ['extra'],
    );
    try {
      await store.get('extra');
      throw StateError('Corruption returned bytes');
    } on PendingMediaFailure catch (e) {
      check(e.code == 'integrityFailure', 'Wrong integrity code');
    }
    await store.close();
    stdout.writeln(
      'PASS SQLCipher pending >10MB, immutable BLOB/target, pinned quota, '
      'unkeyed denial, restart/canary/wrong-key preservation, delivered cleanup, '
      'monotonic source-bound played state and corruption denial',
    );
  } finally {
    await dir.delete(recursive: true);
  }
}

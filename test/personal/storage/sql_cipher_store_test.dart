// SPDX-License-Identifier: AGPL-3.0-or-later
// Run in an isolated Dart package with sqflite_common_ffi and sqlite3's
// SQLCipher hook to avoid unrelated Flutter/webcrypto/Xcode build hooks.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../lib/personal/media/encrypted_media_cache.dart';
import '../../../lib/personal/storage/sql_cipher_json_database.dart';
import '../../../lib/personal/storage/storage_failure.dart';

void check(bool condition, String label) {
  if (!condition) throw StateError(label);
}

Future<void> main() async {
  final temp = await Directory.systemTemp.createTemp('sqlcipher_regression_');
  final key = base64UrlEncode(List<int>.filled(32, 11));
  final wrongKey = base64UrlEncode(List<int>.filled(32, 12));
  final path = '${temp.path}/test.sqlite';
  final factory = createDatabaseFactoryFfi(noIsolate: true);
  try {
    var db = await SqlCipherJsonDatabase.open(
      path: path,
      cipher: key,
      factory: factory,
    );
    const canary = 'plaintext_canary_draft_998761';
    await db.put('draft/room', {'text': canary, 'revision': 1});
    await db.put('draft/room', {'text': canary, 'revision': 2});
    await db.put('job%_/1', {'status': 'queued'});
    await db.put('jobxx/2', {'status': 'queued'});
    await db.put('🎙️/one', {'status': 'done'});
    check((await db.get('draft/room'))?['revision'] == 2, 'Update failed');
    check(await db.get('missing') == null, 'Missing item');
    check((await db.readPrefix('job%_/')).length == 1, 'Prefix wildcard');
    check((await db.readPrefix('🎙️/')).length == 1, 'Unicode prefix');
    check((await db.readPrefix('')).length == 4, 'Empty prefix');
    await db.delete('jobxx/2');
    check(await db.get('jobxx/2') == null, 'Delete failed');
    await db.close();

    var now = DateTime.utc(2026, 10, 4);
    final mediaPath = '${temp.path}/media.sqlite';
    final raw = await factory.openDatabase(
      mediaPath,
      options: OpenDatabaseOptions(
        onConfigure: (db) async {
          await db.execute("PRAGMA key = '$key'");
        },
      ),
    );
    final journalMode = await raw.rawQuery('PRAGMA journal_mode = WAL');
    check(journalMode.first.values.first == 'wal', 'WAL mode unavailable');
    final media = EncryptedMediaCache(
      raw,
      maxFileSize: 30,
      maxCacheBytes: 35,
      retention: const Duration(days: 1),
      now: () => now,
    );
    await media.initialize();
    final a = Uri.parse('mxc://fixture/a');
    final b = Uri.parse('mxc://fixture/b');
    final c = Uri.parse('mxc://fixture/c');
    final marker = Uint8List.fromList(utf8.encode('media_canary_bytes_12345'));
    await media.storeFile(a, marker, 0);
    final wal = File('${mediaPath}-wal');
    check(await wal.exists(), 'WAL evidence missing');
    check(!latin1.decode(await wal.readAsBytes()).contains('media_canary_bytes_12345'), 'Plaintext media in WAL');
    check(
      base64Encode((await media.getFile(a))!) == base64Encode(marker),
      'Media bytes changed',
    );
    now = now.add(const Duration(seconds: 1));
    await media.storeFile(b, Uint8List(20), 0);
    check(await media.getFile(a) == null, 'Cache quota did not evict oldest');
    check(await media.getFile(b) != null, 'Cache evicted new file');
    await media.storeFile(c, Uint8List(31), 0);
    check(await media.getFile(c) == null, 'Oversize file cached');
    now = now.add(const Duration(days: 2));
    check(await media.getFile(b) == null, 'Expired file returned');
    await media.deleteOldFiles(0);
    check(await media.deleteFile(b) == false, 'Retention did not purge');
    await media.storeFile(a, marker, 0);
    check(await media.deleteFile(a) == true, 'Media delete failed');
    await media.storeFile(a, marker, 0);
    await media.clear();
    check(await media.getFile(a) == null, 'Clear cache retained media');
    await media.storeFile(a, marker, 0);
    await raw.close();
    check(
      !latin1
          .decode(await File(mediaPath).readAsBytes())
          .contains('media_canary_bytes_12345'),
      'Media plaintext on disk',
    );

    final original = await File(path).readAsBytes();
    check(
      !latin1.decode(original).contains(canary),
      'Plaintext stored on disk',
    );
    check(
      !latin1.decode(original).startsWith('SQLite format 3'),
      'Plaintext DB',
    );
    try {
      db = await SqlCipherJsonDatabase.open(
        path: path,
        cipher: wrongKey,
        factory: factory,
      );
      await db.close();
      throw StateError('Wrong key accepted');
    } on StorageFailure catch (error) {
      check(
        error.code == StorageFailureCode.databaseUnavailable,
        'Wrong key unsafe error',
      );
      check(!error.toString().contains(wrongKey), 'Key escaped');
    }
    check(
      base64Encode(await File(path).readAsBytes()) == base64Encode(original),
      'Wrong key changed database',
    );
    db = await SqlCipherJsonDatabase.open(
      path: path,
      cipher: key,
      factory: factory,
    );
    check(
      (await db.get('draft/room'))?['text'] == canary,
      'Restart lost draft',
    );
    await db.close();

    final legacyPath = '${temp.path}/plain.sqlite';
    final legacy = await factory.openDatabase(legacyPath);
    await legacy.execute('CREATE TABLE legacy_data (text TEXT)');
    await legacy.insert('legacy_data', {'text': canary});
    await legacy.close();
    final legacyBytes = await File(legacyPath).readAsBytes();
    try {
      await SqlCipherJsonDatabase.open(
        path: legacyPath,
        cipher: key,
        factory: factory,
      );
      throw StateError('Plaintext legacy accepted');
    } on StorageFailure catch (error) {
      check(
        error.code == StorageFailureCode.legacyMigrationRequired,
        'Legacy failure code',
      );
    }
    check(
      base64Encode(await File(legacyPath).readAsBytes()) ==
          base64Encode(legacyBytes),
      'Legacy changed',
    );
    stdout.writeln(
      'PASS native SQLCipher CRUD, restart, prefixes, canary, '
      'wrong-key preservation, legacy preservation, media quota and retention',
    );
  } finally {
    await temp.delete(recursive: true);
  }
}

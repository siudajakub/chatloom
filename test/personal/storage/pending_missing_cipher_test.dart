// SPDX-License-Identifier: AGPL-3.0-or-later
// Run with plain sqlite3 hook, not SQLCipher.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:convert';
import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../../lib/personal/media/pending_media_store.dart';
import '../../../lib/personal/storage/storage_failure.dart';

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('round_missing_cipher_');
  try {
    try {
      final store = await PendingMediaStore.open(
        path: '${dir.path}/pending.sqlite',
        cipher: base64UrlEncode(List<int>.filled(32, 31)),
        factory: createDatabaseFactoryFfi(noIsolate: true),
      );
      await store.close();
      throw StateError('Plain SQLite accepted durable pending media');
    } on StorageFailure catch (e) {
      if (e.code != StorageFailureCode.encryptionUnavailable) {
        throw StateError('Unexpected fail-closed code');
      }
    }
    stdout.writeln('PASS pending-media ordinary SQLite fails closed');
  } finally {
    await dir.delete(recursive: true);
  }
}

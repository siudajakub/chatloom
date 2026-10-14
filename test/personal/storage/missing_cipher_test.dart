// SPDX-License-Identifier: AGPL-3.0-or-later
// Run with sqlite3 hook source: sqlite3 (not sqlcipher).
// ignore_for_file: avoid_relative_lib_imports

import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../lib/personal/storage/sql_cipher_json_database.dart';
import '../../../lib/personal/storage/storage_failure.dart';

Future<void> main() async {
  final temp = await Directory.systemTemp.createTemp('missing_cipher_');
  try {
    try {
      final store = await SqlCipherJsonDatabase.open(
        path: '${temp.path}/protected.sqlite',
        cipher: base64UrlEncode(List<int>.filled(32, 3)),
        factory: createDatabaseFactoryFfi(noIsolate: true),
      );
      await store.close();
      throw StateError('Ordinary SQLite accepted for protected storage');
    } on StorageFailure catch (failure) {
      if (failure.code != StorageFailureCode.encryptionUnavailable) {
        throw StateError('Expected encryptionUnavailable');
      }
    }
    stdout.writeln('PASS ordinary SQLite fails closed without personal schema');
  } finally {
    await temp.delete(recursive: true);
  }
}

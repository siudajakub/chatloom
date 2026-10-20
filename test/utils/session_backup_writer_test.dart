// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/utils/init_with_restore.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingStorage implements FlutterSecureStorage {
  final values = <String, String>{};
  final log = <String>[];
  Completer<void>? writeGate;
  Object? failWrite;

  Future<void> _write(String key, String? value) async {
    log.add('write');
    await writeGate?.future;
    if (failWrite != null) throw failWrite!;
    values[key] = value!;
  }

  // The plugin API has per-platform option parameters; only the key/value
  // contract matters here.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.namedArguments[#key] as String;
    switch (invocation.memberName) {
      case #read:
        log.add('read');
        return Future<String?>.value(values[key]);
      case #write:
        return _write(key, invocation.namedArguments[#value] as String?);
      case #delete:
        log.add('delete');
        values.remove(key);
        return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  const key = 'synthetic_session_backup';

  test('an unchanged backup is read but not rewritten', () async {
    final storage = _RecordingStorage()..values[key] = 'same';
    await SessionBackupWriter.write(storage, key, 'same');
    expect(storage.log, ['read']);
    await SessionBackupWriter.write(storage, key, 'changed');
    expect(storage.log, ['read', 'read', 'write']);
    expect(storage.values[key], 'changed');
  });

  test('a logout delete lands after an in-flight startup write', () async {
    final storage = _RecordingStorage()..writeGate = Completer<void>();
    final write = SessionBackupWriter.write(storage, key, 'session');
    final delete = SessionBackupWriter.delete(storage, key);
    await Future<void>.delayed(Duration.zero);
    expect(storage.log, ['read', 'write']);
    storage.writeGate!.complete();
    await Future.wait([write, delete]);
    expect(storage.log, ['read', 'write', 'delete']);
    expect(storage.values.containsKey(key), isFalse);
    await SessionBackupWriter.settled(key);
  });

  test('a failed write is contained and does not block later work', () async {
    final storage = _RecordingStorage()..failWrite = StateError('keystore');
    await SessionBackupWriter.write(storage, key, 'session');
    storage.failWrite = null;
    await SessionBackupWriter.write(storage, key, 'session');
    expect(storage.values[key], 'session');
  });
}

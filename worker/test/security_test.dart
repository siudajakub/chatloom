// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'package:matrix/matrix.dart';
import 'package:personal_worker/src/config.dart';
import 'package:personal_worker/src/runtime.dart';
import 'package:test/test.dart';

void main() {
  test('SQLCipher at-rest unreadable and wrong key preserves file', () {
    final temp = Directory.systemTemp.createTempSync('worker-encrypted-test-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final file = '${temp.path}/database.sqlite';
    final db = encryptedDatabase(file, 'a' * 64);
    db.execute('CREATE TABLE secret (value TEXT)');
    db.execute('INSERT INTO secret VALUES (?)', ['synthetic_private_fixture']);
    db.close();
    final original = File(file).readAsBytesSync();
    expect(
      String.fromCharCodes(original),
      isNot(contains('synthetic_private_fixture')),
    );
    expect(() => encryptedDatabase(file, 'b' * 64), throwsA(anything));
    expect(File(file).readAsBytesSync(), original);
    final restored = encryptedDatabase(file, 'a' * 64);
    expect(
      restored.select('SELECT value FROM secret').first['value'],
      'synthetic_private_fixture',
    );
    restored.close();
  });
  test('SDK diagnostic sanitized before buffer', () {
    sanitizeLogs();
    Logs().outputEvents.clear();
    Logs().v('SYNTHETIC_SECRET', Exception('SYNTHETIC_MESSAGE'));
    expect(
      Logs().outputEvents.any(
        (e) => e.toFormattedString().contains('SYNTHETIC'),
      ),
      isFalse,
    );
  });
}

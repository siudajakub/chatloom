// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'package:personal_worker/src/config.dart';
import 'package:personal_worker/src/store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import '../bin/migrate.dart' as migration;

void main() {
  test(
    'dry run no writes; apply encrypted backup and explicit mapping only',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'worker-migration-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final sourcePath = '${directory.path}/legacy.sqlite';
      final source = sqlite3.open(sourcePath);
      source.execute(
        'CREATE TABLE transcripts(chat_id TEXT,message_id TEXT,text TEXT,status TEXT)',
      );
      source.execute('INSERT INTO transcripts VALUES (?,?,?,?)', [
        'synthetic-chat',
        '1',
        'synthetic-secret',
        'done',
      ]);
      source.execute('INSERT INTO transcripts VALUES (?,?,?,?)', [
        'unmapped',
        '2',
        'synthetic-unmapped',
        'done',
      ]);
      source.close();
      final original = File(sourcePath).readAsBytesSync();
      final mapping = '${directory.path}/mapping.json';
      File(mapping).writeAsStringSync(
        jsonEncode([
          {
            'legacy': {'chatId': 'synthetic-chat', 'messageId': '1'},
            'source': {
              'conversation': {
                'accountId': '@self:example.invalid',
                'roomId': '!synthetic:example.invalid',
              },
              'eventId': r'$synthetic',
            },
          },
        ]),
      );
      final credentials = '${directory.path}/credentials.json';
      File(
        credentials,
      ).writeAsStringSync(jsonEncode({'databaseCipher': 'c' * 64}));
      await Process.run('chmod', ['600', credentials]);
      final config = '${directory.path}/config.json';
      File(config).writeAsStringSync(
        jsonEncode({
          'stateDirectory': '${directory.path}/state',
          'temporaryDirectory': '${directory.path}/audio',
          'credentialsPath': credentials,
          'journalRoomId': '',
          'trustedDeviceIds': [],
        }),
      );
      await migration.main([sourcePath, mapping, config]);
      expect(Directory('${directory.path}/state').existsSync(), isFalse);
      await migration.main([sourcePath, mapping, config, '--apply']);
      expect(exitCode, 0);
      expect(File(sourcePath).readAsBytesSync(), original);
      final backup = Directory(
        '${directory.path}/state',
      ).listSync().singleWhere((file) => file.path.contains('legacy-backup'));
      expect(
        String.fromCharCodes(File(backup.path).readAsBytesSync()),
        isNot(contains('synthetic-secret')),
      );
      final restored = encryptedDatabase(backup.path, 'c' * 64);
      expect(restored.select('SELECT * FROM transcripts'), hasLength(2));
      restored.close();
      final store = WorkerStore(
        encryptedDatabase('${directory.path}/state/jobs.sqlite', 'c' * 64),
      );
      expect(store.jobs(), hasLength(1));
      expect(store.outbox, hasLength(1));
      store.close();
    },
  );
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:personal_worker/src/config.dart';
import 'package:personal_worker/src/ports.dart';

void main() {
  test('deployment example selects private prepared runtime credential', () {
    final config = WorkerConfig.read('config.example.json');
    expect(config.credentialsPath, '/run/personal-worker/credentials.json');
    expect(config.allowConversationSends, isFalse);
    // Automatic work stays off until the operator opts in; once on, cloud
    // rooms come from the worker's own sync unless explicitly disabled.
    expect(config.autoTranscription, isFalse);
    expect(config.autoTranscriptionMatrix, isTrue);
  });

  test(
    'owner-only credential policy still refuses systemd group-readable input',
    () {
      final temporary = Directory.systemTemp.createTempSync('worker-config-');
      addTearDown(() => temporary.deleteSync(recursive: true));
      final credential = File('${temporary.path}/credentials.json');
      credential.writeAsStringSync(jsonEncode({'databaseCipher': 'a' * 64}));
      final config = WorkerConfig(
        stateDirectory: temporary.path,
        temporaryDirectory: temporary.path,
        credentialsPath: credential.path,
        journalRoomId: '',
        trustedDeviceIds: const [],
        nativeLibraryDirectory: temporary.path,
      );
      expect(Process.runSync('chmod', ['0440', credential.path]).exitCode, 0);
      expect(() => readCredentials(config), throwsA(isA<WorkerFailure>()));
      expect(Process.runSync('chmod', ['0600', credential.path]).exitCode, 0);
      expect(readCredentials(config)['databaseCipher'], 'a' * 64);
    },
  );
}

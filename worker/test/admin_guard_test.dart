// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personal_worker/src/admin_guard.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:test/test.dart';

void main() {
  test(
    'only encrypted journal events pass; chat sends/activity never reach transport',
    () async {
      var reached = 0;
      final client = JournalAdminHttpClient(
        inner: MockClient((_) async {
          reached++;
          return http.Response('{}', 200);
        }),
      )..journals.add('!private:example.invalid');
      addTearDown(client.close);
      for (final endpoint in [
        'rooms/!friend:example.invalid/send/m.room.encrypted/1',
        'rooms/!private:example.invalid/send/m.room.message/1',
        'rooms/!friend:example.invalid/receipt/m.read/event',
        'rooms/!friend:example.invalid/read_markers',
        'rooms/!friend:example.invalid/typing/user',
        'presence/user/status',
        'join/!friend:example.invalid',
      ]) {
        await expectLater(
          client.post(
            Uri.parse('https://example.invalid/_matrix/client/v3/$endpoint'),
          ),
          throwsA(isA<WorkerFailure>()),
        );
      }
      expect(reached, 0);
      await client.put(
        Uri.parse(
          'https://example.invalid/_matrix/client/v3/rooms/!private:example.invalid/send/m.room.encrypted/1',
        ),
      );
      expect(reached, 1);
      expect(client.encryptedJournalWrites, 1);
    },
  );
  test('journal creation rejects invitations and missing encryption', () async {
    var reached = 0;
    final client = JournalAdminHttpClient(
      inner: MockClient((_) async {
        reached++;
        return http.Response('{}', 200);
      }),
    );
    addTearDown(client.close);
    final body = {
      'preset': 'private_chat',
      'creation_content': {'m.federate': false},
      'initial_state': [
        {
          'type': 'm.room.encryption',
          'content': {'algorithm': 'm.megolm.v1.aes-sha2'},
        },
        {
          'type': 'pl.personal.client.journal.v1',
          'content': {'schema': 1},
        },
      ],
    };
    final url = Uri.parse(
      'https://example.invalid/_matrix/client/v3/createRoom',
    );
    await expectLater(
      client.post(
        url,
        body: jsonEncode({
          ...body,
          'invite': ['@friend:example.invalid'],
        }),
      ),
      throwsA(isA<WorkerFailure>()),
    );
    await expectLater(
      client.post(url, body: jsonEncode({...body, 'initial_state': []})),
      throwsA(isA<WorkerFailure>()),
    );
    expect(reached, 0);
    await client.post(url, body: jsonEncode(body));
    expect(reached, 1);
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/matrix_transport.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:test/test.dart';

class UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected database access');
}

void main() {
  test(
    'transcription deployment refuses chat sends and receipts before session access',
    () async {
      final client = Client('no sends fixture', database: UnusedDatabase());
      final transport = MatrixFeatureTransport(
        client,
        allowConversationSends: false,
      );
      const target = SendTarget(
        conversation: ConversationRef(
          accountId: '@fixture:example.invalid',
          roomId: '!fixture:example.invalid',
        ),
      );
      final refusal = throwsA(
        isA<WorkerFailure>().having(
          (e) => e.code,
          'code',
          'conversation_sends_disabled',
        ),
      );
      await expectLater(
        transport.send(target, {
          'msgtype': 'm.text',
          'body': 'fixture',
        }, 'fixture'),
        refusal,
      );
      await expectLater(transport.readAfterAcceptedReply(target), refusal);
    },
  );
}

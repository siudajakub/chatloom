// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';
import 'package:personal_worker/src/journal_ready.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:test/test.dart';

class UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected database access');
}

class JournalClient extends Client {
  Room? selected;
  JournalClient() : super('journal fixture', database: UnusedDatabase());
  @override
  Room? getRoomById(String id) => selected;
}

void main() {
  test('an already synced journal needs no further sync event', () async {
    final client = JournalClient();
    client.selected = Room(id: '!fixture:example.invalid', client: client);
    expect(
      await waitForJoinedJournal(
        client,
        client.selected!.id,
        timeout: const Duration(milliseconds: 50),
      ),
      same(client.selected),
    );
  });
  test(
    'missing journal fails closed without joining or recreating rooms',
    () async {
      await expectLater(
        waitForJoinedJournal(
          JournalClient(),
          '!missing:example.invalid',
          timeout: Duration.zero,
        ),
        throwsA(isA<WorkerFailure>()),
      );
    },
  );
}

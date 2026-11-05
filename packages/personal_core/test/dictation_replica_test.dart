// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'package:personal_core/personal_core.dart';
import 'package:test/test.dart';

final at = DateTime.utc(2026, 11, 5, 12);
void main() {
  group('durable dictation cancellation', () {
    late Map<String, Map<String, dynamic>> records;
    var sequence = 0;
    late PersonalReplica replica;
    PersonalReplica restore() => PersonalReplica(
      read: (key) async => records[key],
      write: (key, value) async {
        records[key] = Map<String, dynamic>.from(
          jsonDecode(jsonEncode(value)) as Map,
        );
      },
      newOperationId: () => 'fixture-${sequence++}',
      clock: () => at,
    )..restore(records);
    Future<PersonalOperation> stage() => replica.stageCommand(
      'dictation.request',
      'dictation-fixture04',
      {'id': 'dictation-fixture04'},
      optimisticJob: {'id': 'dictation-fixture04', 'state': 'waitingSync'},
    );
    PersonalOperation ack(
      PersonalOperation op,
      String state,
      int revision, {
      String? errorCode,
    }) => PersonalOperation(
      opId: 'ack-${sequence++}',
      kind: 'dictation.result',
      entityId: op.entityId,
      baseRevision: revision,
      createdAt: at,
      payload: {
        'state': state,
        'revision': revision,
        'acceptedOpId': op.opId,
        if (errorCode != null) 'errorCode': errorCode,
      },
    );
    setUp(() {
      records = {};
      sequence = 0;
      replica = restore();
    });

    test(
      'unpublished request is withdrawn without later reconnect spend',
      () async {
        await stage();
        expect(
          await replica.cancelDictation('dictation-fixture04'),
          TranscriptCancellation.cancelledLocally,
        );
        final restarted = restore();
        expect(restarted.pending, isEmpty);
        expect(
          restarted.dictations['dictation-fixture04']?['state'],
          'cancelled',
        );
      },
    );

    test(
      'published request cancellation survives restart and waits for ACK',
      () async {
        final request = await stage();
        await replica.markPublishing(request.opId);
        expect(
          await replica.cancelDictation(request.entityId),
          TranscriptCancellation.waitingAcknowledgement,
        );
        replica = restore();
        await replica.acceptResult(ack(request, 'processing', 1));
        final cancellation = replica.pending.values.single;
        expect(cancellation.kind, 'dictation.cancel');
        expect(cancellation.baseRevision, 1);
        await replica.acceptResult(ack(cancellation, 'cancelled', 2));
        expect(restore().pending, isEmpty);
      },
    );

    test(
      'refused cancellation ends instead of generating endless commands',
      () async {
        final request = await stage();
        await replica.markPublishing(request.opId);
        await replica.cancelDictation(request.entityId);
        await replica.acceptResult(ack(request, 'processing', 1));
        final cancellation = replica.pending.values.single;
        await replica.acceptResult(
          ack(cancellation, 'conflict', 1, errorCode: 'not_found'),
        );
        expect(replica.pending, isEmpty);
      },
    );
  });
}

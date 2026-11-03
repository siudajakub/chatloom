// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:personal_core/personal_core.dart';
import 'package:test/test.dart';

const conversation = ConversationRef(
  accountId: '@fixture:example.invalid',
  roomId: '!group:example.invalid',
);
final at = DateTime.utc(2026, 11, 3, 10);
SummarySource source(String text) => SummarySource(
  complete: true,
  messages: [
    SummaryMessage(timestamp: at, sender: 'Participant 1', text: text),
  ],
);

void main() {
  test(
    'Unicode source chunks round-trip below journal limits with a digest',
    () {
      final original = source(List.filled(5000, 'Zażółć 👋 „cytat”').join());
      final upload = SummaryUpload.create(
        id: 'summary:fixture01',
        conversation: conversation,
        request: const SummaryRequest(),
        source: original,
      );
      expect(upload.parts.length, greaterThan(1));
      final joined = upload.parts.map((p) => p['text'] as String).join();
      expect(
        SummarySource.fromJson(
          jsonDecode(joined) as Map<String, dynamic>,
        ).messages.single.text,
        original.messages.single.text,
      );
      expect(sha256Hex(utf8.encode(joined)), upload.manifest['sourceDigest']);
      for (final part in upload.parts) {
        expect(utf8.encode(jsonEncode(part)).length, lessThan(24500));
        expect(
          utf8.encode(part['text'] as String).length,
          lessThanOrEqualTo(SummaryUpload.partBytes),
        );
      }
    },
  );

  test('oversized whole history fails explicitly rather than trimming it', () {
    expect(
      () => SummaryUpload.create(
        id: 'summary:fixture02',
        conversation: conversation,
        request: const SummaryRequest(scope: SummaryScopeKind.all),
        source: source('x' * (SummaryUpload.maxSourceBytes + 1)),
      ),
      throwsA(
        isA<SummaryException>().having(
          (e) => e.code,
          'code',
          'source_too_large',
        ),
      ),
    );
  });

  test(
    'invalid amounts, language, input order and empty source are rejected',
    () {
      expect(const SummaryRequest(amount: 0).isValid, isFalse);
      expect(const SummaryRequest(language: 'xx').isValid, isFalse);
      expect(
        const SummaryRequest(
          scope: SummaryScopeKind.days,
          amount: 3651,
        ).isValid,
        isFalse,
      );
      final unordered = SummarySource(
        complete: true,
        messages: [
          SummaryMessage(timestamp: at, sender: 'Participant', text: 'Later'),
          SummaryMessage(
            timestamp: at.subtract(const Duration(hours: 1)),
            sender: 'Participant',
            text: 'Earlier',
          ),
        ],
      );
      expect(
        () => SummarySource.fromJson(unordered.toJson()),
        throwsA(isA<SummaryException>()),
      );
      expect(
        () => SummaryUpload.create(
          id: 'summary:fixture03',
          conversation: conversation,
          request: const SummaryRequest(),
          source: SummarySource(messages: [], complete: true),
        ),
        throwsA(
          isA<SummaryException>().having((e) => e.code, 'code', 'no_messages'),
        ),
      );
    },
  );

  test(
    'cancellation wakes every waiter once and throws a safe typed error',
    () async {
      final cancellation = SummaryCancellation();
      final wait = cancellation.whenCancelled;
      cancellation.cancel();
      cancellation.cancel();
      await wait;
      expect(cancellation.isCancelled, isTrue);
      expect(
        cancellation.throwIfCancelled,
        throwsA(isA<SummaryCancelledException>()),
      );
    },
  );

  group('durable summary cancellation', () {
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
      'summary.request',
      'summary:fixture04',
      {'id': 'summary:fixture04'},
      optimisticJob: {'id': 'summary:fixture04', 'state': 'waitingSync'},
    );
    PersonalOperation ack(
      PersonalOperation op,
      String state,
      int revision, {
      String? errorCode,
    }) => PersonalOperation(
      opId: 'ack-${sequence++}',
      kind: 'summary.result',
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
          await replica.cancelSummary('summary:fixture04'),
          TranscriptCancellation.cancelledLocally,
        );
        final restarted = restore();
        expect(restarted.pending, isEmpty);
        expect(restarted.summaries['summary:fixture04']?['state'], 'cancelled');
      },
    );

    test(
      'published request cancellation survives restart and waits for ACK',
      () async {
        final request = await stage();
        await replica.markPublishing(request.opId);
        expect(
          await replica.cancelSummary(request.entityId),
          TranscriptCancellation.waitingAcknowledgement,
        );
        replica = restore();
        expect(replica.summaryCancellations, contains(request.entityId));
        await replica.acceptResult(ack(request, 'processing', 1));
        final cancellation = replica.pending.values.single;
        expect(cancellation.kind, 'summary.cancel');
        expect(cancellation.baseRevision, 1);
        await replica.acceptResult(ack(cancellation, 'cancelled', 2));
        expect(restore().summaryCancellations, isEmpty);
        expect(restore().pending, isEmpty);
      },
    );

    test(
      'refused cancellation ends instead of generating endless commands',
      () async {
        final request = await stage();
        await replica.markPublishing(request.opId);
        await replica.cancelSummary(request.entityId);
        await replica.acceptResult(ack(request, 'processing', 1));
        final cancellation = replica.pending.values.single;
        await replica.acceptResult(
          ack(cancellation, 'conflict', 1, errorCode: 'not_found'),
        );
        expect(replica.pending, isEmpty);
        expect(replica.summaryCancellations, isEmpty);
      },
    );
  });
}

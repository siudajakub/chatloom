// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/personal_hub.dart';
import 'package:chatloom/personal/summary/summary_journal.dart';
import 'package:chatloom/personal/worker_readiness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_core/personal_core.dart';

import '../../notion/conversation_test_support.dart';

class _Personal extends PersonalClient {
  final entries = <String, Map<String, dynamic>>{};
  final calls = <String>[];
  bool available = true;
  void Function(String id)? onRequest;
  void Function()? onPart;
  _Personal(super.client)
    : super.forTesting(openStore: () async => throw StateError('Unused')) {
    workerReadiness = WorkerReadiness(
      receivedAt: DateTime.now(),
      healthy: true,
      verified: true,
      summary: 'ready',
      summaryVersion: 1,
    );
  }
  @override
  bool get ready => available;
  @override
  Map<String, Map<String, dynamic>> get summaries => entries;
  @override
  Future<void> put(String key, Map<String, dynamic> value) async {
    calls.add('part');
    onPart?.call();
  }

  @override
  Future<void> delete(String key) async {
    calls.add('delete');
  }

  @override
  Future<PersonalOperation> command(
    String kind,
    String entityId,
    Map<String, dynamic> payload, {
    int? baseRevision,
    Map<String, dynamic>? optimisticJob,
  }) async {
    calls.add(kind);
    onRequest?.call(entityId);
    return PersonalOperation(
      opId: 'fixture',
      kind: kind,
      entityId: entityId,
      payload: payload,
      baseRevision: 0,
      createdAt: DateTime.utc(2026),
    );
  }

  @override
  Future<TranscriptCancellation> cancelSummary(String id) async {
    calls.add('cancel');
    return TranscriptCancellation.queued;
  }
}

void main() {
  late _Personal personal;
  late SummaryCancellation cancellation;
  final at = DateTime.utc(2026, 11, 3);
  final conversation = ConversationRef(
    accountId: '@owner:example.invalid',
    roomId: '!fictional:example.invalid',
    network: 'matrix',
  );
  final source = SummarySource(
    messages: [
      SummaryMessage(timestamp: at, sender: 'Person 1', text: 'A topic'),
    ],
    complete: true,
  );
  setUp(() {
    personal = _Personal(ConversationClient());
    cancellation = SummaryCancellation();
  });
  tearDown(() => personal.dispose());

  Future<SummaryResult> run({bool Function()? current, Duration? timeout}) =>
      SummaryJournal(
        personal: personal,
        isCurrent: current ?? () => true,
        timeout: timeout ?? const Duration(seconds: 5),
      ).generate(
        conversation: conversation,
        request: const SummaryRequest(),
        source: source,
        cancellation: cancellation,
      );

  test('only groups opt into the summary menu entry', () {
    expect(
      conversationQuickActions().where((entry) => entry.value == 'summary'),
      isEmpty,
    );
    expect(
      conversationQuickActions(
        canSummarize: true,
      ).where((entry) => entry.value == 'summary'),
      hasLength(1),
    );
  });

  test(
    'an old or unconfigured worker never receives private source text',
    () async {
      personal.workerReadiness = WorkerReadiness(receivedAt: DateTime.now());
      await expectLater(run(), throwsA(isA<SummaryException>()));
      expect(personal.calls, isEmpty);
      personal.workerReadiness = WorkerReadiness(
        receivedAt: DateTime.now(),
        healthy: true,
        verified: true,
      );
      await expectLater(run(), throwsA(isA<SummaryException>()));
      expect(personal.calls, isEmpty);
    },
  );

  test(
    'source parts precede the request and only the private result returns',
    () async {
      personal.onRequest = (id) {
        personal.entries[id] = {
          'state': 'done',
          ...SummaryResult(
            text: 'Fictional summary',
            model: 'fixture/model',
            messageCount: 1,
            startedAt: at,
            endedAt: at,
            complete: true,
          ).toJson(),
        };
      };
      final result = await run();
      expect(result.text, 'Fictional summary');
      expect(personal.calls, ['part', 'summary.request']);
    },
  );

  test('cancel while collecting chunks never commits a paid request', () async {
    personal.onPart = cancellation.cancel;
    await expectLater(run(), throwsA(isA<SummaryCancelledException>()));
    expect(personal.calls, ['part', 'delete']);
  });

  test(
    'cancel while waiting records durable cancellation and removes chunks',
    () async {
      final started = Completer<void>();
      personal.onRequest = (_) => started.complete();
      final result = run();
      final assertion = expectLater(
        result,
        throwsA(isA<SummaryCancelledException>()),
      );
      await started.future;
      cancellation.cancel();
      await assertion;
      expect(personal.calls, ['part', 'summary.request', 'cancel', 'delete']);
    },
  );

  test('uncertain timeout never automatically retries the model', () async {
    await expectLater(
      run(timeout: const Duration(milliseconds: 1)),
      throwsA(
        isA<SummaryException>().having(
          (e) => e.code,
          'code',
          'summary_timeout',
        ),
      ),
    );
    expect(
      personal.calls.where((call) => call == 'summary.request'),
      hasLength(1),
    );
    expect(personal.calls, contains('cancel'));
  });

  test('stale account or locked surface stops before upload', () async {
    await expectLater(
      run(current: () => false),
      throwsA(isA<SummaryCancelledException>()),
    );
    expect(personal.calls, isEmpty);
  });

  test('summary readiness is explicitly allowlisted and affects equality', () {
    final ready = WorkerReadiness.fromPayload({
      'summary': 'ready',
      'summaryVersion': 1,
    }, at);
    final unknown = WorkerReadiness.fromPayload({
      'summary': 'invented',
      'summaryVersion': '1',
    }, at);
    expect(ready.summary, 'ready');
    expect(ready.summaryVersion, 1);
    expect(unknown.summary, isNull);
    expect(unknown.summaryVersion, isNull);
    expect(ready, isNot(unknown));
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:typed_data';
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/engine.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

const conversation = ConversationRef(
  accountId: '@self:example.invalid',
  roomId: '!synthetic:example.invalid',
);
final source = SourceEventRef(
  conversation: conversation,
  eventId: r'$synthetic',
);

class FakeTransport implements FeatureTransport {
  @override
  String accountId = conversation.accountId;
  @override
  String deviceId = 'TEST_DEVICE';
  @override
  bool verified = true;
  final List<String> sent = [];
  final List<String?> reads = [];
  bool failUnknown = false;
  Completer<void>? holdSend;
  bool receivedReply = false;
  bool? redacted = false;
  int sourceProbes = 0;
  int audioLoads = 0;
  Completer<bool?>? holdSourceProbe;
  Completer<void>? sourceProbeStarted;
  @override
  Future<bool?> sourceRedacted(SourceEventRef source) async {
    sourceProbes++;
    final started = sourceProbeStarted;
    if (started != null && !started.isCompleted) started.complete();
    if (holdSourceProbe != null) return holdSourceProbe!.future;
    return redacted;
  }

  String? replyHistoryFailure;
  @override
  Future<AudioSource> loadAudio(
    SourceEventRef source,
    Cancellation cancel,
  ) async {
    audioLoads++;
    // Distinct bytes per source: identical media would share a transcript.
    return AudioSource(
      Uint8List.fromList([1, 2, 3, ...source.eventId.codeUnits]),
      'audio/ogg',
    );
  }

  @override
  Future<String> send(
    SendTarget target,
    Map<String, dynamic> content,
    String transactionId,
  ) async {
    sent.add(transactionId);
    await holdSend?.future;
    if (failUnknown) throw const WorkerFailure('send_unknown');
    return r'$sent';
  }

  @override
  Future<void> readAfterAcceptedReply(SendTarget target) async {
    reads.add(target.readUpToEventId);
  }

  @override
  Future<bool> hasRepliedSince(
    ConversationRef conversation,
    DateTime since,
  ) async {
    replyChecks++;
    if (replyHistoryFailure != null) throw WorkerFailure(replyHistoryFailure!);
    return receivedReply;
  }

  int replyChecks = 0;
}

class FakeTranscriber implements Transcriber {
  int calls = 0;
  bool paidUnknown = false;
  Completer<void>? hold;
  @override
  Future<TranscriptionResult> transcribe(
    AudioSource audio,
    String? language,
    Cancellation cancel,
    void Function(double, double) estimate,
  ) async {
    calls++;
    estimate(60, 0.0045);
    await hold?.future;
    cancel.check();
    if (paidUnknown) throw const PaidRequestUnknown();
    return const TranscriptionResult('synthetic transcript', 60, 0.0045);
  }
}

PersonalOperation op(
  String id,
  String kind,
  String entity,
  Map<String, dynamic> payload, {
  int revision = 0,
}) => PersonalOperation(
  opId: id,
  kind: kind,
  entityId: entity,
  baseRevision: revision,
  createdAt: DateTime.utc(2026, 10, 4),
  payload: payload,
);
Map<String, dynamic> schedule(String id, DateTime due, {bool read = false}) =>
    Map<String, dynamic>.from(
      ScheduledSend(
        id: id,
        target: SendTarget(
          conversation: conversation,
          readUpToEventId: read ? r'$read-bound' : null,
        ),
        dueAt: due,
        content: {'msgtype': 'm.text', 'body': 'synthetic'},
        transactionId: 'untrusted-client-tx',
      ).toJson(),
    );

void main() {
  late WorkerStore store;
  late FakeTransport transport;
  late FakeTranscriber transcriber;
  late WorkerEngine engine;
  final now = DateTime.utc(2026, 10, 4, 12);
  setUp(() {
    store = WorkerStore(sqlite3.openInMemory());
    transport = FakeTransport();
    transcriber = FakeTranscriber();
    engine = WorkerEngine(store, transport, transcriber, clock: () => now);
  });
  tearDown(() async {
    await engine.waitForIdle();
    store.close();
  });
  test(
    'untilReply waits on incomplete history, then cancels on recipient response without receipts',
    () async {
      var reminderClock = now;
      engine = WorkerEngine(
        store,
        transport,
        transcriber,
        clock: () => reminderClock,
      );
      engine.accept(
        op('reminder-until', 'reminder.create', 'r', {
          'id': 'r',
          'conversation': conversation.toJson(),
          'dueAt': now.toIso8601String(),
          'untilReply': true,
        }),
      );
      transport.replyHistoryFailure = 'waiting_keys';
      await engine.tick();
      expect(store.job('r')!['state'], 'waitingKeys');
      expect(store.job('r')!['due'], isNot(true));
      transport.replyHistoryFailure = 'history_unavailable';
      reminderClock = now.add(const Duration(seconds: 31));
      await engine.tick();
      expect(store.job('r')!['state'], 'waitingSync');
      expect(store.job('r')!['due'], isNot(true));
      transport.replyHistoryFailure = null;
      transport.receivedReply = true;
      reminderClock = now.add(const Duration(seconds: 62));
      await engine.tick();
      expect(store.job('r')!['state'], 'cancelled');
      expect(store.job('r')!['errorCode'], 'replied');
      expect(transport.sent, isEmpty);
      expect(transport.reads, isEmpty);
    },
  );
  test(
    'proved no recipient response releases waiting reminder only after retry',
    () async {
      var reminderClock = now;
      engine = WorkerEngine(
        store,
        transport,
        transcriber,
        clock: () => reminderClock,
      );
      engine.accept(
        op('reminder-until', 'reminder.create', 'r', {
          'id': 'r',
          'conversation': conversation.toJson(),
          'dueAt': now.toIso8601String(),
          'untilReply': true,
        }),
      );
      transport.replyHistoryFailure = 'waiting_keys';
      await engine.tick();
      transport.replyHistoryFailure = null;
      await engine.tick();
      expect(store.job('r')!['state'], 'waitingKeys');
      reminderClock = now.add(const Duration(seconds: 31));
      await engine.tick();
      expect(store.job('r')!['state'], 'done');
      expect(store.job('r')!['due'], true);
      expect(transport.reads, isEmpty);
    },
  );
  group('untilReply reminders with unreadable history', () {
    late DateTime reminderClock;
    setUp(() {
      reminderClock = now;
      engine = WorkerEngine(
        store,
        transport,
        transcriber,
        clock: () => reminderClock,
      );
    });
    void create(DateTime due) => engine.accept(
      op('reminder-until', 'reminder.create', 'r', {
        'id': 'r',
        'conversation': conversation.toJson(),
        'dueAt': due.toIso8601String(),
        'untilReply': true,
      }),
    );
    Map<String, dynamic> lastResult() =>
        Map<String, dynamic>.from(store.outbox.last['payload'] as Map);

    test(
      'fire after a bounded grace past due and mark the reply check skipped',
      () async {
        final due = now.add(const Duration(seconds: 10));
        final graceEnd = due.add(WorkerEngine.reminderReplyCheckGrace);
        create(due);
        transport.replyHistoryFailure = 'waiting_keys';
        await engine.tick();
        expect(store.job('r')!['state'], 'waitingKeys');
        // The retry is pulled forward to the due time instead of +30 s.
        expect(store.job('r')!['nextReplyCheckAt'], due.toIso8601String());
        reminderClock = due;
        await engine.tick();
        expect(store.job('r')!['state'], 'waitingKeys');
        expect(store.job('r')!['due'], isNot(true));
        transport.replyHistoryFailure = 'history_unavailable';
        reminderClock = graceEnd.subtract(const Duration(seconds: 1));
        await engine.tick();
        expect(store.job('r')!['state'], 'waitingSync');
        expect(store.job('r')!['due'], isNot(true));
        expect(store.job('r')!['nextReplyCheckAt'], graceEnd.toIso8601String());
        reminderClock = graceEnd;
        await engine.tick();
        final job = store.job('r')!;
        expect(job['state'], 'done');
        expect(job['due'], true);
        expect(job['errorCode'], isNull);
        expect(job['replyCheck'], 'skipped');
        expect(job['replyCheckError'], 'history_unavailable');
        expect(job.containsKey('nextReplyCheckAt'), isFalse);
        // The published result carries what the client needs to alert.
        final result = lastResult();
        expect(store.outbox.last['kind'], 'reminder.result');
        expect(result['state'], 'done');
        expect(result['due'], true);
        expect(result['untilReply'], true);
        expect(result['replyCheck'], 'skipped');
        expect(result['conversation'], conversation.toJson());
        expect(transport.sent, isEmpty);
        expect(transport.reads, isEmpty);
      },
    );

    test('keys arriving within the grace still cancel on a reply', () async {
      create(now);
      transport.replyHistoryFailure = 'waiting_keys';
      await engine.tick();
      reminderClock = now.add(const Duration(minutes: 2));
      transport.replyHistoryFailure = null;
      transport.receivedReply = true;
      await engine.tick();
      expect(store.job('r')!['state'], 'cancelled');
      expect(store.job('r')!['errorCode'], 'replied');
      expect(store.job('r')!['due'], isNot(true));
    });

    test(
      'a reminder stuck before the grace rule fires on the next tick',
      () async {
        // Persisted by the previous worker: long past due, retry gate ahead.
        store.saveJob({
          'id': 'r',
          'conversation': conversation.toJson(),
          'untilReply': true,
          'kind': 'reminder',
          'revision': 40,
          'state': 'waitingKeys',
          'errorCode': 'waiting_keys',
          'acceptedOpId': 'reminder-until',
          'dueAt': now.subtract(const Duration(days: 2)).toIso8601String(),
          'createdAt': now.subtract(const Duration(days: 3)).toIso8601String(),
          'nextReplyCheckAt': now
              .add(const Duration(seconds: 20))
              .toIso8601String(),
        });
        transport.replyHistoryFailure = 'waiting_keys';
        await engine.tick();
        final job = store.job('r')!;
        expect(job['state'], 'done');
        expect(job['due'], true);
        expect(job['revision'], 41);
        expect(job['replyCheck'], 'skipped');
        expect(job['replyCheckError'], 'waiting_keys');
        expect(lastResult()['state'], 'done');
      },
    );

    test(
      'a stuck reminder whose history is now readable checks first',
      () async {
        store.saveJob({
          'id': 'r',
          'conversation': conversation.toJson(),
          'untilReply': true,
          'kind': 'reminder',
          'revision': 9,
          'state': 'waitingSync',
          'errorCode': 'history_unavailable',
          'acceptedOpId': 'reminder-until',
          'dueAt': now.subtract(const Duration(hours: 1)).toIso8601String(),
          'createdAt': now.subtract(const Duration(hours: 2)).toIso8601String(),
          'nextReplyCheckAt': now
              .add(const Duration(seconds: 20))
              .toIso8601String(),
        });
        await engine.tick();
        expect(store.job('r')!['state'], 'done');
        expect(store.job('r')!.containsKey('replyCheck'), isFalse);
      },
    );

    test(
      'readable history is checked every 30 s before due and at the due time',
      () async {
        final due = now.add(const Duration(seconds: 45));
        create(due);
        await engine.tick();
        expect(transport.replyChecks, 1);
        expect(store.job('r')!['state'], 'queued');
        reminderClock = now.add(const Duration(seconds: 10));
        await engine.tick();
        expect(transport.replyChecks, 1);
        reminderClock = now.add(const Duration(seconds: 30));
        await engine.tick();
        expect(transport.replyChecks, 2);
        expect(store.job('r')!['nextReplyCheckAt'], due.toIso8601String());
        reminderClock = now.add(const Duration(seconds: 40));
        await engine.tick();
        expect(transport.replyChecks, 2);
        expect(store.job('r')!['due'], isNot(true));
        reminderClock = due;
        await engine.tick();
        expect(transport.replyChecks, 3);
        final job = store.job('r')!;
        expect(job['state'], 'done');
        expect(job['due'], true);
        expect(job.containsKey('replyCheck'), isFalse);
      },
    );
  });
  test('pairing ACK is durable, idempotent and never creates a job', () async {
    final command = op('pair', 'worker.pairing', 'worker', {'schema': 1});
    engine.accept(command);
    engine.accept(command);
    expect(store.hasCommand('pair'), isTrue);
    expect(store.jobs(), isEmpty);
    expect(store.outbox, hasLength(1));
    final result = store.outbox.single;
    expect(result['kind'], 'worker.pairing.result');
    expect(result['payload']['acceptedOpId'], 'pair');
    expect(result['payload']['verified'], true);
    expect(result['payload']['state'], 'done');
    final restarted = WorkerEngine(
      store,
      transport,
      transcriber,
      clock: () => now,
    );
    restarted.accept(command);
    expect(store.outbox, hasLength(1));
    await restarted.tick();
    expect(transport.sent, isEmpty);
    expect(transport.reads, isEmpty);
  });
  test('stale schedule conflict preserves actual queued state and payload', () {
    engine.accept(op('create', 'schedule.create', 's', schedule('s', now)));
    final before = store.job('s');
    engine.accept(
      op('stale', 'schedule.update', 's', schedule('s', now), revision: 0),
    );
    expect(store.job('s'), before);
    final conflict = store.outbox.last['payload'];
    expect(conflict['state'], 'conflict');
    expect(conflict['actualState'], 'queued');
    expect(conflict['revision'], 1);
    expect(conflict['acceptedOpId'], 'stale');
  });
  test(
    'explicit re-transcription of done requires fresh op and latest revision',
    () async {
      final requestBody = Map<String, dynamic>.from(
        TranscriptionJob(
          id: 't',
          source: source,
          state: JobState.queued,
        ).toJson(),
      );
      final first = op('first', 'transcript.request', 't', requestBody);
      engine.accept(first);
      await engine.tick();
      await engine.waitForIdle();
      final completed = store.job('t')!;
      expect(completed['state'], 'done');
      expect(transcriber.calls, 1);
      engine.accept(first);
      await engine.tick();
      await engine.waitForIdle();
      expect(transcriber.calls, 1);
      engine.accept(
        op('stale-retry', 'transcript.request', 't', requestBody, revision: 0),
      );
      expect(store.job('t'), completed);
      expect(store.outbox.last['payload']['actualState'], 'done');
      engine.accept(
        op(
          'explicit-retry',
          'transcript.request',
          't',
          requestBody,
          revision: completed['revision'] as int,
        ),
      );
      expect(store.job('t')!['state'], 'queued');
      expect(store.job('t')!['text'], isNull);
      await engine.tick();
      await engine.waitForIdle();
      expect(transcriber.calls, 2);
      expect(store.job('t')!['state'], 'done');
    },
  );
  test(
    'replayed command creates one job and ack; states have unique op IDs',
    () async {
      final request = op(
        'request',
        'transcript.request',
        'transcript:test',
        Map<String, dynamic>.from(
          TranscriptionJob(
            id: 'transcript:test',
            source: source,
            state: JobState.queued,
          ).toJson(),
        ),
      );
      engine.accept(request);
      engine.accept(request);
      expect(store.jobs(), hasLength(1));
      expect(store.outbox, hasLength(1));
      await engine.tick();
      await engine.waitForIdle();
      expect(transcriber.calls, 1);
      expect(store.job('transcript:test')!['state'], 'done');
      expect(
        store.outbox.map((e) => e['opId']).toSet().length,
        store.outbox.length,
      );
      expect(transport.reads, isEmpty);
      expect(transport.sent, isEmpty);
    },
  );
  Map<String, dynamic> transcriptBody() => Map<String, dynamic>.from(
    TranscriptionJob(id: 't', source: source, state: JobState.queued).toJson(),
  );
  Future<void> completeTranscript() async {
    engine.accept(op('request', 'transcript.request', 't', transcriptBody()));
    await engine.tick();
    await engine.waitForIdle();
  }

  for (final sourceStatus in <bool?>[null, false]) {
    test(
      'cancel during ${sourceStatus == null ? 'unknown' : 'available'} preflight never resurrects or downloads audio',
      () async {
        final probe = transport.holdSourceProbe = Completer<bool?>();
        final started = transport.sourceProbeStarted = Completer<void>();
        engine.accept(
          op('request', 'transcript.request', 't', transcriptBody()),
        );
        await engine.tick();
        await started.future;
        engine.accept(
          op('cancel', 'transcript.cancel', 't', {
            'id': 't',
          }, revision: store.job('t')!['revision'] as int),
        );
        final cancelled = store.job('t');
        probe.complete(sourceStatus);
        await engine.waitForIdle();
        expect(store.job('t'), cancelled);
        transport.holdSourceProbe = null;
        await engine.auditTranscriptSources(force: true);
        await engine.tick();
        await engine.waitForIdle();
        expect(store.job('t')!['state'], 'cancelled');
        expect(transport.audioLoads, 0);
        expect(transcriber.calls, 0);
      },
    );
  }
  test(
    'cancelled preflight cannot overwrite a newly accepted manual retry',
    () async {
      final probe = transport.holdSourceProbe = Completer<bool?>();
      final started = transport.sourceProbeStarted = Completer<void>();
      engine.accept(op('request', 'transcript.request', 't', transcriptBody()));
      await engine.tick();
      await started.future;
      engine.accept(
        op('cancel', 'transcript.cancel', 't', {
          'id': 't',
        }, revision: store.job('t')!['revision'] as int),
      );
      engine.accept(
        op(
          'retry',
          'transcript.request',
          't',
          transcriptBody(),
          revision: store.job('t')!['revision'] as int,
        ),
      );
      final retry = store.job('t');
      probe.complete(null);
      await engine.waitForIdle();
      expect(store.job('t'), retry);
      expect(store.job('t')!['acceptedOpId'], 'retry');
      expect(transport.audioLoads, 0);
      expect(transcriber.calls, 0);
      transport.holdSourceProbe = null;
      await engine.tick();
      await engine.waitForIdle();
      expect(store.job('t')!['state'], 'done');
      expect(transcriber.calls, 1);
    },
  );
  test(
    'cancelled paid attempt cannot overwrite an accepted manual retry',
    () async {
      final held = transcriber.hold = Completer<void>();
      engine.accept(op('request', 'transcript.request', 't', transcriptBody()));
      await engine.tick();
      await Future<void>.delayed(Duration.zero);
      expect(transcriber.calls, 1);
      engine.accept(
        op('cancel', 'transcript.cancel', 't', {
          'id': 't',
        }, revision: store.job('t')!['revision'] as int),
      );
      engine.accept(
        op(
          'retry',
          'transcript.request',
          't',
          transcriptBody(),
          revision: store.job('t')!['revision'] as int,
        ),
      );
      final retry = store.job('t');
      held.complete();
      await engine.waitForIdle();
      expect(store.job('t'), retry);
      expect(store.job('t')!['acceptedOpId'], 'retry');
      transcriber.hold = null;
      await engine.tick();
      await engine.waitForIdle();
      expect(store.job('t')!['state'], 'done');
      expect(store.job('t')!['acceptedOpId'], 'retry');
      expect(transcriber.calls, 2);
    },
  );

  test(
    'confirmed done-source redaction tombstones text, revision and old publications once',
    () async {
      await completeTranscript();
      final done = store.outbox.last;
      store.recordTranscriptPublicationIntent(done);
      store.recordTranscriptPublication(done, r'$private-done');
      store.acknowledge(done['opId'] as String);
      final revision = store.job('t')!['revision'];
      transport.redacted = true;
      await engine.auditTranscriptSources(force: true);
      expect(store.job('t')!['state'], 'cancelled');
      expect(store.job('t')!['errorCode'], 'source_redacted');
      expect(store.job('t')!['text'], isNull);
      expect(store.outbox.last['payload'].containsKey('text'), true);
      expect(store.outbox.last['payload']['text'], isNull);
      expect(
        store.pendingTranscriptRedactions.single['event_id'],
        r'$private-done',
      );
      final restarted = WorkerEngine(store, transport, transcriber);
      await restarted.auditTranscriptSources(force: true);
      expect(store.job('t')!['revision'], revision + 1);
      expect(transcriber.calls, 1);
    },
  );
  test(
    'redaction after paid inflight completion never publishes text',
    () async {
      transcriber.hold = Completer<void>();
      engine.accept(op('request', 'transcript.request', 't', transcriptBody()));
      await engine.tick();
      await Future<void>.delayed(Duration.zero);
      transport.redacted = true;
      transcriber.hold!.complete();
      await engine.waitForIdle();
      expect(store.job('t')!['errorCode'], 'source_redacted');
      expect(store.job('t')!['text'], isNull);
      expect(store.outbox.any((e) => e['payload']['text'] is String), false);
    },
  );
  test(
    'sync source audit cancels inflight paid job without result resurrection',
    () async {
      transcriber.hold = Completer<void>();
      engine.accept(op('request', 'transcript.request', 't', transcriptBody()));
      await engine.tick();
      await Future<void>.delayed(Duration.zero);
      transport.redacted = true;
      await engine.auditTranscriptSources(force: true);
      transcriber.hold!.complete();
      await engine.waitForIdle();
      expect(store.job('t')!['state'], 'cancelled');
      expect(store.job('t')!['errorCode'], 'source_redacted');
      expect(store.job('t')!['text'], isNull);
    },
  );
  test(
    'unknown source status preserves done text and never invalidates publications',
    () async {
      await completeTranscript();
      final original = store.job('t');
      transport.redacted = null;
      await engine.auditTranscriptSources(force: true);
      expect(store.job('t'), original);
      expect(store.pendingTranscriptRedactions, isEmpty);
      expect(transcriber.calls, 1);
    },
  );
  test(
    'unknown preflight source does not download or incur paid request',
    () async {
      transport.redacted = null;
      await completeTranscript();
      expect(store.job('t')!['state'], 'waitingSync');
      expect(transcriber.calls, 0);
      await engine.tick();
      expect(transcriber.calls, 0);
      transport.redacted = false;
      await engine.auditTranscriptSources(force: true);
      await engine.tick();
      await engine.waitForIdle();
      expect(store.job('t')!['state'], 'done');
      expect(transcriber.calls, 1);
    },
  );
  test(
    'unknown postpaid outcome is private and resumes after restart without another charge',
    () async {
      transcriber.hold = Completer<void>();
      engine.accept(op('request', 'transcript.request', 't', transcriptBody()));
      await engine.tick();
      await Future<void>.delayed(Duration.zero);
      transport.redacted = null;
      transcriber.hold!.complete();
      await engine.waitForIdle();
      expect(store.job('t')!['state'], 'waitingSync');
      expect(store.job('t')!['pendingResult']['text'], 'synthetic transcript');
      expect(
        store.outbox.any((e) => e['payload'].containsKey('pendingResult')),
        false,
      );
      final restarted = WorkerEngine(store, transport, transcriber);
      restarted.recover();
      await restarted.tick();
      expect(transcriber.calls, 1);
      transport.redacted = false;
      await restarted.auditTranscriptSources(force: true);
      expect(store.job('t')!['state'], 'done');
      expect(store.job('t')!['text'], 'synthetic transcript');
      expect(transcriber.calls, 1);
    },
  );
  test(
    'lost private-result ACK retains txid intent; null retry still redacts original accepted text ID',
    () async {
      await completeTranscript();
      final body = store.outbox.last;
      final opId = body['opId'] as String;
      store.recordTranscriptPublicationIntent(
        body,
      ); // Accepted server send, response lost.
      transport.redacted = true;
      await engine.auditTranscriptSources(force: true);
      final retry = store.outboxEntry(opId)!;
      expect(retry['payload']['text'], isNull);
      expect(retry['opId'], opId);
      final restartedStore = WorkerStore(store.db);
      restartedStore.transaction(() {
        restartedStore.recordTranscriptPublication(
          retry,
          r'$accepted-before-redaction',
        );
        restartedStore.acknowledge(opId);
      });
      expect(
        restartedStore.pendingTranscriptRedactions.single['event_id'],
        r'$accepted-before-redaction',
      );
      restartedStore.acknowledgeTranscriptRedaction(opId);
      expect(restartedStore.pendingTranscriptRedactions, isEmpty);
      expect(transcriber.calls, 1);
    },
  );

  test(
    'postpaid private pending result is erased on confirmed source deletion',
    () async {
      transcriber.hold = Completer<void>();
      engine.accept(op('request', 'transcript.request', 't', transcriptBody()));
      await engine.tick();
      await Future<void>.delayed(Duration.zero);
      transport.redacted = null;
      transcriber.hold!.complete();
      await engine.waitForIdle();
      expect(store.job('t')!['pendingResult'], isA<Map>());
      transport.redacted = true;
      await engine.auditTranscriptSources(force: true);
      expect(store.job('t')!.containsKey('pendingResult'), false);
      expect(store.job('t')!['text'], isNull);
      expect(store.job('t')!['errorCode'], 'source_redacted');
      expect(transcriber.calls, 1);
    },
  );
  test(
    'jobs parked on an unknown source are re-probed ahead of the round-robin',
    () async {
      var clockNow = now;
      engine = WorkerEngine(
        store,
        transport,
        transcriber,
        clock: () => clockNow,
      );
      // Many other jobs: the round-robin alone (4 per 30 s) would reach the
      // parked one only after several passes.
      for (var i = 0; i < 12; i++) {
        final body = transcriptBody()..['id'] = 'old$i';
        engine.accept(op('old$i', 'transcript.request', 'old$i', body));
      }
      await engine.auditTranscriptSources(force: true);
      final probes = transport.sourceProbes;
      // A fresh job whose source could not be checked before the download.
      final body = transcriptBody()..['id'] = 'fresh';
      engine.accept(op('fresh', 'transcript.request', 'fresh', body));
      final parked = store.job('fresh')!
        ..['state'] = 'waitingSync'
        ..['errorCode'] = 'source_status_unknown';
      store.saveJob(parked);
      clockNow = clockNow.add(WorkerEngine.parkedSourceRetry);
      await engine.auditTranscriptSources();
      expect(
        transport.sourceProbes,
        probes + 1,
        reason: 'only the parked job; the round-robin is not due yet',
      );
      expect(store.job('fresh')!['state'], 'queued');
      // Nothing parked any more: no probes until the round-robin is due.
      clockNow = clockNow.add(WorkerEngine.parkedSourceRetry);
      await engine.auditTranscriptSources();
      expect(transport.sourceProbes, probes + 1);
      clockNow = clockNow.add(WorkerEngine.sourceAuditInterval);
      await engine.auditTranscriptSources();
      expect(transport.sourceProbes, probes + 1 + WorkerEngine.sourceAuditBatch);
    },
  );
  test(
    'source audit is bounded and resumes round-robin cursor after restart',
    () async {
      for (var i = 0; i < 9; i++) {
        final body = transcriptBody()..['id'] = 't$i';
        engine.accept(op('request$i', 'transcript.request', 't$i', body));
      }
      await engine.auditTranscriptSources(force: true);
      expect(transport.sourceProbes, 4);
      expect(store.checkpoint('source-audit'), 't3');
      final restarted = WorkerEngine(store, transport, transcriber);
      await restarted.auditTranscriptSources(force: true);
      expect(transport.sourceProbes, 8);
      expect(store.checkpoint('source-audit'), 't7');
      expect(transcriber.calls, 0);
    },
  );

  test('unknown paid result never retries automatically', () async {
    transcriber.paidUnknown = true;
    engine.accept(
      op(
        'request',
        'transcript.request',
        't',
        Map<String, dynamic>.from(
          TranscriptionJob(
            id: 't',
            source: source,
            state: JobState.queued,
          ).toJson(),
        ),
      ),
    );
    await engine.tick();
    await engine.waitForIdle();
    await engine.tick();
    expect(store.job('t')!['state'], 'unknown');
    expect(transcriber.calls, 1);
  });
  test('paid crash recovery is unknown and scheduled recovery reuses txid', () {
    store.saveJob({
      'id': 't',
      'kind': 'transcript',
      'revision': 1,
      'state': 'processing',
    });
    store.saveJob({
      'id': 's',
      'kind': 'schedule',
      'revision': 1,
      'state': 'processing',
      'transactionId': 'persisted',
    });
    engine.recover();
    expect(store.job('t')!['state'], 'unknown');
    expect(store.job('s')!['state'], 'queued');
    expect(store.job('s')!['transactionId'], 'persisted');
  });
  test(
    'scheduled ambiguity retries same txid even outside initial grace',
    () async {
      engine.accept(op('create', 'schedule.create', 's', schedule('s', now)));
      transport.failUnknown = true;
      await engine.tick();
      final tx = store.job('s')!['transactionId'];
      transport.failUnknown = false;
      await engine.tick();
      expect(transport.sent, [tx, tx]);
      expect(store.job('s')!['state'], 'done');
    },
  );
  test('over five minute late is paused without send', () async {
    engine.accept(
      op(
        'create',
        'schedule.create',
        's',
        schedule('s', now.subtract(const Duration(minutes: 6))),
      ),
    );
    await engine.tick();
    expect(store.job('s')!['state'], 'paused');
    expect(transport.sent, isEmpty);
  });
  test(
    'different device pauses sends; never falls back to another transport',
    () async {
      engine.accept(op('create', 'schedule.create', 's', schedule('s', now)));
      transport.deviceId = 'NEW_DEVICE';
      await engine.tick();
      expect(transport.sent, isEmpty);
      expect(store.job('s')!['state'], 'paused');
    },
  );
  test('cancel before dispatch atomic, stale update conflict', () async {
    engine.accept(op('create', 'schedule.create', 's', schedule('s', now)));
    engine.accept(op('cancel', 'schedule.cancel', 's', {}, revision: 1));
    engine.accept(
      op('stale', 'schedule.update', 's', schedule('s', now), revision: 1),
    );
    await engine.tick();
    expect(transport.sent, isEmpty);
    expect(store.job('s')!['state'], 'cancelled');
    expect(store.outbox.last['payload']['errorCode'], 'conflict');
  });
  test(
    'cancel during send rejected; read bound only after accepted send',
    () async {
      transport.holdSend = Completer<void>();
      engine.accept(
        op('create', 'schedule.create', 's', schedule('s', now, read: true)),
      );
      final tick = engine.tick();
      await Future<void>.delayed(Duration.zero);
      expect(transport.reads, isEmpty);
      engine.accept(op('cancel', 'schedule.cancel', 's', {}, revision: 2));
      expect(store.outbox.last['payload']['errorCode'], 'too_late');
      transport.holdSend!.complete();
      await tick;
      expect(transport.reads, [r'$read-bound']);
      expect(store.job('s')!['state'], 'done');
    },
  );
  test('source account and schedule media validation fail before ack', () {
    final bad = schedule('s', now);
    bad['target']['conversation']['accountId'] = '@wrong:example.invalid';
    expect(
      () => engine.accept(op('bad', 'schedule.create', 's', bad)),
      throwsA(isA<WorkerFailure>()),
    );
    expect(store.hasCommand('bad'), isFalse);
    expect(store.jobs(), isEmpty);
  });
  test(
    'metadata revisions include tombstones and conflict preserves value',
    () {
      engine.accept(
        op('put', 'metadata.put', 'people:test', {
          'value': {'name': 'synthetic'},
        }),
      );
      engine.accept(
        op('stale', 'metadata.put', 'people:test', {'value': 'wrong'}),
      );
      expect(store.metadata('people:test')!['value'], {'name': 'synthetic'});
      engine.accept(
        op('delete', 'metadata.delete', 'people:test', {}, revision: 1),
      );
      expect(store.metadata('people:test')!['deleted'], isTrue);
      expect(store.metadata('people:test')!['revision'], 2);
    },
  );
  test('long transcript does not block schedule timer', () async {
    transcriber.hold = Completer<void>();
    engine.accept(
      op(
        'request',
        'transcript.request',
        't',
        Map<String, dynamic>.from(
          TranscriptionJob(
            id: 't',
            source: source,
            state: JobState.queued,
          ).toJson(),
        ),
      ),
    );
    await engine.tick();
    await Future<void>.delayed(Duration.zero);
    engine.accept(op('create', 'schedule.create', 's', schedule('s', now)));
    await engine.tick();
    expect(transport.sent, hasLength(1));
    transcriber.hold!.complete();
    await engine.waitForIdle();
  });
  test(
    'reminder due result is durable and cancellation prevents trigger',
    () async {
      engine.accept(
        op('reminder', 'reminder.create', 'r', {
          'id': 'r',
          'conversation': conversation.toJson(),
          'dueAt': now.toIso8601String(),
          'untilReply': false,
        }),
      );
      await engine.tick();
      expect(store.job('r')!['state'], 'done');
      expect(store.outbox.last['kind'], 'reminder.result');
      expect(store.outbox.last['payload']['due'], isTrue);
      expect(transport.sent, isEmpty);
      expect(transport.reads, isEmpty);
      engine.accept(
        op('reminder2', 'reminder.create', 'r2', {
          'id': 'r2',
          'conversation': conversation.toJson(),
          'dueAt': now.toIso8601String(),
          'untilReply': false,
        }),
      );
      engine.accept(
        op('cancel-reminder2', 'reminder.cancel', 'r2', {}, revision: 1),
      );
      await engine.tick();
      expect(store.job('r2')!['state'], 'cancelled');
    },
  );
  test('metadata direct payload and explicit conflict retain both copies', () {
    engine.accept(op('put', 'metadata.put', 'draft:s', {'text': 'first'}));
    engine.accept(op('put2', 'metadata.put', 'draft:s', {'text': 'second'}));
    expect(store.metadata('draft:s')!['value'], {'text': 'first'});
    expect(store.outbox.last['payload']['existingValue'], {'text': 'first'});
    expect(store.outbox.last['payload']['proposedValue'], {'text': 'second'});
  });
}

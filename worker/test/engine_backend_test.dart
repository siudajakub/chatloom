// SPDX-License-Identifier: AGPL-3.0-or-later
// Wave 5 backend review (CB-01, CB-04 ... CB-08, CB-13, CB-16, CB-17):
// bounded retries, quiet re-attempts, off-loop reply checks, long
// transcripts and indexed store queries. Fake transport and provider only.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/engine.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

const _account = '@self:example.invalid';
const _room = '!room:example.invalid';
const _otherRoom = '!other:example.invalid';

SourceEventRef _source(String event, {String room = _room}) => SourceEventRef(
  conversation: ConversationRef(accountId: _account, roomId: room),
  eventId: event,
);

class _Transport implements FeatureTransport {
  @override
  String get accountId => _account;
  @override
  String get deviceId => 'WORKER';
  @override
  bool get verified => true;

  /// Successive failure codes of loads per event id.
  final failures = <String, List<String>>{};
  final loads = <String>[];
  bool? redacted = false;
  int probes = 0;
  final replyHolds = <Completer<bool>>[];
  int replyChecks = 0;
  bool holdReplies = false;

  @override
  Future<bool?> sourceRedacted(SourceEventRef source) async {
    probes++;
    return redacted;
  }

  @override
  Future<AudioSource> loadAudio(
    SourceEventRef source,
    Cancellation cancel,
  ) async {
    loads.add(source.eventId);
    final queue = failures[source.eventId];
    if (queue != null && queue.isNotEmpty) {
      final code = queue.length == 1 ? queue.single : queue.removeAt(0);
      throw WorkerFailure(code);
    }
    return AudioSource(
      Uint8List.fromList(utf8.encode(source.eventId)),
      'audio/ogg',
    );
  }

  @override
  Future<bool> hasRepliedSince(ConversationRef conversation, DateTime since) {
    replyChecks++;
    if (!holdReplies) return Future.value(false);
    final hold = Completer<bool>();
    replyHolds.add(hold);
    return hold.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected conversation operation');
}

class _Transcriber implements Transcriber {
  String text = 'synthetic transcript';
  int calls = 0;
  @override
  Future<TranscriptionResult> transcribe(
    AudioSource audio,
    String? language,
    Cancellation cancel,
    void Function(double, double) estimate,
  ) async {
    calls++;
    estimate(60, 0.0045);
    return TranscriptionResult(text, 60, 0.0045);
  }
}

PersonalOperation _op(
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
  createdAt: DateTime.utc(2026, 10, 21),
  payload: payload,
);

Map<String, dynamic> _request(
  SourceEventRef source, {
  TranscriptionOrigin origin = TranscriptionOrigin.manual,
}) => Map<String, dynamic>.from(
  TranscriptionJob(
    id: transcriptEntityId(source),
    source: source,
    state: JobState.queued,
    origin: origin,
  ).toJson(),
);

/// About 45 minutes of Polish speech.
String _longText() {
  final text = StringBuffer();
  for (var minute = 0; text.length < 46000; minute++) {
    text.write(
      'Minuta $minute: zażółć gęślą jaźń, "cytat" i dalej o planach. ',
    );
  }
  return text.toString();
}

void main() {
  late WorkerStore store;
  late _Transport transport;
  late _Transcriber transcriber;
  late WorkerEngine engine;
  late DateTime now;

  setUp(() {
    now = DateTime.utc(2026, 10, 21, 12);
    store = WorkerStore(sqlite3.openInMemory());
    transport = _Transport();
    transcriber = _Transcriber();
    engine = WorkerEngine(
      store,
      transport,
      transcriber,
      clock: () => now,
      autoTranscription: true,
    );
  });
  tearDown(() async {
    await engine.shutdown();
    store.close();
  });

  Future<void> run() async {
    await engine.tick();
    await engine.waitForIdle();
    await engine.reminderChecksIdle();
  }

  Map<String, dynamic> job(SourceEventRef source) =>
      store.job(transcriptEntityId(source))!;

  group('long transcripts (CB-01)', () {
    test('a 45-minute transcript is published as a preview plus slices '
        'that each fit one journal event', () async {
      final text = _longText();
      transcriber.text = text;
      final source = _source(r'$long');
      engine.accept(
        _op(
          'request',
          'transcript.request',
          transcriptEntityId(source),
          _request(source),
        ),
      );
      await run();
      expect(job(source)['state'], 'done');
      expect(job(source)['text'], text, reason: 'the worker keeps it whole');
      final outbox = store.outbox;
      final done = outbox.lastWhere(
        (body) =>
            body['kind'] == 'transcript.result' &&
            (body['payload'] as Map)['state'] == 'done',
      );
      final meta = TranscriptTextParts.tryParse(
        (done['payload'] as Map)['textParts'],
      )!;
      expect(
        (done['payload'] as Map)['text'],
        endsWith(transcriptPreviewSuffix),
      );
      final parts = [
        for (final body in outbox)
          if (body['kind'] == transcriptTextPartKind)
            TranscriptTextPart.tryParse(
              Map<String, dynamic>.from(body['payload'] as Map),
            )!,
      ];
      expect(parts, hasLength(meta.count));
      expect(meta.count, greaterThanOrEqualTo(2));
      expect(
        assembleTranscriptText(meta, {for (final p in parts) p.index: p.text}),
        text,
      );
      // Plaintext event well below the SDK's 60000-byte encrypted limit
      // (~1.34 x plaintext + envelope).
      for (final body in outbox) {
        expect(utf8.encode(jsonEncode(body)).length, lessThan(40000));
      }
      // Slices are text-bearing publications: erased with the source.
      for (final body in outbox) {
        store.recordTranscriptPublicationIntent(body);
        store.recordTranscriptPublication(body, '\$${body['opId']}');
        store.acknowledge(body['opId'] as String);
      }
      transport.redacted = true;
      await engine.auditTranscriptSources(force: true);
      expect(job(source)['text'], isNull);
      expect(
        store.pendingTranscriptRedactions.length,
        meta.count + 1 > 8 ? 8 : meta.count + 1,
        reason: 'the preview result and every slice (one page of at most 8)',
      );
    });

    test('an oversize result queued by an older worker is split when the '
        'store opens, so it can no longer block the queue', () {
      final source = _source(r'$legacy');
      final text = _longText();
      final legacy = PersonalOperation(
        opId: 'legacy-done',
        kind: 'transcript.result',
        entityId: transcriptEntityId(source),
        baseRevision: 3,
        createdAt: now,
        payload: {
          ..._request(source),
          'state': 'done',
          'revision': 3,
          'text': text,
        },
      ).toJson();
      store.db.execute('INSERT INTO outbox VALUES (?,?)', [
        'legacy-done',
        jsonEncode(legacy),
      ]);
      final reopened = WorkerStore(store.db);
      final outbox = reopened.outbox;
      expect(outbox.first['opId'], 'legacy-done');
      expect((outbox.first['payload'] as Map)['textParts'], isA<Map>());
      expect(
        outbox.where((body) => body['kind'] == transcriptTextPartKind),
        isNotEmpty,
      );
      // Idempotent: opening again changes nothing.
      expect(WorkerStore(store.db).outbox, hasLength(outbox.length));
    });

    test('a refusal never echoes the transcript text', () async {
      final source = _source(r'$echo');
      engine.accept(
        _op(
          'first',
          'transcript.request',
          transcriptEntityId(source),
          _request(source),
        ),
      );
      await run();
      expect(job(source)['text'], isA<String>());
      engine.accept(
        _op('cancel-late', 'transcript.cancel', transcriptEntityId(source), {
          'id': transcriptEntityId(source),
        }, revision: job(source)['revision'] as int),
      );
      final refusal = store.outbox.last['payload'] as Map;
      expect(refusal['state'], 'conflict');
      expect(refusal['errorCode'], 'too_late');
      expect(refusal.containsKey('text'), isFalse);
    });
  });

  group('automatic requests (CB-07, CB-17)', () {
    test('never re-run an existing finished job', () async {
      final source = _source(r'$auto');
      final entity = transcriptEntityId(source);
      engine.accept(
        _op('manual', 'transcript.request', entity, _request(source)),
      );
      await run();
      final done = job(source);
      expect(done['state'], 'done');
      engine.accept(
        _op(
          'late-auto',
          'transcript.request',
          entity,
          _request(source, origin: TranscriptionOrigin.auto),
          revision: done['revision'] as int,
        ),
      );
      await run();
      expect(job(source), done, reason: 'text, cost and createdAt kept');
      expect(transcriber.calls, 1, reason: 'never paid twice');
      final refusal = store.outbox.last['payload'] as Map;
      expect(refusal['errorCode'], 'already_exists');
      // An explicit request still re-runs it.
      engine.accept(
        _op(
          'manual-again',
          'transcript.request',
          entity,
          _request(source),
          revision: done['revision'] as int,
        ),
      );
      await run();
      expect(transcriber.calls, 2);
    });

    test('rule refusals of automatic jobs end silently cancelled', () async {
      final source = _source(r'$vanishing');
      transport.failures[r'$vanishing'] = ['protected_media'];
      engine.accept(
        _op(
          'auto',
          'transcript.request',
          transcriptEntityId(source),
          _request(source, origin: TranscriptionOrigin.auto),
        ),
      );
      await run();
      expect(job(source)['state'], 'cancelled');
      expect(job(source)['errorCode'], 'protected_media');
      // The same refusal of a request made by hand is an error.
      final manual = _source(r'$vanishing-manual');
      transport.failures[r'$vanishing-manual'] = ['protected_media'];
      engine.accept(
        _op(
          'manual',
          'transcript.request',
          transcriptEntityId(manual),
          _request(manual),
        ),
      );
      await run();
      expect(job(manual)['state'], 'failed');
    });
  });

  group('jobs waiting for keys (CB-05)', () {
    test('retries are quiet, bounded and woken only by keys for their '
        'room', () async {
      final source = _source(r'$keys');
      transport.failures[r'$keys'] = ['waiting_keys'];
      engine.accept(
        _op(
          'request',
          'transcript.request',
          transcriptEntityId(source),
          _request(source),
        ),
      );
      await run();
      expect(job(source)['state'], 'waitingKeys');
      final published = store.outbox.length;
      final revision = job(source)['revision'];
      // Keys for another room wake nothing.
      expect(engine.retryWaitingKeys(rooms: {_otherRoom}), 0);
      expect(engine.waitsForKeys(_otherRoom), isFalse);
      expect(engine.waitsForKeys(_room), isTrue);
      // A key for its room retries it at once, without a journal event when
      // nothing changed for clients.
      expect(engine.retryWaitingKeys(rooms: {_room}), 1);
      await run();
      expect(transport.loads, hasLength(2));
      expect(store.outbox, hasLength(published));
      expect(job(source)['revision'], revision);
      // At most once per job per wake interval.
      expect(engine.retryWaitingKeys(rooms: {_room}), 0);
      // Backoff retries stay quiet too; after a day the job gives up.
      for (var i = 0; i < 60; i++) {
        now = now.add(const Duration(minutes: 30));
        await run();
      }
      expect(job(source)['state'], 'failed');
      expect(job(source)['errorCode'], 'keys_unavailable');
      expect(transport.loads.length, lessThan(60));
      final waitEvents = store.outbox
          .skip(published)
          .where((body) => body['kind'] == 'transcript.result')
          .length;
      expect(waitEvents, 1, reason: 'only the final keys_unavailable');
      // A later key for that room queues it once more.
      transport.failures.remove(r'$keys');
      expect(engine.retryWaitingKeys(rooms: {_room}), 1);
      await run();
      expect(job(source)['state'], 'done');
      expect(engine.retryWaitingKeys(rooms: {_room}), 0);
    });

    test(
      'an automatic job that gives up on keys ends without an error',
      () async {
        final source = _source(r'$auto-keys');
        transport.failures[r'$auto-keys'] = ['waiting_keys'];
        engine.accept(
          _op(
            'auto',
            'transcript.request',
            transcriptEntityId(source),
            _request(source, origin: TranscriptionOrigin.auto),
          ),
        );
        await run();
        now = now.add(WorkerEngine.keysWaitLimit + const Duration(minutes: 1));
        await run();
        expect(job(source)['state'], 'cancelled');
        expect(job(source)['errorCode'], 'keys_unavailable');
      },
    );
  });

  group('source audits (CB-06)', () {
    test(
      'a parked job is probed with a growing delay, not every 5 s',
      () async {
        final source = _source(r'$gone');
        transport.redacted = null;
        engine.accept(
          _op(
            'request',
            'transcript.request',
            transcriptEntityId(source),
            _request(source),
          ),
        );
        await run();
        expect(job(source)['state'], 'waitingSync');
        final probes = <DateTime>[];
        var last = transport.probes;
        final start = now;
        for (var i = 0; i < 720; i++) {
          now = now.add(const Duration(seconds: 5));
          await engine.auditTranscriptSources();
          if (transport.probes != last) {
            probes.add(now);
            last = transport.probes;
          }
        }
        // An hour at 5 s would be 720 probes; the round-robin leaves parked
        // jobs to their own schedule.
        expect(probes.length, lessThan(15));
        expect(now.difference(start), const Duration(hours: 1));
        // Still parked: no age limit, nothing erased.
        expect(job(source)['state'], 'waitingSync');
        // Once the source answers the job continues.
        transport.redacted = false;
        now = now.add(WorkerEngine.parkedSourceRetryMax);
        await engine.auditTranscriptSources();
        expect(job(source)['state'], 'queued');
        expect(job(source).containsKey('auditAt'), isFalse);
      },
    );

    test('the round-robin skips jobs without a source to protect', () async {
      for (var i = 0; i < 3; i++) {
        final source = _source('\$skip$i');
        transport.failures['\$skip$i'] = ['not_audio'];
        engine.accept(
          _op(
            'skip$i',
            'transcript.request',
            transcriptEntityId(source),
            _request(source),
          ),
        );
      }
      await run();
      final done = _source(r'$kept');
      engine.accept(
        _op(
          'kept',
          'transcript.request',
          transcriptEntityId(done),
          _request(done),
        ),
      );
      await run();
      expect(job(done)['state'], 'done');
      final before = transport.probes;
      await engine.auditTranscriptSources(force: true);
      expect(transport.probes - before, 1, reason: 'failed jobs are skipped');
    });
  });

  group('reminder reply checks (CB-08)', () {
    void create(String id, {bool untilReply = true}) => engine.accept(
      _op('create-$id', 'reminder.create', id, {
        'id': id,
        'conversation': ConversationRef(
          accountId: _account,
          roomId: _room,
        ).toJson(),
        'dueAt': now.add(const Duration(hours: 1)).toIso8601String(),
        'untilReply': untilReply,
      }),
    );

    test('run beside the loop, at most two at a time', () async {
      transport.holdReplies = true;
      for (final id in ['a', 'b', 'c']) {
        create(id);
      }
      await engine.tick().timeout(const Duration(seconds: 1));
      expect(transport.replyChecks, 2, reason: 'bounded concurrency');
      // The loop is not held up: another tick returns at once.
      await engine.tick().timeout(const Duration(seconds: 1));
      expect(transport.replyChecks, 2);
      for (final hold in transport.replyHolds) {
        hold.complete(false);
      }
      await engine.reminderChecksIdle();
      await engine.tick();
      expect(transport.replyChecks, 3);
      transport.replyHolds.last.complete(false);
      await engine.reminderChecksIdle();
    });

    test('a reminder cancelled during its check stays cancelled', () async {
      transport.holdReplies = true;
      create('r');
      await engine.tick();
      engine.accept(_op('cancel', 'reminder.cancel', 'r', {}, revision: 1));
      expect(store.job('r')!['state'], 'cancelled');
      transport.replyHolds.single.complete(true);
      await engine.reminderChecksIdle();
      expect(store.job('r')!['state'], 'cancelled');
      expect(store.job('r')!['errorCode'], isNull);
    });
  });

  group('store queries (CB-04)', () {
    test('per-loop queries read only the rows they need', () async {
      for (var i = 0; i < 5; i++) {
        final source = _source('\$q$i');
        engine.accept(
          _op(
            'q$i',
            'transcript.request',
            transcriptEntityId(source),
            _request(source),
          ),
        );
      }
      expect(store.jobsWhere('transcript', ['queued']), hasLength(5));
      expect(store.jobsWhere('transcript', ['done']), isEmpty);
      expect(store.jobsWhere('reminder'), isEmpty);
      expect(store.pendingJobCount, 5);
      await run();
      await run();
      await run();
      expect(store.pendingJobCount, 0);
      expect(store.jobsWhere('transcript', ['done']), hasLength(5));
      final plan = store.db
          .select(
            "EXPLAIN QUERY PLAN SELECT body FROM jobs WHERE kind='transcript' AND state IN ('queued')",
          )
          .map((row) => row['detail'])
          .join(' ');
      expect(plan, contains('jobs_kind_state'));
    });

    test('the daily budget ledger survives rollbacks and restarts', () async {
      final source = _source(r'$budget');
      engine.accept(
        _op(
          'auto',
          'transcript.request',
          transcriptEntityId(source),
          _request(source, origin: TranscriptionOrigin.auto),
        ),
      );
      await run();
      expect(engine.autoSpent(), closeTo(0.0045, 1e-9));
      expect(
        () => store.transaction(() {
          store.saveJob({...job(source), 'estimatedCostUsd': 9.0});
          throw StateError('rolled back');
        }),
        throwsStateError,
      );
      expect(engine.autoSpent(), closeTo(0.0045, 1e-9));
      final reopened = WorkerEngine(
        WorkerStore(store.db),
        transport,
        transcriber,
        clock: () => now,
      );
      expect(reopened.autoSpent(), closeTo(0.0045, 1e-9));
      now = now.add(const Duration(hours: 25));
      expect(engine.autoSpent(), 0);
    });
  });

  group('restarts and failures (CB-13, CB-16)', () {
    test(
      'a storage failure inside a job never escapes as an uncaught error',
      () async {
        final errors = <Object>[];
        await runZonedGuarded(() async {
          final failing = _FailingStore(store.db);
          final local = WorkerEngine(
            failing,
            transport,
            transcriber,
            clock: () => now,
          );
          final source = _source(r'$storage');
          local.accept(
            _op(
              'request',
              'transcript.request',
              transcriptEntityId(source),
              _request(source),
            ),
          );
          failing.failSaves = true;
          await local.tick();
          await local.waitForIdle();
          await Future<void>.delayed(Duration.zero);
        }, (error, _) => errors.add(error));
        expect(errors, isEmpty);
      },
    );
  });
}

class _FailingStore extends WorkerStore {
  bool failSaves = false;
  _FailingStore(super.db);
  @override
  void saveJob(Map<String, dynamic> body) {
    if (failSaves) throw StateError('synthetic storage failure');
    super.saveJob(body);
  }
}

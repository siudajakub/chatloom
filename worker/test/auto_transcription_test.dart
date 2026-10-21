// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/engine.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

const account = '@self:example.invalid';
const room = '!telegram:beeper.local';

class FakeTransport implements FeatureTransport, MediaPreflight {
  @override
  String get accountId => account;
  @override
  String get deviceId => 'TEST_DEVICE';
  @override
  bool get verified => true;
  final loads = <String>[];

  /// Events whose media bytes are identical (forwards, merged chats).
  final sharedMedia = <String, List<int>>{};

  /// Declared metadata; small declared size unless overridden (null facts
  /// = metadata unavailable).
  final facts = <String, MediaFacts?>{};
  @override
  Future<MediaFacts?> mediaFacts(SourceEventRef source) async =>
      facts.containsKey(source.eventId)
      ? facts[source.eventId]
      : const MediaFacts(sizeBytes: 3);
  @override
  Future<bool?> sourceRedacted(SourceEventRef source) async => false;
  @override
  Future<AudioSource> loadAudio(
    SourceEventRef source,
    Cancellation cancel,
  ) async {
    loads.add(source.eventId);
    // Distinct bytes per source: identical media would share a transcript.
    return AudioSource(
      Uint8List.fromList(
        sharedMedia[source.eventId] ?? utf8.encode(source.eventId),
      ),
      'video/mp4',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected conversation operation');
}

/// Mirrors OpenAiTranscriber: estimate() is the pre-upload gate.
class MeasuringTranscriber implements Transcriber {
  double duration = 30;
  final uploads = <String>[];
  final languages = <String?>[];
  @override
  Future<TranscriptionResult> transcribe(
    AudioSource audio,
    String? language,
    Cancellation cancel,
    void Function(double, double) estimate,
  ) async {
    final cost = duration / 60 * 0.0045;
    estimate(duration, cost);
    cancel.check();
    uploads.add(audio.mimeType);
    languages.add(language);
    return TranscriptionResult('synthetic transcript', duration, cost);
  }
}

class FakeScanner implements RecentSourceScanner {
  final pages = <RecentSourcePage?>[];
  final calls = <(int?, DateTime?)>[];
  final reelRequests = <bool>[];
  Object? failure;
  @override
  Future<RecentSourcePage?> recent({
    required int? cursor,
    DateTime? since,
    int limit = 100,
    bool reels = false,
  }) async {
    calls.add((cursor, since));
    reelRequests.add(reels);
    if (failure != null) throw failure!;
    return pages.isEmpty ? null : pages.removeAt(0);
  }
}

/// Received a minute before the tests' initial clock unless given.
final recently = DateTime.utc(2026, 10, 17, 11, 59);
const undated = Object();

RecentSourceItem item(
  String event, {
  String roomId = room,
  AutoTranscriptionKind kind = AutoTranscriptionKind.voice,
  int? durationMs = 20000,
  String network = 'telegram',
  Object? timestamp,
}) => RecentSourceItem(
  roomId: roomId,
  eventId: event,
  kind: kind,
  network: network,
  durationMs: durationMs,
  timestamp: identical(timestamp, undated)
      ? null
      : timestamp as DateTime? ?? recently,
);

String entity(String event, {String roomId = room}) => transcriptEntityId(
  SourceEventRef(
    conversation: ConversationRef(accountId: account, roomId: roomId),
    eventId: event,
  ),
);

PersonalOperation op(
  String id,
  String kind,
  String entityId,
  Map<String, dynamic> payload, {
  int revision = 0,
}) => PersonalOperation(
  opId: id,
  kind: kind,
  entityId: entityId,
  baseRevision: revision,
  createdAt: DateTime.utc(2026, 10, 17),
  payload: payload,
);

void main() {
  late WorkerStore store;
  late FakeTransport transport;
  late MeasuringTranscriber transcriber;
  late FakeScanner scanner;
  late WorkerEngine engine;
  var now = DateTime.utc(2026, 10, 17, 12);

  WorkerEngine build({bool auto = true, int concurrency = 2}) => WorkerEngine(
    store,
    transport,
    transcriber,
    clock: () => now,
    recentSources: scanner,
    autoTranscription: auto,
    maxConcurrentTranscripts: concurrency,
  );

  void putPolicy(TranscriptionPolicy policy) {
    final old = store.metadata(transcriptionPolicyEntity);
    engine.accept(
      op(
        'policy-${old?['revision'] ?? 0}',
        'metadata.put',
        transcriptionPolicyEntity,
        {'value': policy.toJson()},
        revision: old?['revision'] as int? ?? 0,
      ),
    );
  }

  void putMetadata(String id, Map<String, dynamic> value) =>
      engine.accept(op('meta-$id', 'metadata.put', id, {'value': value}));

  Future<void> runJobs() async {
    for (var i = 0; i < 6; i++) {
      await engine.tick();
      await engine.waitForIdle();
    }
  }

  setUp(() {
    now = DateTime.utc(2026, 10, 17, 12);
    store = WorkerStore(sqlite3.openInMemory());
    transport = FakeTransport();
    transcriber = MeasuringTranscriber();
    scanner = FakeScanner();
    engine = build();
  });
  tearDown(() async {
    await engine.waitForIdle();
    store.close();
  });

  test('entity id matches the app formula over package:crypto', () {
    for (final roomId in [room, '!ünïcödé/?#:beeper.local']) {
      final source = SourceEventRef(
        conversation: ConversationRef(
          accountId: account,
          roomId: roomId,
          network: 'telegram',
        ),
        eventId: r'$event',
      );
      expect(
        transcriptEntityId(source),
        'transcript:${sha256.convert(utf8.encode(source.key))}',
      );
    }
  });

  test(
    'operator switch off never scans, even with the default policy',
    () async {
      engine = build(auto: false);
      expect(engine.autoScanActive, isFalse);
      expect(await engine.autoScan(force: true), 0);
      expect(scanner.calls, isEmpty);
      expect(store.jobs(), isEmpty);
    },
  );

  test(
    'first scan records the position only; later items become auto jobs',
    () async {
      scanner.pages.add(const RecentSourcePage(40, []));
      expect(await engine.autoScan(force: true), 0);
      expect(scanner.calls.single.$1, isNull);
      expect(store.checkpoint(WorkerEngine.autoScanCheckpoint), '40');
      expect(store.jobs(), isEmpty);

      scanner.pages.add(
        RecentSourcePage(43, [
          item(r'$voice'),
          item(r'$round', kind: AutoTranscriptionKind.round),
        ]),
      );
      expect(await engine.autoScan(force: true), 2);
      expect(scanner.calls.last.$1, 40);
      // Never further back than the 24 h window when no enable time exists.
      expect(scanner.calls.last.$2, now.subtract(autoTranscriptionMaxAge));
      expect(store.checkpoint(WorkerEngine.autoScanCheckpoint), '43');
      final job = store.job(entity(r'$voice'))!;
      expect(job['origin'], 'auto');
      expect(job['state'], 'queued');
      expect(job['revision'], 1);
      expect(job['createdAt'], now.toIso8601String());
      final results = store.outbox
          .where((e) => e['kind'] == 'transcript.result')
          .toList();
      expect(results, hasLength(2));
      expect(results.first['payload']['origin'], 'auto');
      expect(results.first['payload']['source']['eventId'], r'$voice');
      expect(results.first['payload'].containsKey('text'), isTrue);

      // Re-reporting the same messages never creates a second job.
      scanner.pages.add(RecentSourcePage(44, [item(r'$voice')]));
      expect(await engine.autoScan(force: true), 0);
      expect(store.checkpoint(WorkerEngine.autoScanCheckpoint), '44');

      await runJobs();
      expect(store.job(entity(r'$voice'))!['state'], 'done');
      expect(store.job(entity(r'$round'))!['state'], 'done');
      expect(transcriber.uploads, ['video/mp4', 'video/mp4']);
    },
  );

  test(
    'Instagram reels are on demand unless the policy switches them on',
    () async {
      scanner.pages.add(const RecentSourcePage(1, []));
      await engine.autoScan(force: true);
      expect(scanner.reelRequests.last, isFalse);
      // A reel reported anyway (an older adapter) still creates no job.
      scanner.pages.add(
        RecentSourcePage(3, [
          item(
            r'$reel',
            kind: AutoTranscriptionKind.reel,
            network: 'instagram',
          ),
          item(
            r'$clip',
            kind: AutoTranscriptionKind.video,
            network: 'instagram',
          ),
        ]),
      );
      expect(await engine.autoScan(force: true), 1);
      expect(scanner.reelRequests.last, isFalse);
      expect(store.job(entity(r'$reel')), isNull);
      expect(store.job(entity(r'$clip'))!['mediaKind'], 'video');

      putPolicy(
        const TranscriptionPolicy().withKind(AutoTranscriptionKind.reel, true),
      );
      scanner.pages.add(
        RecentSourcePage(4, [
          item(
            r'$reel2',
            kind: AutoTranscriptionKind.reel,
            network: 'instagram',
          ),
        ]),
      );
      expect(await engine.autoScan(force: true), 1);
      expect(scanner.reelRequests.last, isTrue);
      expect(store.job(entity(r'$reel2'))!['mediaKind'], 'reel');
    },
  );

  test('scan interval, busy source and failures keep the cursor', () async {
    store.setCheckpoint(WorkerEngine.autoScanCheckpoint, '7');
    expect(await engine.autoScan(), 0); // busy: null page
    expect(await engine.autoScan(), 0); // within interval: no call
    expect(scanner.calls, hasLength(1));
    scanner.failure = const WorkerFailure('local_source_unavailable');
    now = now.add(WorkerEngine.autoScanInterval);
    expect(await engine.autoScan(), 0);
    expect(scanner.calls, hasLength(2));
    expect(store.checkpoint(WorkerEngine.autoScanCheckpoint), '7');
  });

  test(
    'turning the policy off clears the cursor; re-enable skips history',
    () async {
      store.setCheckpoint(WorkerEngine.autoScanCheckpoint, '7');
      putPolicy(TranscriptionPolicy.defaults.withAuto(false, now));
      expect(await engine.autoScan(force: true), 0);
      expect(scanner.calls, isEmpty);
      expect(store.checkpoint(WorkerEngine.autoScanCheckpoint), '');
      final enabled = now.add(const Duration(hours: 1));
      now = enabled;
      putPolicy(engine.autoPolicy().withAuto(true, enabled));
      scanner.pages.add(const RecentSourcePage(90, []));
      await engine.autoScan(force: true);
      expect(scanner.calls.single.$1, isNull);
      expect(store.checkpoint(WorkerEngine.autoScanCheckpoint), '90');
      scanner.pages.add(RecentSourcePage(91, [item(r'$new')]));
      await engine.autoScan(force: true);
      expect(scanner.calls.last.$2, enabled);
    },
  );

  test(
    'muted, ignored, never, disabled network and grouped people are skipped',
    () async {
      store.setCheckpoint(WorkerEngine.autoScanCheckpoint, '1');
      putMetadata('org:!muted:beeper.local', {'muted': true});
      putMetadata('org:!ignored:beeper.local', {'ignored': true});
      putMetadata('person:p1', {
        'id': 'p1',
        'members': [
          {'accountId': account, 'roomId': '!grouped:beeper.local'},
        ],
      });
      putMetadata('org:person:p1', {'placement': 'ignored'});
      putMetadata('network-policy:signal', {'notifications': 'muted'});
      putPolicy(
        TranscriptionPolicy.defaults
            .withChatOverride('!never:beeper.local', false)
            .withNetwork('whatsapp', false),
      );
      scanner.pages.add(
        RecentSourcePage(9, [
          item(r'$a', roomId: '!muted:beeper.local'),
          item(r'$b', roomId: '!ignored:beeper.local'),
          item(r'$c', roomId: '!grouped:beeper.local'),
          item(r'$d', roomId: '!never:beeper.local'),
          item(r'$e', roomId: '!wa:beeper.local', network: 'whatsapp'),
          item(r'$f', roomId: '!sig:beeper.local', network: 'signal'),
          item(r'$g', roomId: '!unknown:beeper.local', network: 'unknown'),
          item(r'$h', timestamp: now.subtract(const Duration(hours: 25))),
          item(r'$ok'),
        ]),
      );
      expect(await engine.autoScan(force: true), 1);
      expect(store.job(entity(r'$ok')), isNotNull);
      expect(
        store.jobs().where((j) => j['kind'] == 'transcript'),
        hasLength(1),
      );
      expect(store.checkpoint(WorkerEngine.autoScanCheckpoint), '9');
    },
  );

  test('over-long and over-budget messages are recorded as skipped', () async {
    store.setCheckpoint(WorkerEngine.autoScanCheckpoint, '1');
    putPolicy(TranscriptionPolicy.defaults.copyWith(maxSeconds: 60));
    scanner.pages.add(RecentSourcePage(2, [item(r'$long', durationMs: 61000)]));
    await engine.autoScan(force: true);
    final long = store.job(entity(r'$long'))!;
    expect(long['state'], 'cancelled');
    expect(long['errorCode'], 'auto_skipped_duration');
    // Spent budget within 24 h blocks further automatic work.
    store.saveJob({
      ...long,
      'id': 'transcript:spent',
      'state': 'done',
      'estimatedCostUsd': 1.0,
    });
    scanner.pages.add(RecentSourcePage(3, [item(r'$late')]));
    await engine.autoScan(force: true);
    expect(store.job(entity(r'$late'))!['errorCode'], 'auto_skipped_budget');
    await runJobs();
    expect(transport.loads, isEmpty);
    expect(transcriber.uploads, isEmpty);
  });

  test(
    'measured duration and budget stop auto jobs before any upload',
    () async {
      store.setCheckpoint(WorkerEngine.autoScanCheckpoint, '1');
      putPolicy(
        TranscriptionPolicy.defaults.copyWith(
          maxSeconds: 60,
          dailyBudgetUsd: 0.01,
        ),
      );
      // Unknown advertised duration: the worker measures it first.
      scanner.pages.add(
        RecentSourcePage(2, [item(r'$long', durationMs: null)]),
      );
      await engine.autoScan(force: true);
      transcriber.duration = 61;
      await runJobs();
      expect(store.job(entity(r'$long'))!['state'], 'cancelled');
      expect(
        store.job(entity(r'$long'))!['errorCode'],
        'auto_skipped_duration',
      );
      expect(transcriber.uploads, isEmpty);

      transcriber.duration = 59; // ~0.0044 USD each
      scanner.pages.add(
        RecentSourcePage(4, [item(r'$one'), item(r'$two'), item(r'$three')]),
      );
      await engine.autoScan(force: true);
      await runJobs();
      expect(store.job(entity(r'$one'))!['state'], 'done');
      expect(store.job(entity(r'$two'))!['state'], 'done');
      expect(store.job(entity(r'$three'))!['state'], 'cancelled');
      expect(store.job(entity(r'$three'))!['errorCode'], 'auto_skipped_budget');
      expect(transcriber.uploads, hasLength(2));
      expect(engine.autoSpent(), closeTo(2 * 59 / 60 * 0.0045, 1e-9));
      // Automatic estimates are durable but not separately published.
      final states = store.outbox
          .where((e) => e['entityId'] == entity(r'$one'))
          .map((e) => e['payload']['state'])
          .toList();
      expect(states, ['queued', 'processing', 'done']);
    },
  );

  test('manual requests run before queued automatic work', () async {
    engine = build(concurrency: 1);
    store.setCheckpoint(WorkerEngine.autoScanCheckpoint, '1');
    scanner.pages.add(RecentSourcePage(2, [item(r'$auto')]));
    await engine.autoScan(force: true);
    final manual = SourceEventRef(
      conversation: const ConversationRef(accountId: account, roomId: room),
      eventId: r'$manual',
    );
    final manualId = transcriptEntityId(manual);
    engine.accept(
      op(
        'manual',
        'transcript.request',
        manualId,
        Map<String, dynamic>.from(
          TranscriptionJob(
            id: manualId,
            source: manual,
            state: JobState.queued,
            language: 'hy',
          ).toJson(),
        ),
      ),
    );
    await engine.tick();
    await engine.waitForIdle();
    expect(transport.loads, [r'$manual']);
    expect(transcriber.languages, ['hy']);
    await runJobs();
    expect(transport.loads, [r'$manual', r'$auto']);
  });

  test(
    'switching the policy off cancels queued automatic jobs unpaid',
    () async {
      store.setCheckpoint(WorkerEngine.autoScanCheckpoint, '1');
      scanner.pages.add(RecentSourcePage(2, [item(r'$auto')]));
      await engine.autoScan(force: true);
      putPolicy(TranscriptionPolicy.defaults.withAuto(false, now));
      await runJobs();
      expect(store.job(entity(r'$auto'))!['state'], 'cancelled');
      expect(store.job(entity(r'$auto'))!['errorCode'], 'auto_disabled');
      expect(transport.loads, isEmpty);
    },
  );

  test('an item without a timestamp is too old and creates no job', () async {
    store.setCheckpoint(WorkerEngine.autoScanCheckpoint, '1');
    scanner.pages.add(
      RecentSourcePage(3, [
        item(r'$undated', timestamp: undated),
        item(r'$ok'),
      ]),
    );
    expect(await engine.autoScan(force: true), 1);
    expect(store.job(entity(r'$undated')), isNull);
    expect(store.job(entity(r'$ok'))!['state'], 'queued');
  });

  group('operator switch off', () {
    final source = SourceEventRef(
      conversation: const ConversationRef(
        accountId: account,
        roomId: '!cloud:example.invalid',
      ),
      eventId: r'$client',
    );
    final id = transcriptEntityId(source);
    PersonalOperation request(String opId, TranscriptionOrigin origin) => op(
      opId,
      'transcript.request',
      id,
      Map<String, dynamic>.from(
        TranscriptionJob(
          id: id,
          source: source,
          state: JobState.waitingSync,
          origin: origin,
        ).toJson(),
      ),
    );

    test('client requests with origin auto are rejected unpaid', () async {
      engine = build(auto: false);
      engine.accept(request('client-auto', TranscriptionOrigin.auto));
      expect(store.job(id), isNull);
      final result = store.outbox
          .where((e) => e['kind'] == 'transcript.result')
          .single['payload'];
      expect(result['state'], 'conflict');
      expect(result['errorCode'], 'auto_disabled');
      await runJobs();
      expect(transport.loads, isEmpty);
      expect(transcriber.uploads, isEmpty);
      // The user's explicit request still works.
      engine.accept(request('client-manual', TranscriptionOrigin.manual));
      await runJobs();
      expect(store.job(id)!['state'], 'done');
      expect(transport.loads, [r'$client']);
    });

    test('queued automatic jobs are cancelled after a restart without the '
        'switch, and the scan position is forgotten', () async {
      store.setCheckpoint(WorkerEngine.autoScanCheckpoint, '1');
      scanner.pages.add(RecentSourcePage(2, [item(r'$auto')]));
      await engine.autoScan(force: true);
      expect(store.job(entity(r'$auto'))!['state'], 'queued');
      engine = build(auto: false)..recover();
      expect(store.checkpoint(WorkerEngine.autoScanCheckpoint), '');
      await runJobs();
      expect(store.job(entity(r'$auto'))!['state'], 'cancelled');
      expect(store.job(entity(r'$auto'))!['errorCode'], 'auto_disabled');
      expect(transport.loads, isEmpty);
      expect(await engine.autoScan(force: true), 0);
      expect(scanner.calls, hasLength(1));
    });
  });

  test('client catch-up requests keep auto origin and its limits', () async {
    final source = SourceEventRef(
      conversation: const ConversationRef(
        accountId: account,
        roomId: '!cloud:example.invalid',
      ),
      eventId: r'$catchup',
    );
    final id = transcriptEntityId(source);
    putPolicy(TranscriptionPolicy.defaults.copyWith(maxSeconds: 10));
    engine.accept(
      op(
        'catchup',
        'transcript.request',
        id,
        Map<String, dynamic>.from(
          TranscriptionJob(
            id: id,
            source: source,
            state: JobState.waitingSync,
            origin: TranscriptionOrigin.auto,
          ).toJson(),
        ),
      ),
    );
    expect(store.job(id)!['origin'], 'auto');
    expect(store.job(id)!['createdAt'], now.toIso8601String());
    await runJobs();
    expect(store.job(id)!['errorCode'], 'auto_skipped_duration');
    expect(transcriber.uploads, isEmpty);
    // An explicit retry is manual and not bound by automatic limits.
    engine.accept(
      op(
        'retry',
        'transcript.request',
        id,
        Map<String, dynamic>.from(
          TranscriptionJob(
            id: id,
            source: source,
            state: JobState.queued,
          ).toJson(),
        ),
        revision: store.job(id)!['revision'] as int,
      ),
    );
    await runJobs();
    expect(store.job(id)!['state'], 'done');
    expect(store.job(id)!.containsKey('origin'), isFalse);
  });

  test(
    'unsupported languages are rejected; Armenian reaches the provider',
    () async {
      final source = SourceEventRef(
        conversation: const ConversationRef(accountId: account, roomId: room),
        eventId: r'$lang',
      );
      final id = transcriptEntityId(source);
      Map<String, dynamic> body(Object? language) => {
        ...TranscriptionJob(
          id: id,
          source: source,
          state: JobState.queued,
        ).toJson(),
        'language': language,
      };
      for (final language in ['de', 'HY', 7]) {
        final request = op(
          'bad-$language',
          'transcript.request',
          id,
          body(language),
        );
        expect(
          () => engine.accept(request),
          throwsA(
            isA<WorkerFailure>().having(
              (e) => e.code,
              'code',
              'invalid_language',
            ),
          ),
        );
        engine.rejectInvalid(request, 'invalid_language');
        expect(store.outbox.last['payload']['errorCode'], 'invalid_language');
        expect(store.job(id), isNull);
      }
      engine.accept(op('good', 'transcript.request', id, body('hy')));
      await runJobs();
      expect(transcriber.languages, ['hy']);
      expect(store.job(id)!['language'], 'hy');
    },
  );

  test(
    'reminder payload keeps only documented fields and a bounded anchor',
    () {
      final conversation = const ConversationRef(
        accountId: account,
        roomId: room,
        network: 'telegram',
      ).toJson();
      engine.accept(
        op('reminder', 'reminder.create', 'r1', {
          'id': 'r1',
          'conversation': {...conversation, 'extra': 'dropped'},
          'dueAt': now.toIso8601String(),
          'untilReply': true,
          'anchorEventId': r'$anchor',
          'note': 'private text must not be stored',
        }),
      );
      final stored = store.job('r1')!;
      expect(stored['anchorEventId'], r'$anchor');
      expect(stored['untilReply'], true);
      expect(stored.containsKey('note'), isFalse);
      expect(stored['conversation'], conversation);
      expect(
        jsonEncode(store.outbox.last),
        isNot(contains('private text must not be stored')),
      );
      for (final anchor in ['no-dollar', '\$${'x' * 255}', 5]) {
        expect(
          () => engine.accept(
            op('reminder-$anchor', 'reminder.create', 'r-$anchor', {
              'id': 'r-$anchor',
              'conversation': conversation,
              'dueAt': now.toIso8601String(),
              'anchorEventId': anchor,
            }),
          ),
          throwsA(isA<WorkerFailure>()),
        );
      }
      engine.accept(
        op('reminder-plain', 'reminder.create', 'r2', {
          'id': 'r2',
          'conversation': conversation,
          'dueAt': now.toIso8601String(),
        }),
      );
      expect(store.job('r2')!.containsKey('anchorEventId'), isFalse);
      expect(store.job('r2')!.containsKey('untilReply'), isFalse);
    },
  );
}

// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Engine pipeline: live (Matrix sync) feed, preflight limits before
// download, bounded concurrency, newest-first priority, media dedupe,
// transient backoff and silent-video handling. Fake transport/provider only.
import 'dart:async';
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
const cloudRoom = '!cloud:beeper.com';

class _Transport
    implements FeatureTransport, MediaPreflight, BoundedAudioLoader {
  @override
  String get accountId => account;
  @override
  String get deviceId => 'TEST_DEVICE';
  @override
  bool get verified => true;
  final loads = <String>[];

  /// Declared metadata; a small declared size unless set (null = none).
  final facts = <String, MediaFacts?>{};

  /// (event, maxBytes, requireDeclaredSize) of every bounded load.
  final bounds = <(String, int, bool)>[];
  int inFlight = 0;
  int maxInFlight = 0;
  final media = <String, List<int>>{};

  /// Failure codes thrown by successive loads of an event.
  final failures = <String, List<String>>{};
  final holds = <String, Completer<void>>{};
  @override
  Future<bool?> sourceRedacted(SourceEventRef source) async => false;
  @override
  Future<MediaFacts?> mediaFacts(SourceEventRef source) async =>
      facts.containsKey(source.eventId)
      ? facts[source.eventId]
      : const MediaFacts(sizeBytes: 64);
  @override
  Future<AudioSource> loadAudioBounded(
    SourceEventRef source,
    Cancellation cancel, {
    required int maxBytes,
    required bool requireDeclaredSize,
  }) async {
    bounds.add((source.eventId, maxBytes, requireDeclaredSize));
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      // Simulates the streaming cap of the real transports.
      await Future<void>.delayed(Duration.zero);
      final audio = await loadAudio(source, cancel);
      if (audio.bytes.length > maxBytes) {
        throw const WorkerFailure('source_too_large');
      }
      return audio;
    } finally {
      inFlight--;
    }
  }

  @override
  Future<AudioSource> loadAudio(
    SourceEventRef source,
    Cancellation cancel,
  ) async {
    loads.add(source.eventId);
    await holds[source.eventId]?.future;
    final queue = failures[source.eventId];
    if (queue != null && queue.isNotEmpty) {
      throw WorkerFailure(queue.removeAt(0));
    }
    return AudioSource(
      Uint8List.fromList(media[source.eventId] ?? utf8.encode(source.eventId)),
      'video/mp4',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected conversation operation');
}

class _Transcriber implements Transcriber {
  double duration = 20;
  final uploads = <int>[];
  String? failure;
  @override
  Future<TranscriptionResult> transcribe(
    AudioSource audio,
    String? language,
    Cancellation cancel,
    void Function(double, double) estimate,
  ) async {
    final bytes = audio.takeBytes();
    if (failure != null) throw WorkerFailure(failure!);
    final cost = duration / 60 * 0.0045;
    estimate(duration, cost);
    uploads.add(bytes.length);
    return TranscriptionResult('text ${utf8.decode(bytes)}', duration, cost);
  }
}

class _Feed implements LiveSourceFeed {
  final items = <RecentSourceItem>[];
  bool isActive = true;
  Completer<void> _wake = Completer<void>();
  @override
  set active(bool value) => isActive = value;
  @override
  Future<List<RecentSourceItem>> drain() async {
    final out = List.of(items);
    items.clear();
    return out;
  }

  @override
  Future<void> get wakeup => _wake.future;
  void push(RecentSourceItem item) {
    items.add(item);
    if (!_wake.isCompleted) _wake.complete();
    _wake = Completer<void>();
  }
}

RecentSourceItem live(
  String event, {
  AutoTranscriptionKind kind = AutoTranscriptionKind.video,
  DateTime? at,
  int? durationMs = 20000,
}) => RecentSourceItem(
  roomId: cloudRoom,
  eventId: event,
  kind: kind,
  network: 'whatsapp',
  durationMs: durationMs,
  timestamp: at,
);

String entity(String event) => transcriptEntityId(
  SourceEventRef(
    conversation: const ConversationRef(accountId: account, roomId: cloudRoom),
    eventId: event,
  ),
);

void main() {
  late WorkerStore store;
  late _Transport transport;
  late _Transcriber transcriber;
  late _Feed feed;
  late WorkerEngine engine;
  var now = DateTime.utc(2026, 10, 19, 12);

  WorkerEngine build({int concurrency = 2, bool auto = true}) => WorkerEngine(
    store,
    transport,
    transcriber,
    clock: () => now,
    liveSources: feed,
    autoTranscription: auto,
    maxConcurrentTranscripts: concurrency,
  );

  Future<void> runJobs() async {
    for (var i = 0; i < 6; i++) {
      await engine.tick();
      await engine.waitForIdle();
    }
  }

  Map<String, dynamic> job(String event) => store.job(entity(event))!;

  void putPolicy(TranscriptionPolicy policy) {
    final old = store.metadata(transcriptionPolicyEntity);
    engine.accept(
      PersonalOperation(
        opId: 'policy-${old?['revision'] ?? 0}',
        kind: 'metadata.put',
        entityId: transcriptionPolicyEntity,
        baseRevision: old?['revision'] as int? ?? 0,
        createdAt: now,
        payload: {'value': policy.toJson()},
      ),
    );
  }

  /// Activates the live window, then delivers [items] received after it.
  Future<void> deliver(List<RecentSourceItem> items) async {
    await engine.autoScan();
    for (final item in items) {
      feed.push(item);
    }
    await engine.autoScan();
  }

  setUp(() {
    now = DateTime.utc(2026, 10, 19, 12);
    store = WorkerStore(sqlite3.openInMemory());
    transport = _Transport();
    transcriber = _Transcriber();
    feed = _Feed();
    engine = build();
  });
  tearDown(() async {
    await engine.waitForIdle();
    store.close();
  });

  test('live feed: a fresh video in a cloud room becomes a job at once, '
      'nothing from before activation', () async {
    feed.push(live(r'$before', at: now.subtract(const Duration(seconds: 5))));
    await engine.autoScan();
    expect(store.jobs(), isEmpty, reason: 'window starts on activation');
    expect(
      store.checkpoint(WorkerEngine.autoLiveCheckpoint),
      now.toIso8601String(),
    );
    now = now.add(const Duration(seconds: 1));
    feed.push(live(r'$video', at: now));
    feed.push(live(r'$voice', kind: AutoTranscriptionKind.voice, at: now));
    expect(await engine.autoScan(), 2);
    expect(job(r'$video')['origin'], 'auto');
    expect(job(r'$video')['source']['conversation']['network'], 'whatsapp');
    await runJobs();
    expect(job(r'$video')['state'], 'done');
    expect(job(r'$voice')['state'], 'done');
    expect(engine.liveScanActive, isTrue);
    expect(engine.autoScanActive, isTrue);
  });

  test('live feed respects policy kinds and the off switch', () async {
    putPolicy(
      TranscriptionPolicy.defaults.withKind(AutoTranscriptionKind.video, false),
    );
    await deliver([
      live(r'$video', at: now),
      live(r'$audio', kind: AutoTranscriptionKind.audio, at: now),
    ]);
    expect(store.job(entity(r'$video')), isNull);
    expect(job(r'$audio')['state'], 'queued');
    putPolicy(TranscriptionPolicy.defaults.withAuto(false, now));
    feed.push(live(r'$later', at: now));
    await engine.autoScan();
    expect(feed.isActive, isFalse);
    expect(store.job(entity(r'$later')), isNull);
    expect(store.checkpoint(WorkerEngine.autoLiveCheckpoint), '');
    // Without the operator switch nothing is collected or created.
    engine = build(auto: false);
    feed.push(live(r'$off', at: now));
    expect(await engine.autoScan(), 0);
    expect(engine.autoScanActive, isFalse);
  });

  test('declared over-long, oversized or disabled media is skipped before '
      'download', () async {
    putPolicy(
      TranscriptionPolicy.defaults
          .copyWith(maxSeconds: 60)
          .withKind(AutoTranscriptionKind.audio, false),
    );
    // The feed does not know the duration; metadata does.
    transport.facts[r'$long'] = const MediaFacts(
      kind: AutoTranscriptionKind.video,
      durationMs: 61000,
      sizeBytes: 1000,
    );
    transport.facts[r'$huge'] = const MediaFacts(
      kind: AutoTranscriptionKind.video,
      sizeBytes: autoMediaMaxBytes + 1,
    );
    transport.facts[r'$file'] = const MediaFacts(
      kind: AutoTranscriptionKind.audio,
      sizeBytes: 1000,
    );
    await deliver([
      live(r'$long', at: now, durationMs: null),
      live(r'$huge', at: now, durationMs: null),
      // Classified as video by the sync, as audio by fresh metadata.
      live(r'$file', at: now, durationMs: null),
    ]);
    await runJobs();
    expect(job(r'$long')['errorCode'], 'auto_skipped_duration');
    expect(job(r'$huge')['errorCode'], 'auto_skipped_size');
    expect(job(r'$file')['errorCode'], 'auto_skipped_kind');
    for (final event in [r'$long', r'$huge', r'$file']) {
      expect(job(event)['state'], 'cancelled');
    }
    expect(transport.loads, isEmpty, reason: 'nothing was downloaded');
    expect(transcriber.uploads, isEmpty);
  });

  test('two jobs run in parallel, newest automatic message first', () async {
    engine = build(concurrency: 2);
    await engine.autoScan();
    for (final (index, event) in [r'$a', r'$b', r'$c'].indexed) {
      now = now.add(const Duration(seconds: 1));
      transport.holds[event] = Completer<void>();
      feed.push(live(event, at: now));
      await engine.autoScan();
      expect(job(event)['createdAt'], isNotNull, reason: '$index');
    }
    await engine.tick();
    expect(engine.activeTranscripts, 2);
    for (var i = 0; i < 50 && transport.loads.length < 2; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(transport.loads, [r'$c', r'$b']);
    for (final hold in transport.holds.values) {
      hold.complete();
    }
    await runJobs();
    expect(transport.loads, [r'$c', r'$b', r'$a']);
    for (final event in [r'$a', r'$b', r'$c']) {
      expect(job(event)['state'], 'done');
    }
  });

  test('a finished transcript wakes the daemon to publish it', () async {
    await deliver([live(r'$wake', at: now)]);
    final wake = engine.wakeup;
    await engine.tick();
    await wake.timeout(const Duration(seconds: 2));
    await engine.waitForIdle();
    expect(job(r'$wake')['state'], 'done');
  });

  test(
    'identical media reuses the transcript without another upload',
    () async {
      transport.media[r'$original'] = utf8.encode('same clip');
      transport.media[r'$forward'] = utf8.encode('same clip');
      await deliver([live(r'$original', at: now)]);
      await runJobs();
      now = now.add(const Duration(seconds: 5));
      feed.push(live(r'$forward', at: now));
      await engine.autoScan();
      await runJobs();
      expect(transcriber.uploads, hasLength(1));
      expect(job(r'$forward')['state'], 'done');
      expect(job(r'$forward')['text'], job(r'$original')['text']);
      expect(job(r'$forward')['estimatedCostUsd'], 0);
      expect(engine.autoSpent(), closeTo(20 / 60 * 0.0045, 1e-9));
    },
  );

  test('a redacted original is not reused', () async {
    transport.media[r'$original'] = utf8.encode('same clip');
    transport.media[r'$copy'] = utf8.encode('same clip');
    await deliver([live(r'$original', at: now)]);
    await runJobs();
    final original = job(r'$original')..['text'] = null;
    store.saveJob(original);
    feed.push(live(r'$copy', at: now));
    await engine.autoScan();
    await runJobs();
    expect(transcriber.uploads, hasLength(2));
  });

  test('transient failures back off and retry without a busy loop', () async {
    transport.failures[r'$busy'] = ['local_source_unavailable'];
    await deliver([live(r'$busy', at: now)]);
    await runJobs();
    expect(job(r'$busy')['state'], 'queued');
    expect(job(r'$busy')['errorCode'], 'local_source_unavailable');
    expect(transport.loads, [r'$busy'], reason: 'not retried before due');
    now = now.add(const Duration(seconds: 16));
    await runJobs();
    expect(job(r'$busy')['state'], 'done');
    expect(job(r'$busy').containsKey('retries'), isFalse);
    expect(transport.loads, [r'$busy', r'$busy']);
  });

  test(
    'missing keys wait with backoff instead of reloading every tick',
    () async {
      transport.failures[r'$keys'] = ['waiting_keys', 'waiting_keys'];
      await deliver([live(r'$keys', at: now)]);
      await runJobs();
      expect(job(r'$keys')['state'], 'waitingKeys');
      expect(transport.loads, hasLength(1));
      now = now.add(const Duration(seconds: 16));
      await runJobs();
      expect(transport.loads, hasLength(2));
      expect(job(r'$keys')['state'], 'waitingKeys');
      now = now.add(const Duration(seconds: 30));
      await runJobs();
      expect(transport.loads, hasLength(2), reason: 'second wait is 1 min');
      now = now.add(const Duration(seconds: 31));
      await runJobs();
      expect(job(r'$keys')['state'], 'done');
    },
  );

  test('new room keys retry key-waiting jobs at once', () async {
    transport.failures[r'$late-keys'] = ['waiting_keys'];
    await deliver([live(r'$late-keys', at: now)]);
    await runJobs();
    expect(job(r'$late-keys')['state'], 'waitingKeys');
    expect(transport.loads, hasLength(1));
    // Without keys arriving the job waits for its backoff.
    await runJobs();
    expect(transport.loads, hasLength(1));
    // A to-device room key arrived: no waiting for the backoff.
    expect(engine.retryWaitingKeys(), 1);
    await runJobs();
    expect(job(r'$late-keys')['state'], 'done');
    expect(transport.loads, hasLength(2));
    expect(engine.retryWaitingKeys(), 0, reason: 'nothing left to wake');
  });

  test('retry budget is bounded for persistent provider overload', () async {
    transcriber.failure = 'openai_unavailable';
    await deliver([live(r'$down', at: now)]);
    for (var i = 0; i < 8; i++) {
      await runJobs();
      now = now.add(const Duration(minutes: 30));
    }
    expect(job(r'$down')['state'], 'failed');
    expect(job(r'$down')['errorCode'], 'openai_unavailable');
    expect(transport.loads, hasLength(WorkerEngine.transientRetryLimit + 1));
  });

  test('a video without audio is dropped silently when automatic, reported '
      'when requested manually', () async {
    transcriber.failure = 'no_audio_track';
    await deliver([live(r'$gif', at: now)]);
    await runJobs();
    expect(job(r'$gif')['state'], 'cancelled');
    expect(job(r'$gif')['errorCode'], 'no_audio_track');
    final manual = SourceEventRef(
      conversation: const ConversationRef(
        accountId: account,
        roomId: cloudRoom,
      ),
      eventId: r'$manual',
    );
    final id = transcriptEntityId(manual);
    engine.accept(
      PersonalOperation(
        opId: 'manual',
        kind: 'transcript.request',
        entityId: id,
        baseRevision: 0,
        createdAt: now,
        payload: Map<String, dynamic>.from(
          TranscriptionJob(
            id: id,
            source: manual,
            state: JobState.queued,
          ).toJson(),
        ),
      ),
    );
    await runJobs();
    expect(store.job(id)!['state'], 'failed');
    expect(store.job(id)!['errorCode'], 'no_audio_track');
  });

  group('memory bounds', () {
    test('automatic jobs of unknown size run under the small hard cap '
        'without the large slot; manual ones take it', () async {
      transport.facts[r'$nosize'] = const MediaFacts(
        kind: AutoTranscriptionKind.video,
      );
      transport.facts[r'$nometa'] = null;
      await deliver([live(r'$nosize', at: now), live(r'$nometa', at: now)]);
      await runJobs();
      for (final event in [r'$nosize', r'$nometa']) {
        expect(job(event)['state'], 'done');
      }
      expect(
        transport.bounds.map((b) => (b.$2, b.$3)),
        everyElement((largeMediaBytes, false)),
      );
      expect(transport.maxInFlight, 2, reason: 'no large slot taken');
      transport.bounds.clear();
      final manual = SourceEventRef(
        conversation: const ConversationRef(
          accountId: account,
          roomId: cloudRoom,
        ),
        eventId: r'$manual',
      );
      transport.facts[r'$manual'] = null;
      final id = transcriptEntityId(manual);
      engine.accept(
        PersonalOperation(
          opId: 'manual',
          kind: 'transcript.request',
          entityId: id,
          baseRevision: 0,
          createdAt: now,
          payload: Map<String, dynamic>.from(
            TranscriptionJob(
              id: id,
              source: manual,
              state: JobState.queued,
            ).toJson(),
          ),
        ),
      );
      await runJobs();
      expect(store.job(id)!['state'], 'done');
      // Unknown size counts as large: the full manual cap, no size demand.
      expect(transport.bounds.single, (
        r'$manual',
        transcriptionSourceMaxBytes,
        false,
      ));
    });

    test(
      'an undeclared automatic download passing the cap stops unpaid',
      () async {
        transport.facts[r'$huge'] = null;
        transport.media[r'$huge'] = List<int>.filled(largeMediaBytes + 1, 0);
        await deliver([live(r'$huge', at: now)]);
        await runJobs();
        expect(job(r'$huge')['state'], 'cancelled');
        expect(job(r'$huge')['errorCode'], 'auto_skipped_size_cap');
        expect(transcriber.uploads, isEmpty);
      },
    );

    test('small declared media is capped at the large threshold; large '
        'media takes the single large slot', () async {
      transport.facts[r'$big1'] = const MediaFacts(
        sizeBytes: largeMediaBytes + 1,
      );
      transport.facts[r'$big2'] = const MediaFacts(
        sizeBytes: largeMediaBytes + 2,
      );
      await engine.autoScan();
      for (final event in [r'$big1', r'$big2']) {
        transport.holds[event] = Completer<void>();
        now = now.add(const Duration(seconds: 1));
        feed.push(live(event, at: now));
        await engine.autoScan();
      }
      await engine.tick();
      expect(engine.activeTranscripts, 2);
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(transport.loads, [r'$big2'], reason: 'one large job at a time');
      transport.holds[r'$big2']!.complete();
      for (var i = 0; i < 50 && transport.loads.length < 2; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(transport.loads, [r'$big2', r'$big1']);
      expect(transport.maxInFlight, 1);
      transport.holds[r'$big1']!.complete();
      await runJobs();
      expect(transport.bounds.map((b) => (b.$2, b.$3)), [
        (autoMediaMaxBytes, false),
        (autoMediaMaxBytes, false),
      ]);
      // A small declared job never gets more than the threshold.
      await deliver([live(r'$small', at: now)]);
      await runJobs();
      expect(transport.bounds.last, (r'$small', largeMediaBytes, false));
      expect(job(r'$small')['state'], 'done');
    });

    test(
      'a kind switched off while the job downloads stops before upload',
      () async {
        transport.holds[r'$clip'] = Completer<void>();
        await deliver([live(r'$clip', at: now)]);
        await engine.tick();
        for (var i = 0; i < 50 && transport.loads.isEmpty; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(job(r'$clip')['mediaKind'], 'video');
        putPolicy(
          TranscriptionPolicy.defaults.withKind(
            AutoTranscriptionKind.video,
            false,
          ),
        );
        transport.holds[r'$clip']!.complete();
        await runJobs();
        expect(job(r'$clip')['state'], 'cancelled');
        expect(job(r'$clip')['errorCode'], 'auto_skipped_kind');
        expect(transcriber.uploads, isEmpty);
      },
    );

    test('large buffers hash in slices to the same digest', () async {
      final bytes = Uint8List(5 * 1024 * 1024 + 7);
      for (var i = 0; i < bytes.length; i += 4093) {
        bytes[i] = i % 251;
      }
      expect(
        await WorkerEngine.mediaDigest(bytes),
        sha256.convert(bytes).toString(),
      );
    });
  });

  group('dedupe retention', () {
    Future<void> original() async {
      transport.media[r'$original'] = utf8.encode('same clip');
      transport.media[r'$copy'] = utf8.encode('same clip');
      await deliver([live(r'$original', at: now)]);
      await runJobs();
    }

    List<String> entries() => store
        .checkpointsWithPrefix(WorkerEngine.mediaCheckpointPrefix)
        .keys
        .toList();

    test('entries expire after the TTL and are pruned', () async {
      await original();
      expect(entries(), hasLength(1));
      now = now.add(WorkerEngine.mediaDedupeTtl + const Duration(minutes: 1));
      feed.push(live(r'$copy', at: now));
      await engine.autoScan();
      await runJobs();
      expect(transcriber.uploads, hasLength(2), reason: 'expired: no reuse');
      // The copy left a fresh entry; pruning drops only expired/stale ones.
      store.setCheckpoint('${WorkerEngine.mediaCheckpointPrefix}legacy:', 'x');
      expect(engine.pruneMediaCheckpoints(), 1);
      expect(entries(), hasLength(1));
    });

    test('a redacted source forgets its entry at once', () async {
      await original();
      final current = job(r'$original');
      engine.pruneMediaCheckpoints(jobId: current['id'] as String);
      expect(entries(), isEmpty);
    });

    test(
      'the hourly tick prunes entries of jobs that lost their text',
      () async {
        await original();
        final current = job(r'$original')..['text'] = null;
        store.saveJob(current);
        now = now.add(const Duration(hours: 2));
        await engine.tick();
        expect(entries(), isEmpty);
      },
    );
  });
}

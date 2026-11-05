// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:typed_data';
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/engine.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

const account = '@fixture:example.invalid';
final source = SourceEventRef(
  conversation: const ConversationRef(
    accountId: account,
    roomId: '!fixture:example.invalid',
  ),
  eventId: r'$fixture',
);
final id = transcriptEntityId(source);

class _Transport implements FeatureTransport {
  bool? redacted = false;
  int loads = 0;
  @override
  String get accountId => account;
  @override
  String get deviceId => 'FIXTURE';
  @override
  bool get verified => true;
  @override
  Future<bool?> sourceRedacted(SourceEventRef source) async => redacted;
  @override
  Future<AudioSource> loadAudio(
    SourceEventRef source,
    Cancellation cancel,
  ) async {
    loads++;
    return AudioSource(Uint8List.fromList([1, 2, 3]), 'audio/ogg');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected transport');
}

class _Staged implements Transcriber, StagedTranscriber, TranscriberIdentity {
  String identity = 'pipeline-a';
  @override
  String get transcriptionCacheIdentity => identity;
  final primarySaved = Completer<void>();
  final finishTiming = Completer<void>();
  int uploads = 0;
  @override
  Future<TranscriptionResult> transcribe(
    AudioSource a,
    String? l,
    Cancellation c,
    void Function(double, double) e,
  ) => throw StateError('staged interface required');
  @override
  Future<TranscriptionResult> transcribeStaged(
    AudioSource a,
    String? l,
    Cancellation c,
    void Function(double, double) e,
    Future<void> Function(TranscriptionResult) onPrimaryResult,
  ) async {
    e(12, .02);
    uploads++;
    await onPrimaryResult(
      TranscriptionResult('Primary fixture text.', 12, .01),
    );
    if (!primarySaved.isCompleted) primarySaved.complete();
    await finishTiming.future;
    c.check();
    return TranscriptionResult('Primary fixture text.', 12, .015);
  }
}

PersonalOperation operation(
  String kind,
  String opId,
  int revision, [
  Map<String, dynamic> payload = const {},
]) => PersonalOperation(
  opId: opId,
  kind: kind,
  entityId: id,
  baseRevision: revision,
  createdAt: DateTime.utc(2026, 11, 5),
  payload: payload,
);

void main() {
  late WorkerStore store;
  late _Transport transport;
  late _Staged provider;
  late WorkerEngine engine;
  setUp(() {
    store = WorkerStore(sqlite3.openInMemory());
    transport = _Transport();
    provider = _Staged();
    engine = WorkerEngine(store, transport, provider);
    engine.accept(
      operation(
        'transcript.request',
        'request',
        0,
        Map<String, dynamic>.from(
          TranscriptionJob(
            id: id,
            source: source,
            state: JobState.queued,
          ).toJson(),
        ),
      ),
    );
  });
  tearDown(() async {
    if (!provider.finishTiming.isCompleted) provider.finishTiming.complete();
    await engine.waitForIdle();
    store.close();
  });

  Future<void> start() async {
    await engine.tick();
    await provider.primarySaved.future;
  }

  test(
    'primary checkpoint stays private and final result replaces it',
    () async {
      await start();
      final job = store.job(id)!;
      expect(job['state'], 'processing');
      expect(job['text'], isNull);
      expect(job['pendingResult']['text'], 'Primary fixture text.');
      expect(job['pendingResult']['estimatedCostUsd'], .02);
      expect(
        store.outbox.every(
          (e) =>
              !e['payload'].containsKey('pendingResult') &&
              e['payload']['text'] == null,
        ),
        isTrue,
      );
      provider.finishTiming.complete();
      await engine.waitForIdle();
      expect(store.job(id)!['state'], 'done');
      expect(store.job(id)!.containsKey('pendingResult'), isFalse);
      expect(store.job(id)!['estimatedCostUsd'], .015);
    },
  );

  test(
    'restart validates checkpoint source without another provider upload',
    () async {
      await start();
      final recoveredStore = WorkerStore(sqlite3.openInMemory());
      recoveredStore.saveJob(store.job(id)!);
      final recovered = WorkerEngine(recoveredStore, transport, provider);
      try {
        transport.redacted = null;
        recovered.recover();
        expect(recoveredStore.job(id)!['state'], 'waitingSync');
        expect(recoveredStore.job(id)!['text'], isNull);
        await recovered.auditTranscriptSources(force: true);
        expect(recoveredStore.job(id)!['state'], 'waitingSync');
        transport.redacted = false;
        await recovered.auditTranscriptSources(force: true);
        await recovered.tick();
        await recovered.waitForIdle();
        expect(recoveredStore.job(id)!['state'], 'done');
        expect(recoveredStore.job(id)!['text'], 'Primary fixture text.');
        expect(recoveredStore.job(id)!['estimatedCostUsd'], .02);
        expect(recoveredStore.job(id)!.containsKey('pendingResult'), isFalse);
        expect(provider.uploads, 1);
        expect(transport.loads, 1);
      } finally {
        recoveredStore.close();
      }
    },
  );

  test(
    'media dedupe reuses matching pipeline and excludes changed models',
    () async {
      provider.finishTiming.complete();
      await engine.tick();
      await engine.waitForIdle();
      expect(provider.uploads, 1);
      Future<void> request(String event) async {
        final nextSource = SourceEventRef(
          conversation: source.conversation,
          eventId: event,
        );
        final nextId = transcriptEntityId(nextSource);
        engine.accept(
          PersonalOperation(
            opId: event,
            kind: 'transcript.request',
            entityId: nextId,
            baseRevision: 0,
            createdAt: DateTime.utc(2026, 11, 5),
            payload: Map<String, dynamic>.from(
              TranscriptionJob(
                id: nextId,
                source: nextSource,
                state: JobState.queued,
              ).toJson(),
            ),
          ),
        );
        await engine.tick();
        await engine.waitForIdle();
        expect(store.job(nextId)!['state'], 'done');
      }

      await request(r'$same-pipeline');
      expect(provider.uploads, 1);
      provider.identity = 'pipeline-b';
      await request(r'$changed-model');
      expect(provider.uploads, 2);
    },
  );

  for (final redaction in [false, true]) {
    test(
      '${redaction ? 'redaction' : 'cancellation'} erases staged text',
      () async {
        await start();
        if (redaction) {
          transport.redacted = true;
          await engine.auditTranscriptSources(force: true);
        } else {
          engine.accept(
            operation(
              'transcript.cancel',
              'cancel',
              store.job(id)!['revision'] as int,
            ),
          );
        }
        provider.finishTiming.complete();
        await engine.waitForIdle();
        expect(store.job(id)!['state'], 'cancelled');
        expect(store.job(id)!.containsKey('pendingResult'), isFalse);
        expect(store.job(id)!['text'], isNull);
        expect(provider.uploads, 1);
      },
    );
  }
}

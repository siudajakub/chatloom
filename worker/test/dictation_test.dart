// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:typed_data';
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/engine.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

class _Source implements PrivateDictationSource {
  int loads = 0;
  bool? redacted = false;
  @override
  Future<bool?> dictationRedacted(String eventId) async => redacted;
  @override
  Future<AudioSource> loadDictation(
    String eventId,
    String id,
    Cancellation cancel,
  ) async {
    loads++;
    return AudioSource(Uint8List.fromList([1, 2, 3]), 'audio/ogg');
  }
}

class _Provider implements Transcriber {
  int calls = 0, uploads = 0;
  double duration = 12, cost = 0.01;
  String text = 'Editable fixture text.';
  WorkerFailure? error;
  Completer<void>? gate;
  @override
  Future<TranscriptionResult> transcribe(
    AudioSource audio,
    String? language,
    Cancellation cancel,
    void Function(double, double) estimate,
  ) async {
    calls++;
    estimate(duration, cost);
    uploads++;
    await gate?.future;
    cancel.check();
    if (error != null) throw error!;
    return TranscriptionResult(text, duration, cost);
  }
}

class _Transport implements FeatureTransport {
  int sends = 0;
  @override
  String get accountId => '@fixture:example.invalid';
  @override
  String get deviceId => 'FIXTURE';
  @override
  bool get verified => true;
  @override
  Future<String> send(SendTarget t, Map<String, dynamic> c, String tx) async {
    sends++;
    throw StateError('Dictation must never send to a conversation');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected transport');
}

void main() {
  const id = 'dictation-fixture';
  final now = DateTime.utc(2026, 11, 5, 12);
  late WorkerStore store;
  late _Source source;
  late _Provider provider;
  late _Transport transport;
  late WorkerEngine engine;
  PersonalOperation op(
    String kind, {
    String entity = id,
    int revision = 0,
    String? opId,
    Map<String, dynamic>? payload,
    DateTime? created,
  }) => PersonalOperation(
    opId: opId ?? '$kind-$entity-$revision',
    kind: kind,
    entityId: entity,
    baseRevision: revision,
    createdAt: created ?? now,
    payload:
        payload ??
        {
          'id': entity,
          'eventId': r'$private-audio',
          'durationMs': 12000,
          'sizeBytes': 3,
        },
  );
  setUp(() {
    store = WorkerStore(sqlite3.openInMemory());
    source = _Source();
    provider = _Provider();
    transport = _Transport();
    engine = WorkerEngine(
      store,
      transport,
      provider,
      clock: () => now,
      dictationSource: source,
      dictationTranscriber: provider,
    );
  });
  tearDown(() async {
    if (provider.gate?.isCompleted == false) provider.gate!.complete();
    await engine.waitForIdle();
    store.close();
  });
  Future<void> run() async {
    await engine.tick();
    await engine.waitForIdle();
  }

  test(
    'private request produces editable Scribe text without a chat send',
    () async {
      engine.accept(op('dictation.request'));
      await run();
      expect(store.job(id)?['state'], 'done');
      expect(store.job(id)?['text'], provider.text);
      expect(provider.uploads, 1);
      expect(transport.sends, 0);
      final result = store.outbox.last['payload'] as Map;
      expect(result['text'], provider.text);
      expect(result.containsKey('eventId'), isFalse);
    },
  );
  test('duplicate commands and repeated ids never pay again', () async {
    engine.accept(op('dictation.request'));
    engine.accept(op('dictation.request'));
    await run();
    engine.accept(op('dictation.request', revision: 1, opId: 'second'));
    await run();
    expect(provider.uploads, 1);
    expect(transport.sends, 0);
  });
  test('unknown or older workers cannot claim configured support', () async {
    engine = WorkerEngine(store, transport, provider, clock: () => now);
    expect(engine.dictationConfigured, isFalse);
    engine.accept(op('dictation.request'));
    await run();
    expect(store.job(id)?['errorCode'], 'dictation_not_configured');
    expect(provider.uploads, 0);
  });
  test('requests cannot name a contact room or override the provider', () {
    for (final field in ['roomId', 'model', 'language']) {
      expect(
        () => engine.accept(
          op(
            'dictation.request',
            opId: field,
            payload: {...op('dictation.request').payload, field: 'forbidden'},
          ),
        ),
        throwsA(isA<WorkerFailure>()),
      );
    }
    expect(provider.uploads, 0);
  });
  test('declared duration and byte caps refuse before download', () {
    for (final patch in [
      {'durationMs': 300001},
      {'sizeBytes': DictationLimits.maxBytes + 1},
      {'durationMs': 0},
      {'eventId': 'not-an-event'},
    ]) {
      expect(
        () => engine.accept(
          op(
            'dictation.request',
            opId: patch.toString(),
            payload: {...op('dictation.request').payload, ...patch},
          ),
        ),
        throwsA(isA<WorkerFailure>()),
      );
    }
    expect(source.loads, 0);
  });
  test('measured duration gate refuses provider upload', () async {
    provider.duration = 301;
    engine.accept(op('dictation.request'));
    await run();
    expect(provider.uploads, 0);
    expect(store.job(id)?['errorCode'], 'dictation_duration_limit');
  });
  test('empty recognition is a failed draft', () async {
    provider.text = '  ';
    engine.accept(op('dictation.request'));
    await run();
    expect(store.job(id)?['errorCode'], 'empty_transcript');
  });
  test(
    'oversized multibyte text never creates an oversized result event',
    () async {
      provider.text = '界' * 9000;
      engine.accept(op('dictation.request'));
      await run();
      expect(store.job(id)?['errorCode'], 'dictation_text_limit');
      expect(store.job(id)?.containsKey('text'), isFalse);
      expect(
        store.outbox.where(
          (value) => (value['payload'] as Map).containsKey('text'),
        ),
        isEmpty,
      );
    },
  );
  test('daily estimate is durably reserved and caps new drafts', () async {
    provider.cost = 0.3;
    engine.accept(op('dictation.request'));
    await run();
    engine.accept(op('dictation.request', entity: 'dictation-second'));
    await run();
    expect(provider.uploads, 1);
    expect(
      store.job('dictation-second')?['errorCode'],
      'dictation_daily_budget',
    );
  });
  test('cancelled paid work keeps its budget reservation', () async {
    provider.cost = 0.3;
    provider.gate = Completer<void>();
    engine.accept(op('dictation.request'));
    await engine.tick();
    while (provider.uploads == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    engine.accept(op('dictation.cancel', revision: 1));
    provider.gate!.complete();
    await engine.waitForIdle();
    provider.gate = null;
    engine.accept(op('dictation.request', entity: 'dictation-second'));
    await run();
    expect(provider.uploads, 1);
    expect(store.job(id)?['state'], 'cancelled');
    expect(
      store.job('dictation-second')?['errorCode'],
      'dictation_daily_budget',
    );
  });
  test('cancel queued draft never downloads or pays', () async {
    engine.accept(op('dictation.request'));
    engine.accept(op('dictation.cancel', revision: 1));
    await run();
    expect(source.loads, 0);
    expect(provider.uploads, 0);
    expect(store.job(id)?['state'], 'cancelled');
  });
  test('paid uncertainty is terminal and never retried', () async {
    provider.error = const PaidRequestUnknown();
    engine.accept(op('dictation.request'));
    await run();
    await run();
    engine.recover();
    await run();
    expect(store.job(id)?['state'], 'unknown');
    expect(provider.uploads, 1);
  });
  test('recover paid attempt refuses replay', () async {
    engine.accept(op('dictation.request'));
    final job = store.job(id)!
      ..['state'] = 'processing'
      ..['providerAttemptAt'] = now.toIso8601String();
    store.saveJob(job);
    engine.recover();
    await run();
    expect(store.job(id)?['errorCode'], 'paid_request_unknown');
    expect(provider.uploads, 0);
  });
  test('recover pre-provider processing safely queues once', () async {
    engine.accept(op('dictation.request'));
    store.saveJob(store.job(id)!..['state'] = 'processing');
    engine.recover();
    await run();
    expect(provider.uploads, 1);
  });
  test('expired requests cannot replay old audio', () async {
    engine.accept(
      op(
        'dictation.request',
        created: now.subtract(const Duration(minutes: 16)),
      ),
    );
    await run();
    expect(source.loads, 0);
    expect(store.job(id)?['errorCode'], 'dictation_source_timeout');
  });
  test('redacted or unavailable sources never reach provider', () async {
    for (final state in [true, null]) {
      source.redacted = state;
      final entity = state == true ? 'dictation-redacted' : 'dictation-unknown';
      engine.accept(op('dictation.request', entity: entity));
      await run();
      expect(
        store.job(entity)?['state'],
        state == true ? 'cancelled' : 'failed',
      );
    }
    expect(provider.uploads, 0);
  });
  test('redaction during provider work suppresses final text', () async {
    provider.gate = Completer<void>();
    engine.accept(op('dictation.request'));
    await engine.tick();
    while (provider.uploads == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    source.redacted = true;
    provider.gate!.complete();
    await engine.waitForIdle();
    expect(store.job(id)?['state'], 'cancelled');
    expect(store.job(id)?.containsKey('text'), isFalse);
  });
}

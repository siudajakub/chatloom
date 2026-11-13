// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/engine.dart';
import 'package:personal_worker/src/gist_provider.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

const conversation = ConversationRef(
  accountId: '@self:example.invalid',
  roomId: '!synthetic:example.invalid',
);
SourceEventRef sourceOf(String event) =>
    SourceEventRef(conversation: conversation, eventId: event);

const longText =
    'Hey, about Saturday: I booked the cabin near Zakopane for three nights, '
    'it costs 900 zloty in total, so 300 each. Can you bring the board games '
    'and tell Marek to pick up the keys before six?';

class Transport implements FeatureTransport {
  @override
  String get accountId => conversation.accountId;
  @override
  String get deviceId => 'FIXTURE';
  @override
  bool get verified => true;
  bool? redacted = false;

  /// Same bytes for every source: identical media.
  bool sameMedia = false;

  @override
  Future<bool?> sourceRedacted(SourceEventRef source) async => redacted;

  @override
  Future<AudioSource> loadAudio(
    SourceEventRef source,
    Cancellation cancel,
  ) async => AudioSource(
    Uint8List.fromList([1, 2, 3, if (!sameMedia) ...source.eventId.codeUnits]),
    'audio/ogg',
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FixedTranscriber implements Transcriber {
  String text = longText;
  int calls = 0;
  @override
  Future<TranscriptionResult> transcribe(
    AudioSource audio,
    String? language,
    Cancellation cancel,
    void Function(double, double) estimate,
  ) async {
    calls++;
    estimate(40, 0.003);
    return TranscriptionResult(text, 40, 0.003);
  }
}

class FakeGister implements TranscriptGister {
  int calls = 0;
  WorkerFailure? failure;
  Completer<void>? hold;
  final List<String> inputs = [];
  @override
  bool get configured => true;
  @override
  double ceilingUsd(String text) => 0.001;
  @override
  Future<TranscriptGistResult> gist(
    String text,
    Cancellation cancel,
    void Function() onAttempt,
  ) async {
    calls++;
    inputs.add(text);
    onAttempt();
    await hold?.future;
    cancel.check();
    if (failure case final failure?) throw failure;
    return const TranscriptGistResult(
      'Cabin near Zakopane booked for Saturday, 900 zł; bring board games, '
      'Marek picks up keys before six.',
      0.0002,
    );
  }
}

PersonalOperation request(String id, String event) => PersonalOperation(
  opId: 'request-$id',
  kind: 'transcript.request',
  entityId: id,
  baseRevision: 0,
  createdAt: DateTime.utc(2026, 11, 13),
  payload: TranscriptionJob(
    id: id,
    source: sourceOf(event),
    state: JobState.queued,
  ).toJson(),
);

void main() {
  late WorkerStore store;
  late Transport transport;
  late FixedTranscriber transcriber;
  late FakeGister gister;
  late WorkerEngine engine;
  final now = DateTime.utc(2026, 11, 13, 12);

  setUp(() {
    store = WorkerStore(sqlite3.openInMemory());
    transport = Transport();
    transcriber = FixedTranscriber();
    gister = FakeGister();
    engine = WorkerEngine(
      store,
      transport,
      transcriber,
      clock: () => now,
      gister: gister,
    );
  });

  Future<void> run([WorkerEngine? on]) async {
    final target = on ?? engine;
    await target.tick();
    await target.waitForIdle();
  }

  Map<String, dynamic> lastResult(String id) => Map<String, dynamic>.from(
    store.outbox.lastWhere((o) => o['entityId'] == id)['payload'] as Map,
  );

  test('a finished transcript carries its gist and the gist cost', () async {
    engine.accept(request('t', r'$long'));
    await run();
    final job = store.job('t')!;
    expect(job['state'], 'done');
    expect(job['gist'], startsWith('Cabin near Zakopane'));
    expect(job['estimatedCostUsd'], closeTo(0.0032, 1e-9));
    expect(job.containsKey('pendingResult'), isFalse);
    expect(gister.inputs.single, longText);
    final published = TranscriptionJob.fromJson(lastResult('t'));
    expect(published.state, JobState.done);
    expect(published.gist, job['gist']);
  });

  test('a short transcript is its own gist without a request', () async {
    transcriber.text = '  Okay,   see you\nat eight! ';
    engine.accept(request('t', r'$short'));
    await run();
    expect(store.job('t')!['gist'], 'Okay, see you at eight!');
    expect(store.job('t')!['estimatedCostUsd'], 0.003);
    expect(gister.calls, 0);
  });

  test('a refused gist leaves the transcript as it is', () async {
    gister.failure = const WorkerFailure('gist_rejected');
    engine.accept(request('t', r'$long'));
    await run();
    final job = store.job('t')!;
    expect(job['state'], 'done');
    expect(job['text'], longText);
    expect(job.containsKey('gist'), isFalse);
    expect(job['estimatedCostUsd'], 0.003);
    expect(lastResult('t').containsKey('gist'), isFalse);
  });

  test('an unknown paid gist counts its ceiling, never retries', () async {
    gister.failure = const PaidRequestUnknown();
    engine.accept(request('t', r'$long'));
    await run();
    final job = store.job('t')!;
    expect(job['state'], 'done');
    expect(job['estimatedCostUsd'], closeTo(0.004, 1e-9));
    await run();
    expect(gister.calls, 1);
  });

  test('a crash during the gist still publishes the paid transcript', () async {
    gister.hold = Completer<void>();
    engine.accept(request('t', r'$long'));
    await engine.tick();
    for (var i = 0; i < 20 && gister.calls == 0; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(gister.calls, 1);
    // The process dies here; a new engine recovers from the store.
    final restarted = WorkerEngine(
      store,
      transport,
      transcriber,
      clock: () => now,
      gister: gister,
    );
    restarted.recover();
    expect(store.job('t')!['state'], 'waitingSync');
    expect(
      (store.job('t')!['pendingResult'] as Map)['estimatedCostUsd'],
      closeTo(0.004, 1e-9),
    );
    await restarted.auditTranscriptSources(force: true);
    final job = store.job('t')!;
    expect(job['state'], 'done');
    expect(job['text'], longText);
    expect(job.containsKey('gist'), isFalse);
    expect(transcriber.calls, 1);
  });

  test('identical media reuses the earlier gist for free', () async {
    transport.sameMedia = true;
    engine.accept(request('a', r'$first'));
    await run();
    engine.accept(request('b', r'$forward'));
    await run();
    expect(transcriber.calls, 1);
    expect(gister.calls, 1);
    expect(store.job('b')!['gist'], store.job('a')!['gist']);
  });

  test('deleting the source erases the gist with the text', () async {
    engine.accept(request('t', r'$long'));
    await run();
    transport.redacted = true;
    await engine.auditTranscriptSources(force: true);
    expect(store.job('t')!['text'], isNull);
    expect(store.job('t')!.containsKey('gist'), isFalse);
    expect(lastResult('t').containsKey('gist'), isFalse);
  });

  test('an automatic job skips the gist past its daily budget', () async {
    final id = transcriptEntityId(sourceOf(r'$auto'));
    // Earlier automatic work used all but a fraction of the budget.
    store.saveJob({
      ...TranscriptionJob(
        id: 'spent',
        source: sourceOf(r'$spent'),
        state: JobState.done,
        text: 'x',
        estimatedCostUsd: 0.9965,
        origin: TranscriptionOrigin.auto,
      ).toJson(),
      'kind': 'transcript',
      'revision': 2,
      'createdAt': now.toIso8601String(),
    });
    store.saveJob({
      ...TranscriptionJob(
        id: id,
        source: sourceOf(r'$auto'),
        state: JobState.queued,
        origin: TranscriptionOrigin.auto,
      ).toJson(),
      'kind': 'transcript',
      'revision': 1,
      'acceptedOpId': 'auto-op',
      'createdAt': now.toIso8601String(),
      'mediaKind': 'voice',
    });
    engine = WorkerEngine(
      store,
      transport,
      transcriber,
      clock: () => now,
      gister: gister,
      autoTranscription: true,
    );
    await run();
    expect(store.job(id)!['state'], 'done');
    expect(store.job(id)!.containsKey('gist'), isFalse);
    expect(gister.calls, 0);
  });

  group('OpenRouterTranscriptGister', () {
    Map<String, dynamic>? sent;
    http.Client client(Map<String, Object?> answer, {int status = 200}) =>
        MockClient((request) async {
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response.bytes(utf8.encode(jsonEncode(answer)), status);
        });
    Map<String, Object?> answer(String content, {String finish = 'stop'}) => {
      'model': 'google/gemini-3.1-flash-lite',
      'choices': [
        {
          'finish_reason': finish,
          'message': {'content': content},
        },
      ],
      'usage': {'cost': 0.00004},
    };

    test('one private request; quotes and line breaks removed', () async {
      var attempts = 0;
      final result = await OpenRouterTranscriptGister(
        'key',
        clientFactory: () => client(answer('"Cabin booked,\n900 zł."')),
      ).gist(longText, Cancellation(), () => attempts++);
      expect(result.text, 'Cabin booked, 900 zł.');
      expect(result.costUsd, 0.00004);
      expect(attempts, 1);
      expect(sent!['model'], transcriptGistModel);
      expect(sent!['max_tokens'], transcriptGistMaxTokens);
      expect(sent!['provider']['zdr'], true);
      expect(sent!['provider']['data_collection'], 'deny');
      final messages = sent!['messages'] as List;
      expect(messages.first['content'], contains('exactly one short sentence'));
      expect(messages.first['content'], contains('untrusted data'));
      expect(
        jsonDecode(messages.last['content'] as String)['transcript'],
        transcriptGistOneLine(longText),
      );
    });

    test('a long note may take two sentences', () async {
      await OpenRouterTranscriptGister(
        'key',
        clientFactory: () => client(answer('Two. Sentences.')),
      ).gist(List.filled(80, 'word').join(' '), Cancellation(), () {});
      expect(
        (sent!['messages'] as List).first['content'],
        contains('at most two short sentences'),
      );
    });

    test('cut, empty, oversized or foreign answers are refused', () async {
      Future<Object?> outcome(Map<String, Object?> body, {int status = 200}) =>
          OpenRouterTranscriptGister(
                'key',
                clientFactory: () => client(body, status: status),
              )
              .gist(longText, Cancellation(), () {})
              .then<Object?>((r) => r.text, onError: (Object e) => e);
      expect(
        await outcome(answer('Half', finish: 'length')),
        isA<WorkerFailure>().having(
          (e) => e.code,
          'code',
          'gist_output_incomplete',
        ),
      );
      expect(
        await outcome(answer('   ')),
        isA<WorkerFailure>().having(
          (e) => e.code,
          'code',
          'gist_invalid_response',
        ),
      );
      expect(
        await outcome(answer('x' * (transcriptGistMaxChars + 1))),
        isA<WorkerFailure>().having(
          (e) => e.code,
          'code',
          'gist_invalid_response',
        ),
      );
      expect(
        await outcome({...answer('ok'), 'model': 'other/model'}),
        isA<WorkerFailure>().having(
          (e) => e.code,
          'code',
          'gist_model_mismatch',
        ),
      );
      expect(
        await outcome(answer('ok'), status: 503),
        isA<PaidRequestUnknown>(),
      );
      expect(
        await outcome(answer('ok'), status: 400),
        isA<WorkerFailure>().having((e) => e.code, 'code', 'gist_rejected'),
      );
    });

    test('without a key nothing is sent', () async {
      final gister = OpenRouterTranscriptGister('');
      expect(gister.configured, isFalse);
      await expectLater(
        gister.gist(longText, Cancellation(), () {}),
        throwsA(isA<WorkerFailure>()),
      );
    });
  });
}

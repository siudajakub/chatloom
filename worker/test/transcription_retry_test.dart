// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Bursts of incoming voice notes (2026-10-26, J: some showed an error, and
// Retry then worked). Transient failures are retried by the worker itself;
// only an exhausted or permanent failure is published as an error, and a
// retry never charges the daily budget twice. The local adapter is a
// raw-socket stand-in with the single-slot, fail-fast behaviour of
// deploy/local_sources.py. Fake provider only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/engine.dart';
import 'package:personal_worker/src/local_sources.dart';
import 'package:personal_worker/src/matrix_transport.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

const account = '@self:example.invalid';
const cloudRoom = '!cloud:beeper.com';
const localRoom = '!afina:beeper.local';
const cost = 20 / 60 * 0.0045;

Never _fail(Object failure) =>
    throw failure is String ? WorkerFailure(failure) : failure;

class _Transport
    implements FeatureTransport, MediaPreflight, BoundedAudioLoader {
  @override
  String get accountId => account;
  @override
  String get deviceId => 'TEST_DEVICE';
  @override
  bool get verified => true;
  final loads = <String>[];

  /// What successive loads of an event throw: a [WorkerFailure] code or a
  /// raw exception, as an unclassified transport error would.
  final failures = <String, List<Object>>{};
  final holds = <String, Completer<void>>{};
  @override
  Future<bool?> sourceRedacted(SourceEventRef source) async => false;
  @override
  Future<MediaFacts?> mediaFacts(SourceEventRef source) async =>
      const MediaFacts(sizeBytes: 64);
  @override
  Future<AudioSource> loadAudioBounded(
    SourceEventRef source,
    Cancellation cancel, {
    required int maxBytes,
    required bool requireDeclaredSize,
  }) => loadAudio(source, cancel);
  @override
  Future<AudioSource> loadAudio(
    SourceEventRef source,
    Cancellation cancel,
  ) async {
    loads.add(source.eventId);
    await holds[source.eventId]?.future;
    final queue = failures[source.eventId];
    if (queue != null && queue.isNotEmpty) _fail(queue.removeAt(0));
    return AudioSource(
      Uint8List.fromList(utf8.encode(source.eventId)),
      'audio/ogg',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected conversation operation');
}

class _Transcriber implements Transcriber {
  /// Events measured (the pre-upload gate ran) and uploaded successfully.
  final measured = <String>[];
  final uploads = <String>[];

  /// What successive uploads of an event throw after it was measured.
  final failures = <String, List<Object>>{};
  @override
  Future<TranscriptionResult> transcribe(
    AudioSource audio,
    String? language,
    Cancellation cancel,
    void Function(double, double) estimate,
  ) async {
    final event = utf8.decode(audio.takeBytes());
    estimate(20, cost);
    measured.add(event);
    final queue = failures[event];
    if (queue != null && queue.isNotEmpty) _fail(queue.removeAt(0));
    uploads.add(event);
    return TranscriptionResult('text $event', 20, cost);
  }
}

class _Feed implements LiveSourceFeed {
  final items = <RecentSourceItem>[];
  @override
  set active(bool value) {}
  @override
  Future<List<RecentSourceItem>> drain() async {
    final out = List.of(items);
    items.clear();
    return out;
  }

  @override
  Future<void> get wakeup => Completer<void>().future;
}

String entity(String event, {String room = cloudRoom}) => transcriptEntityId(
  SourceEventRef(
    conversation: ConversationRef(accountId: account, roomId: room),
    eventId: event,
  ),
);

/// Every state the worker published for [id], in order.
List<String> publishedStates(WorkerStore store, String id) => [
  for (final op in store.outbox)
    if (op['kind'] == 'transcript.result' && op['entityId'] == id)
      (op['payload'] as Map)['state'] as String,
];

void main() {
  group('engine', () {
    late WorkerStore store;
    late _Transport transport;
    late _Transcriber transcriber;
    late _Feed feed;
    late WorkerEngine engine;
    late DateTime now;

    WorkerEngine build() => WorkerEngine(
      store,
      transport,
      transcriber,
      clock: () => now,
      liveSources: feed,
      autoTranscription: true,
    );

    Future<void> runJobs() async {
      for (var i = 0; i < 6; i++) {
        await engine.tick();
        await engine.waitForIdle();
      }
    }

    Map<String, dynamic> job(String event) => store.job(entity(event))!;

    /// A burst arriving through the worker's own sync, one second apart.
    Future<void> burst(List<String> events) async {
      await engine.autoScan(); // Opens the live window.
      for (final event in events) {
        now = now.add(const Duration(seconds: 1));
        feed.items.add(
          RecentSourceItem(
            roomId: cloudRoom,
            eventId: event,
            kind: AutoTranscriptionKind.voice,
            network: 'telegram',
            durationMs: 20000,
            timestamp: now,
          ),
        );
      }
      await engine.autoScan();
    }

    setUp(() {
      now = DateTime.utc(2026, 10, 26, 9);
      store = WorkerStore(sqlite3.openInMemory());
      transport = _Transport();
      transcriber = _Transcriber();
      feed = _Feed();
      engine = build();
    });
    tearDown(() async {
      engine.cancelAll();
      for (final hold in transport.holds.values) {
        if (!hold.isCompleted) hold.complete();
      }
      await engine.waitForIdle();
      store.close();
    });

    test('a burst with transient failures finishes without any error, '
        'each message charged once', () async {
      final events = [r'$v1', r'$v2', r'$v3', r'$v4', r'$v5'];
      transport.failures[r'$v1'] = ['source_unavailable'];
      // Unclassified: a dropped connection from a transport.
      transport.failures[r'$v2'] = [
        const HttpException('Connection closed before full header'),
      ];
      transport.failures[r'$v4'] = [
        'local_source_unavailable',
        'local_source_busy',
      ];
      // Measured (estimate stored), then refused by the provider.
      transcriber.failures[r'$v3'] = ['openai_rate_limited'];
      await burst(events);
      await runJobs();
      expect(job(r'$v5')['state'], 'done');
      for (final event in [r'$v1', r'$v2', r'$v3', r'$v4']) {
        expect(job(event)['state'], 'queued', reason: '$event backs off');
        expect(job(event).containsKey('providerAttemptAt'), isFalse);
      }
      for (var i = 0; i < 6; i++) {
        now = now.add(const Duration(minutes: 1));
        await runJobs();
      }
      for (final event in events) {
        expect(job(event)['state'], 'done', reason: event);
        expect(job(event)['text'], 'text $event');
        expect(job(event).containsKey('retries'), isFalse);
        // Devices only ever saw it pending, then done: never an error.
        expect(
          publishedStates(store, entity(event)),
          everyElement(isIn(['queued', 'processing', 'done'])),
          reason: event,
        );
      }
      expect(transcriber.uploads, unorderedEquals(events));
      expect(transcriber.measured.where((e) => e == r'$v3'), hasLength(2));
      // The rate-limited message was measured twice but counts once.
      expect(engine.autoSpent(), closeTo(events.length * cost, 1e-12));
    });

    test('an unclassified error before the provider is retried a bounded '
        'number of times, then shown as an error', () async {
      transport.failures[r'$broken'] = List.filled(
        10,
        const SocketException('Connection reset by peer'),
      );
      await burst([r'$broken']);
      for (var i = 0; i < 6; i++) {
        await runJobs();
        now = now.add(const Duration(minutes: 30));
      }
      expect(job(r'$broken')['state'], 'failed');
      expect(job(r'$broken')['errorCode'], 'transcription_failed');
      expect(transport.loads, hasLength(WorkerEngine.unexpectedRetryLimit + 1));
      expect(transcriber.measured, isEmpty, reason: 'nothing was paid');
      // Pending while retrying, one error at the end: no error, then
      // pending, then an error again.
      final states = publishedStates(store, entity(r'$broken'));
      expect(states.last, 'failed');
      expect(states.where((s) => s == 'failed'), hasLength(1));
    });

    test(
      'an unclassified error after the provider gate is never retried',
      () async {
        transcriber.failures[r'$paid'] = [StateError('lost after measuring')];
        await burst([r'$paid']);
        for (var i = 0; i < 3; i++) {
          await runJobs();
          now = now.add(const Duration(minutes: 30));
        }
        expect(job(r'$paid')['state'], 'failed');
        expect(job(r'$paid')['errorCode'], 'transcription_failed');
        expect(transcriber.measured, [r'$paid']);
      },
    );

    test('a restart during the retry of a rate-limited job does not turn it '
        'into a paid unknown', () async {
      transcriber.failures[r'$rl'] = ['openai_rate_limited'];
      await burst([r'$rl']);
      await runJobs();
      expect(job(r'$rl')['state'], 'queued');
      expect(job(r'$rl')['estimatedCostUsd'], closeTo(cost, 1e-12));
      // The retry is still downloading when the worker stops.
      transport.holds[r'$rl'] = Completer<void>();
      now = now.add(const Duration(seconds: 16));
      await engine.tick();
      for (var i = 0; i < 20 && transport.loads.length < 2; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(job(r'$rl')['state'], 'processing');
      build().recover();
      expect(job(r'$rl')['state'], 'queued');
      expect(job(r'$rl')['errorCode'], isNull);
    });
  });

  group('Matrix media download', () {
    test('a dropped connection is a transient source failure', () async {
      final client = MockClient(
        (_) async => throw http.ClientException('Connection reset by peer'),
      );
      await expectLater(
        boundedMediaDownload(
          client,
          Uri.parse('https://media.example.invalid/download'),
          accessToken: 'token',
          maxBytes: 4096,
          cancel: Cancellation(),
        ),
        throwsA(
          isA<WorkerFailure>().having(
            (e) => e.code,
            'code',
            'source_unavailable',
          ),
        ),
      );
    });
  });

  group('single-slot local adapter', () {
    const source = SourceEventRef(
      conversation: ConversationRef(
        accountId: account,
        roomId: localRoom,
        network: 'whatsapp',
      ),
      eventId: r'$voice',
    );

    test('a request sent before the adapter freed its slot is resent, '
        'not failed', () async {
      final adapter = await _SingleSlotAdapter.start();
      final transport = LocalSourceTransport(_NoMatrix(), adapter.socket);
      // metadata, export and metadata again, back to back.
      final audio = await transport.loadAudio(source, Cancellation());
      expect(utf8.decode(audio.bytes), r'$voice');
      expect(adapter.answered, 3);
      expect(adapter.refused, greaterThan(0), reason: 'the race was hit');
    });

    test('an adapter that keeps hanging up is a transient failure, not a '
        'raw exception', () async {
      final adapter = await _SingleSlotAdapter.start()
        ..refuseAll = true;
      final transport = LocalSourceTransport(
        _NoMatrix(),
        adapter.socket,
        refusalRetryDelays: const [Duration.zero, Duration.zero],
      );
      await expectLater(
        transport.loadAudio(source, Cancellation()),
        throwsA(
          isA<WorkerFailure>().having(
            (e) => e.code,
            'code',
            'local_source_unavailable',
          ),
        ),
      );
      expect(adapter.refused, 3, reason: 'one request, two resends');
      expect(await transport.sourceRedacted(source), isNull);
    });

    test('a dropped export does not fail the job', () async {
      // No timing involved: exactly the export's connection is dropped
      // (1 media facts, 2 status probe, 3 metadata, 4 export).
      final adapter =
          await _SingleSlotAdapter.start(releaseAfterAnswer: Duration.zero)
            ..refuseConnections.add(4);
      final store = WorkerStore(sqlite3.openInMemory());
      addTearDown(store.close);
      final transcriber = _Transcriber();
      final engine = WorkerEngine(
        store,
        LocalSourceTransport(_NoMatrix(), adapter.socket),
        transcriber,
        autoTranscription: true,
      );
      final id = transcriptEntityId(source);
      engine.accept(
        PersonalOperation(
          opId: 'auto-voice',
          kind: 'transcript.request',
          entityId: id,
          baseRevision: 0,
          createdAt: DateTime.now(),
          payload: Map<String, dynamic>.from(
            TranscriptionJob(
              id: id,
              source: source,
              state: JobState.queued,
              origin: TranscriptionOrigin.auto,
            ).toJson(),
          ),
        ),
      );
      await engine.tick();
      await engine.waitForIdle();
      expect(adapter.refused, 1);
      expect(store.job(id)!['state'], 'done');
      expect(transcriber.uploads, [r'$voice']);
    });

    test('a burst of automatic jobs through the adapter all finish at '
        'once', () async {
      final adapter = await _SingleSlotAdapter.start();
      final transport = LocalSourceTransport(_NoMatrix(), adapter.socket);
      final store = WorkerStore(sqlite3.openInMemory());
      addTearDown(store.close);
      final transcriber = _Transcriber();
      final engine = WorkerEngine(
        store,
        transport,
        transcriber,
        autoTranscription: true,
      );
      final events = [for (var i = 1; i <= 5; i++) '\$burst$i'];
      for (final event in events) {
        final ref = SourceEventRef(
          conversation: source.conversation,
          eventId: event,
        );
        final id = transcriptEntityId(ref);
        engine.accept(
          PersonalOperation(
            opId: 'auto-$event',
            kind: 'transcript.request',
            entityId: id,
            baseRevision: 0,
            createdAt: DateTime.now(),
            payload: Map<String, dynamic>.from(
              TranscriptionJob(
                id: id,
                source: ref,
                state: JobState.queued,
                origin: TranscriptionOrigin.auto,
              ).toJson(),
            ),
          ),
        );
      }
      // Real clock: an engine-level backoff (15 s) would leave jobs queued.
      // The daemon's order: source audits, then the transcript slots.
      for (var i = 0; i < 8; i++) {
        await engine.auditTranscriptSources(force: true);
        await engine.tick();
        await engine.waitForIdle();
      }
      for (final event in events) {
        final id = entity(event, room: localRoom);
        expect(store.job(id)!['state'], 'done', reason: event);
        expect(
          publishedStates(store, id),
          everyElement(isIn(['queued', 'processing', 'done'])),
        );
      }
      expect(transcriber.uploads, unorderedEquals(events));
      expect(adapter.refused, greaterThan(0), reason: 'the race was hit');
    });
  });
}

class _NoMatrix implements FeatureTransport {
  @override
  String get accountId => account;
  @override
  String get deviceId => 'fixture';
  @override
  bool get verified => true;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected Matrix operation');
}

/// Stand-in for deploy/local_sources.py: one request at a time; a
/// connection that arrives while the slot is held is closed without an
/// answer. Like the Python server, the slot is released only a moment after
/// the answer was written (handler finish, socket shutdown, then release).
class _SingleSlotAdapter {
  final Directory _directory;
  bool _busy = false;
  bool refuseAll = false;

  /// Connections (1-based, in arrival order) dropped whatever the slot.
  final refuseConnections = <int>{};
  int connections = 0;
  int answered = 0;
  int refused = 0;

  /// How long the slot stays held after the answer's last byte.
  final Duration releaseAfterAnswer;

  _SingleSlotAdapter._(this._directory, this.releaseAfterAnswer);

  String get socket => '${_directory.path}/source.sock';

  static Future<_SingleSlotAdapter> start({
    Duration releaseAfterAnswer = const Duration(milliseconds: 30),
  }) async {
    // A short path: Unix socket paths are limited to about 100 bytes.
    final directory = await Directory('/tmp').createTemp('personal-slot-');
    final server = await ServerSocket.bind(
      InternetAddress(
        '${directory.path}/source.sock',
        type: InternetAddressType.unix,
      ),
      0,
    );
    final adapter = _SingleSlotAdapter._(directory, releaseAfterAnswer);
    server.listen(adapter._serve);
    addTearDown(() async {
      await server.close();
      await directory.delete(recursive: true);
    });
    return adapter;
  }

  Future<void> _serve(Socket socket) async {
    connections++;
    if (_busy || refuseAll || refuseConnections.contains(connections)) {
      refused++;
      socket.destroy();
      return;
    }
    _busy = true;
    try {
      final request = await _read(socket);
      final body = _answer(request.$1, request.$2);
      socket
        ..add(
          latin1.encode(
            'HTTP/1.1 200 OK\r\n'
            'Content-Type: application/octet-stream\r\n'
            'Content-Length: ${body.length}\r\n'
            'Connection: close\r\n\r\n',
          ),
        )
        ..add(body);
      await socket.flush();
      answered++;
      await Future<void>.delayed(releaseAfterAnswer);
      await socket.close();
    } catch (_) {
      socket.destroy();
    } finally {
      _busy = false;
    }
  }

  List<int> _answer(String path, Map request) {
    if (path != '/source') throw StateError('unexpected $path');
    final source = SourceEventRef.fromJson(
      Map<String, dynamic>.from(request['source'] as Map),
    );
    final media = utf8.encode(source.eventId);
    if (request['mode'] == 'audio') return media;
    return utf8.encode(
      jsonEncode({
        'sourceKey': source.key,
        'redacted': false,
        'transcriptionAllowed': true,
        'mimeType': 'audio/ogg',
        'kind': 'voice',
        'durationMs': 20000,
        'fileSize': media.length,
      }),
    );
  }

  /// Reads one request (headers and a Content-Length body).
  static Future<(String, Map)> _read(Socket socket) {
    final done = Completer<(String, Map)>();
    final buffer = BytesBuilder();
    socket.listen(
      (chunk) {
        if (done.isCompleted) return;
        buffer.add(chunk);
        final bytes = buffer.toBytes();
        final text = latin1.decode(bytes);
        final end = text.indexOf('\r\n\r\n');
        if (end < 0) return;
        final head = text.substring(0, end);
        final length = int.parse(
          RegExp(
            r'content-length:\s*(\d+)',
            caseSensitive: false,
          ).firstMatch(head)!.group(1)!,
        );
        if (bytes.length < end + 4 + length) return;
        done.complete((
          head.split(' ')[1],
          jsonDecode(utf8.decode(bytes.sublist(end + 4, end + 4 + length)))
              as Map,
        ));
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      onDone: () {
        if (!done.isCompleted) done.completeError(StateError('closed'));
      },
    );
    return done.future;
  }
}

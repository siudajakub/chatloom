import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/local_sources.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:test/test.dart';

class NoMatrix implements FeatureTransport {
  @override
  String get accountId => '@fixture:example.invalid';
  @override
  String get deviceId => 'fixture';
  @override
  bool get verified => true;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected Matrix operation');
}

/// Bounded fake adapter: records paths and the highest number of requests
/// that were in flight at once.
class FixtureSource {
  final HttpServer server;
  final Directory directory;
  final requests = <Map>[];
  var active = 0;
  var maxActive = 0;
  Future<void> Function(Map request)? delay;
  Map<String, Object?> Function(Map request) metadata;
  Object? Function(Map request) recent = (_) => {'cursor': 0, 'items': []};
  List<int> media = [1, 2, 3];
  int? declaredLength;

  FixtureSource._(this.server, this.directory, this.metadata);

  String get socket => '${directory.path}/source.sock';

  static Future<FixtureSource> start(
    Map<String, Object?> Function(Map request) metadata,
  ) async {
    final directory = await Directory('/tmp').createTemp('personal-source-');
    final server = await HttpServer.bind(
      InternetAddress(
        '${directory.path}/source.sock',
        type: InternetAddressType.unix,
      ),
      0,
    );
    final fixture = FixtureSource._(server, directory, metadata);
    server.listen((r) async {
      fixture.active++;
      if (fixture.active > fixture.maxActive) {
        fixture.maxActive = fixture.active;
      }
      var counted = true;
      void done() {
        if (counted) fixture.active--;
        counted = false;
      }

      try {
        expect(
          r.contentLength,
          greaterThan(0),
          reason: 'The bounded source server requires Content-Length.',
        );
        final request = jsonDecode(await utf8.decoder.bind(r).join()) as Map;
        request['_path'] = r.uri.path;
        fixture.requests.add(request);
        await fixture.delay?.call(request);
        List<int> bytes;
        if (r.uri.path == '/recent') {
          bytes = utf8.encode(jsonEncode(fixture.recent(request)));
        } else if (request['mode'] == 'metadata') {
          bytes = utf8.encode(jsonEncode(fixture.metadata(request)));
        } else {
          bytes = fixture.media;
        }
        r.response.contentLength =
            r.uri.path == '/source' && request['mode'] == 'audio'
            ? fixture.declaredLength ?? bytes.length
            : bytes.length;
        // The client may start its next request as soon as it has the body.
        done();
        r.response.add(bytes);
        try {
          await r.response.close();
        } on HttpException {
          // Oversized declarations: the client refuses and hangs up early.
          if (fixture.declaredLength == null) rethrow;
        }
      } finally {
        done();
      }
    });
    addTearDown(() async {
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    return fixture;
  }

  int count(String mode) => requests.where((r) => r['mode'] == mode).length;
}

void main() {
  const source = SourceEventRef(
    conversation: ConversationRef(
      accountId: '@fixture:example.invalid',
      roomId: '!source:beeper.local',
      network: 'telegram',
    ),
    eventId: r'$source',
  );
  for (final scenario in [
    'ordinary',
    'protected',
    'wrongBinding',
    'deletedAfterDownload',
  ]) {
    test(
      'local source $scenario is bound and rechecked before provider handoff',
      () async {
        var metadataRequests = 0;
        final fixture = await FixtureSource.start((_) {
          metadataRequests++;
          return {
            'sourceKey': scenario == 'wrongBinding' ? 'wrong' : source.key,
            'redacted':
                scenario == 'deletedAfterDownload' && metadataRequests > 1,
            'transcriptionAllowed': scenario != 'protected',
            'mimeType': 'audio/ogg',
          };
        });
        final transport = LocalSourceTransport(NoMatrix(), fixture.socket);
        if (scenario == 'ordinary') {
          final result = await transport.loadAudio(source, Cancellation());
          expect(result.bytes, [1, 2, 3]);
          expect(metadataRequests, 2);
          expect(fixture.count('audio'), 1);
        } else {
          await expectLater(
            transport.loadAudio(source, Cancellation()),
            throwsA(isA<WorkerFailure>()),
          );
          expect(
            fixture.count('audio'),
            scenario == 'deletedAfterDownload' ? 1 : 0,
          );
        }
      },
    );
  }

  Map<String, Object?> roundMetadata(Map _) => {
    'sourceKey': source.key,
    'redacted': false,
    'transcriptionAllowed': true,
    'mimeType': 'video/mp4',
    'kind': 'round',
  };

  test('round video exports MP4 bytes for audio extraction', () async {
    final fixture = await FixtureSource.start(roundMetadata);
    fixture.media = List<int>.generate(4096, (i) => i % 251);
    final transport = LocalSourceTransport(NoMatrix(), fixture.socket);
    final result = await transport.loadAudio(source, Cancellation());
    expect(result.mimeType, 'video/mp4');
    expect(result.bytes, fixture.media);
    expect(fixture.requests.map((r) => r['mode']), [
      'metadata',
      'audio',
      'metadata',
    ]);
    expect(
      fixture.requests[1]['source']['conversation']['network'],
      'telegram',
    );
  });

  test('round exports above 64 MiB are refused before buffering', () async {
    final fixture = await FixtureSource.start(roundMetadata);
    fixture.declaredLength = localRoundMaxBytes + 1;
    final transport = LocalSourceTransport(NoMatrix(), fixture.socket);
    await expectLater(
      transport.loadAudio(source, Cancellation()),
      throwsA(
        isA<WorkerFailure>().having((e) => e.code, 'code', 'source_too_large'),
      ),
    );
  });

  for (final (name, mime, kind, code) in [
    ('non-MP4 video', 'video/webm', 'round', 'invalid_round_format'),
    ('video as voice', 'video/mp4', 'voice', 'invalid_round_format'),
    ('audio as round', 'audio/ogg', 'round', 'protected_media'),
    ('other media', 'image/png', 'voice', 'protected_media'),
  ]) {
    test('$name is refused without exporting bytes', () async {
      final fixture = await FixtureSource.start(
        (_) => {
          'sourceKey': source.key,
          'redacted': false,
          'transcriptionAllowed': true,
          'mimeType': mime,
          'kind': kind,
        },
      );
      final transport = LocalSourceTransport(NoMatrix(), fixture.socket);
      await expectLater(
        transport.loadAudio(source, Cancellation()),
        throwsA(isA<WorkerFailure>().having((e) => e.code, 'code', code)),
      );
      expect(fixture.count('audio'), 0);
    });
  }

  test('kind changing between checks fails closed', () async {
    var calls = 0;
    final fixture = await FixtureSource.start((request) {
      calls++;
      return {...roundMetadata(request), if (calls > 1) 'kind': 'voice'};
    });
    final transport = LocalSourceTransport(NoMatrix(), fixture.socket);
    await expectLater(
      transport.loadAudio(source, Cancellation()),
      throwsA(isA<WorkerFailure>()),
    );
  });

  test(
    'recent scan sends account, cursor and since; parses identifiers',
    () async {
      final fixture = await FixtureSource.start(roundMetadata);
      fixture.recent = (request) => {
        'cursor': 12,
        'items': [
          {
            'roomId': '!a:beeper.local',
            'eventId': r'$a',
            'kind': 'round',
            'durationMs': 9000,
            'network': 'telegram',
            'timestampMs': 1760702400000,
          },
          {'roomId': '!b:beeper.local', 'eventId': r'$b', 'kind': 'voice'},
          {
            'roomId': '!c:beeper.local',
            'eventId': r'$c',
            'kind': 'voice',
            'network': 'Not A Label!',
          },
        ],
      };
      final transport = LocalSourceTransport(NoMatrix(), fixture.socket);
      final since = DateTime.utc(2026, 10, 17, 11);
      final page = await transport.recent(cursor: 10, since: since, limit: 50);
      expect(fixture.requests.single, {
        'accountId': '@fixture:example.invalid',
        'cursor': 10,
        'sinceMs': since.millisecondsSinceEpoch,
        'limit': 50,
        '_path': '/recent',
      });
      expect(page!.cursor, 12);
      expect(page.items.map((i) => i.kind), [
        AutoTranscriptionKind.round,
        AutoTranscriptionKind.voice,
        AutoTranscriptionKind.voice,
      ]);
      expect(page.items.first.durationMs, 9000);
      expect(page.items.first.network, 'telegram');
      expect(page.items.first.timestamp, DateTime.utc(2025, 10, 17, 12));
      expect(page.items[1].network, 'unknown');
      expect(page.items[2].network, 'unknown');
    },
  );

  for (final (name, body) in [
    ('cursor moving backwards', {'cursor': 9, 'items': []}),
    (
      'cloud room',
      {
        'cursor': 11,
        'items': [
          {'roomId': '!a:example.org', 'eventId': r'$a', 'kind': 'voice'},
        ],
      },
    ),
    (
      'unknown kind',
      {
        'cursor': 11,
        'items': [
          {'roomId': '!a:beeper.local', 'eventId': r'$a', 'kind': 'image'},
        ],
      },
    ),
    (
      'bad event id',
      {
        'cursor': 11,
        'items': [
          {'roomId': '!a:beeper.local', 'eventId': 'a', 'kind': 'voice'},
        ],
      },
    ),
    (
      'negative duration',
      {
        'cursor': 11,
        'items': [
          {
            'roomId': '!a:beeper.local',
            'eventId': r'$a',
            'kind': 'voice',
            'durationMs': -1,
          },
        ],
      },
    ),
    ('not an object', [1, 2]),
  ]) {
    test('recent scan rejects $name', () async {
      final fixture = await FixtureSource.start(roundMetadata);
      fixture.recent = (_) => body;
      final transport = LocalSourceTransport(NoMatrix(), fixture.socket);
      await expectLater(
        transport.recent(cursor: 10),
        throwsA(
          isA<WorkerFailure>().having(
            (e) => e.code,
            'code',
            'invalid_recent_response',
          ),
        ),
      );
    });
  }

  test(
    'scan and audit never collide with a running export on the 1-slot adapter',
    () async {
      final release = Completer<void>();
      final fixture = await FixtureSource.start(roundMetadata);
      fixture.delay = (request) async {
        if (request['mode'] == 'audio') await release.future;
      };
      final transport = LocalSourceTransport(NoMatrix(), fixture.socket);
      final export = transport.loadAudio(source, Cancellation());
      while (fixture.count('audio') == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // Optional scan skips this interval rather than queueing.
      expect(await transport.recent(cursor: 1), isNull);
      final probe = transport.sourceRedacted(source);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fixture.requests.where((r) => r['_path'] == '/recent'), isEmpty);
      release.complete();
      expect((await export).bytes, fixture.media);
      expect(await probe, isFalse);
      expect(fixture.maxActive, 1);
    },
  );
}

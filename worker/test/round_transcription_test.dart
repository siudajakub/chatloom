// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/matrix_transport.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/transcriber.dart';
import 'package:test/test.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected database access');
}

class _SourceRoom extends Room {
  Event? source;
  _SourceRoom(Client client)
    : super(id: '!fixture:example.invalid', client: client);
  @override
  Future<Event?> getEventById(String eventID) async => source;
}

class _Transport extends MatrixFeatureTransport {
  final _SourceRoom selected;
  _Transport(super.client, this.selected);
  @override
  Future<Room> room(ConversationRef ref) async => selected;
}

class _SourceEvent extends Event {
  int downloads = 0;
  final void Function()? afterDownload;
  _SourceEvent(Room room, Map<String, dynamic> content, {this.afterDownload})
    : super(
        room: room,
        content: content,
        type: EventTypes.Message,
        eventId: r'$round',
        senderId: '@fixture:example.invalid',
        originServerTs: DateTime.utc(2026),
      );
  @override
  Future<MatrixFile> downloadAndDecryptAttachment({
    bool getThumbnail = false,
    Future<Uint8List> Function(Uri)? downloadCallback,
    bool fromLocalStoreOnly = false,
    bool skipScanner = false,
    bool cacheAttachment = true,
    void Function(int)? onDownloadProgress,
  }) async {
    downloads++;
    afterDownload?.call();
    return MatrixFile(
      bytes: Uint8List.fromList([1, 2, 3]),
      name: 'round.mp4',
      mimeType: 'video/mp4',
    );
  }
}

Map<String, dynamic> _content({
  Object marker = true,
  Map<String, dynamic> extra = const {},
}) => {
  'msgtype': 'm.video',
  'body': 'round.mp4',
  'info': {
    'fi.mau.telegram.round_message': marker,
    'mimetype': 'video/mp4',
    'size': 3,
  },
  ...extra,
};

class _InspectUploadClient extends http.BaseClient {
  final Future<void> Function(http.MultipartRequest) inspect;
  _InspectUploadClient(this.inspect);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await inspect(request as http.MultipartRequest);
    return http.StreamedResponse(
      Stream.value(utf8.encode('{"text":"synthetic result"}')),
      200,
    );
  }
}

void main() {
  final ffmpeg = Platform.environment['FFMPEG_PATH'] ?? 'ffmpeg';
  final ffprobe = Platform.environment['FFPROBE_PATH'] ?? 'ffprobe';
  final sourceRef = SourceEventRef(
    conversation: const ConversationRef(
      accountId: 'fixture',
      roomId: '!fixture:example.invalid',
    ),
    eventId: r'$round',
  );

  test('only unprotected speech media reaches the attachment loader', () async {
    final client = Client('round worker fixture', database: _UnusedDatabase());
    final room = _SourceRoom(client);
    final transport = _Transport(client, room);
    for (final content in [
      // GIF-style silent loops, images and text never carry speech.
      {
        'msgtype': 'm.video',
        'body': 'loop.mp4',
        'info': {'mimetype': 'video/mp4', 'size': 3, 'fi.mau.gif': true},
      },
      {
        'msgtype': 'm.video',
        'body': 'anim.gif',
        'info': {'mimetype': 'image/gif', 'size': 3},
      },
      {
        'msgtype': 'm.file',
        'body': 'notes.pdf',
        'info': {'mimetype': 'application/pdf', 'size': 3},
      },
      {
        'msgtype': 'm.image',
        'body': 'photo.jpg',
        'info': {'mimetype': 'image/jpeg', 'size': 3},
      },
      {
        'msgtype': 'm.video',
        'body': 'huge.mp4',
        'info': {'mimetype': 'video/mp4', 'size': 250000001},
      },
      _content(extra: {'view_once': true}),
      _content(extra: {'ttl_seconds': 15}),
      _content(extra: {'protected_content': true}),
      _content(extra: {'protected_content': 'unknown'}),
      _content(
        extra: {
          'pl.personal.chat.telegram.media_policy': {
            'version': 1,
            'transfer_allowed': false,
            'reason': 'time_limited',
            'ttl_seconds': 15,
            'view_once': false,
            'protected_content': null,
            'lazy_supported': false,
          },
        },
      ),
    ]) {
      final event = room.source = _SourceEvent(room, content);
      await expectLater(
        transport.loadAudio(sourceRef, Cancellation()),
        throwsA(isA<WorkerFailure>()),
      );
      expect(event.downloads, 0);
    }
    final allowed = room.source = _SourceEvent(room, _content());
    final audio = await transport.loadAudio(sourceRef, Cancellation());
    expect(allowed.downloads, 1);
    expect(audio.mimeType, 'video/mp4');
    final ordinaryAudio = room.source = _SourceEvent(room, {
      'msgtype': MessageTypes.Audio,
      'body': 'audio.m4a',
      'info': {'mimetype': 'audio/mp4', 'size': 3},
    });
    await transport.loadAudio(sourceRef, Cancellation());
    expect(ordinaryAudio.downloads, 1);
    // Ordinary videos (any container), malformed round markers and media
    // sent as files are transcribed from their audio track as well.
    for (final content in [
      _content(marker: false),
      _content(marker: 'true'),
      {
        'msgtype': 'm.video',
        'body': 'clip.webm',
        'info': {'mimetype': 'video/webm', 'size': 3},
      },
      {
        'msgtype': 'm.video',
        'body': 'clip.mov',
        'info': {'mimetype': 'video/quicktime', 'size': 3},
      },
      {
        'msgtype': 'm.file',
        'body': 'lecture.mkv',
        'info': {'mimetype': 'video/x-matroska', 'size': 3},
      },
      {'msgtype': 'm.file', 'body': 'memo.ogg'},
    ]) {
      final event = room.source = _SourceEvent(room, content);
      await transport.loadAudio(sourceRef, Cancellation());
      expect(event.downloads, 1, reason: '${content['body']}');
    }
    final facts = await transport.mediaFacts(sourceRef);
    expect(facts!.kind, AutoTranscriptionKind.audio);
  });

  test('disappearing messages and chats never reach the loader', () async {
    final client = Client('round worker fixture', database: _UnusedDatabase());
    final room = _SourceRoom(client);
    final transport = _Transport(client, room);
    Future<void> refused(Map<String, dynamic> content) async {
      final event = room.source = _SourceEvent(room, content);
      await expectLater(
        transport.loadAudio(sourceRef, Cancellation()),
        throwsA(
          isA<WorkerFailure>().having((e) => e.code, 'code', 'protected_media'),
        ),
      );
      expect(event.downloads, 0);
    }

    final voice = {
      'msgtype': MessageTypes.Audio,
      'body': 'audio.ogg',
      'info': {'mimetype': 'audio/ogg', 'size': 3},
    };
    // mautrix bridgev2 marks the message itself.
    await refused({
      ...voice,
      beeperDisappearingTimerKey: {'type': 'after_read', 'timer': 60000},
    });
    await refused({...voice, beeperDisappearingTimerKey: 'garbled'});
    await refused(
      _content(
        extra: {
          beeperDisappearingTimerKey: {'type': 'after_send', 'timer': 1000},
        },
      ),
    );
    // The chat's current setting (room state), including malformed values.
    void roomTimer(Map<String, dynamic> content) => room.setState(
      StrippedStateEvent(
        type: beeperDisappearingTimerKey,
        content: content,
        senderId: '@bridge:example.invalid',
        stateKey: '',
      ),
    );
    roomTimer({'type': 'after_read', 'timer': 86400000});
    await refused(voice);
    roomTimer({'type': 7});
    await refused(voice);
    // An explicit "off" ({} from mautrix) allows ordinary transcription.
    roomTimer(<String, dynamic>{});
    final allowed = room.source = _SourceEvent(room, voice);
    await transport.loadAudio(sourceRef, Cancellation());
    expect(allowed.downloads, 1);
  });

  test(
    'protection appearing during download prevents decoder/provider access',
    () async {
      final client = Client(
        'round worker fixture',
        database: _UnusedDatabase(),
      );
      final room = _SourceRoom(client);
      final content = _content();
      room.source = _SourceEvent(
        room,
        content,
        afterDownload: () {
          content['protected_content'] = true;
        },
      );
      await expectLater(
        _Transport(client, room).loadAudio(sourceRef, Cancellation()),
        throwsA(
          isA<WorkerFailure>().having(
            (failure) => failure.code,
            'code',
            'protected_media',
          ),
        ),
      );
    },
  );

  test(
    'round MP4 extracts only audio and drops video/metadata before provider',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'round_transcript_fixture_',
      );
      addTearDown(() async => directory.delete(recursive: true));
      final source = File('${directory.path}/source.mp4');
      final encoded = await Process.run(ffmpeg, [
        '-nostdin',
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        'color=c=black:s=384x384:r=10:d=1',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:duration=1',
        '-c:v',
        'libx264',
        '-pix_fmt',
        'yuv420p',
        '-c:a',
        'aac',
        '-shortest',
        '-metadata',
        'comment=ROUND_PRIVATE_METADATA_FIXTURE',
        source.path,
      ]);
      expect(
        encoded.exitCode,
        0,
        reason: 'Configured media runtime must encode fixture MP4',
      );
      var uploads = 0;
      final service = OpenAiTranscriber(
        'synthetic-key',
        temporaryRoot: '${directory.path}/leases',
        ffmpeg: ffmpeg,
        ffprobe: '',
        clientFactory: () => _InspectUploadClient((request) async {
          uploads++;
          expect(request.files, hasLength(1));
          final file = request.files.single;
          expect(file.filename, 'audio.mp3');
          final bytes = await file.finalize().toBytes();
          expect(
            latin1.decode(bytes),
            isNot(contains('ROUND_PRIVATE_METADATA_FIXTURE')),
          );
          final uploaded = File('${directory.path}/provider.mp3');
          await uploaded.writeAsBytes(bytes);
          final probe = await Process.run(ffprobe, [
            '-v',
            'error',
            '-show_entries',
            'stream=codec_type,codec_name',
            '-of',
            'json',
            uploaded.path,
          ]);
          expect(probe.exitCode, 0);
          final streams =
              (jsonDecode(probe.stdout as String) as Map)['streams'] as List;
          expect(streams, hasLength(1));
          expect(streams.single['codec_type'], 'audio');
          expect(streams.single['codec_name'], 'mp3');
        }),
      );
      final result = await service.transcribe(
        AudioSource(await source.readAsBytes(), 'video/mp4'),
        null,
        Cancellation(),
        (_, _) {},
      );
      expect(result.text, 'synthetic result');
      expect(uploads, 1);
      expect(
        await Directory('${directory.path}/leases').list().toList(),
        isEmpty,
      );
    },
  );

  test(
    'automatic loads refuse undeclared or oversized media unfetched',
    () async {
      final client = Client(
        'round worker fixture',
        database: _UnusedDatabase(),
      );
      final room = _SourceRoom(client);
      final transport = _Transport(client, room);
      final undeclared = room.source = _SourceEvent(room, {
        'msgtype': 'm.video',
        'body': 'clip.mp4',
        'info': {'mimetype': 'video/mp4'},
      });
      await expectLater(
        transport.loadAudioBounded(
          sourceRef,
          Cancellation(),
          maxBytes: 1000,
          requireDeclaredSize: true,
        ),
        throwsA(
          isA<WorkerFailure>().having(
            (e) => e.code,
            'code',
            'auto_skipped_unknown_size',
          ),
        ),
      );
      expect(undeclared.downloads, 0);
      // A manual request keeps today's behaviour for undeclared sizes.
      await transport.loadAudioBounded(
        sourceRef,
        Cancellation(),
        maxBytes: 1000,
        requireDeclaredSize: false,
      );
      expect(undeclared.downloads, 1);
      final oversized = room.source = _SourceEvent(room, {
        'msgtype': 'm.video',
        'body': 'clip.mp4',
        'info': {'mimetype': 'video/mp4', 'size': 1001},
      });
      await expectLater(
        transport.loadAudioBounded(
          sourceRef,
          Cancellation(),
          maxBytes: 1000,
          requireDeclaredSize: true,
        ),
        throwsA(
          isA<WorkerFailure>().having(
            (e) => e.code,
            'code',
            'source_too_large',
          ),
        ),
      );
      expect(oversized.downloads, 0);
    },
  );

  group('bounded media download', () {
    final uri = Uri.parse('https://media.example.invalid/download');
    MockClient streaming(List<List<int>> chunks, {int? length}) =>
        MockClient.streaming((request, _) async {
          expect(request.headers['authorization'], 'Bearer token');
          return http.StreamedResponse(
            Stream.fromIterable(chunks),
            200,
            contentLength: length,
          );
        });

    test('returns the body within the bound', () async {
      final bytes = await boundedMediaDownload(
        streaming([
          [1, 2],
          [3],
        ]),
        uri,
        accessToken: 'token',
        maxBytes: 3,
        cancel: Cancellation(),
      );
      expect(bytes, [1, 2, 3]);
    });

    test('aborts once the stream passes the bound', () async {
      var produced = 0;
      final client = MockClient.streaming((request, _) async {
        Stream<List<int>> body() async* {
          for (var i = 0; i < 1000; i++) {
            produced++;
            yield List<int>.filled(1024, 0);
          }
        }

        return http.StreamedResponse(body(), 200);
      });
      await expectLater(
        boundedMediaDownload(
          client,
          uri,
          accessToken: 'token',
          maxBytes: 4096,
          cancel: Cancellation(),
        ),
        throwsA(
          isA<WorkerFailure>().having(
            (e) => e.code,
            'code',
            'source_too_large',
          ),
        ),
      );
      expect(produced, lessThan(10), reason: 'stream cancelled early');
    });

    test('a declared Content-Length above the bound is refused', () async {
      await expectLater(
        boundedMediaDownload(
          streaming([
            [1],
          ], length: 5000),
          uri,
          accessToken: 'token',
          maxBytes: 4096,
          cancel: Cancellation(),
        ),
        throwsA(
          isA<WorkerFailure>().having(
            (e) => e.code,
            'code',
            'source_too_large',
          ),
        ),
      );
    });

    test('HTTP errors fail without a body copy', () async {
      final client = MockClient.streaming(
        (request, _) async =>
            http.StreamedResponse(Stream.value([1, 2, 3]), 404),
      );
      await expectLater(
        boundedMediaDownload(
          client,
          uri,
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
}

// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Synthetic media only: every fixture is a tiny sine tone (or a silent
// picture) generated locally with the configured ffmpeg; the provider is a
// fake. Nothing reaches OpenAI.
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/transcriber.dart';
import 'package:test/test.dart';

/// Records every upload and checks it is a single mono 16 kHz MP3 stream.
class _FakeProvider extends http.BaseClient {
  final String ffprobe;
  final Directory directory;
  final List<int> statuses;
  final Map<String, String> headers;
  final Object? Function(int call)? failure;
  int calls = 0;
  final uploads = <Map<String, Object?>>[];
  _FakeProvider(
    this.ffprobe,
    this.directory, {
    this.statuses = const [],
    this.headers = const {},
    this.failure,
  });

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final call = calls++;
    final thrown = failure?.call(call);
    if (thrown != null) throw thrown;
    final multipart = request as http.MultipartRequest;
    final bytes = await multipart.files.single.finalize().toBytes();
    final file = File('${directory.path}/upload-$call.mp3');
    await file.writeAsBytes(bytes);
    final probe = await Process.run(ffprobe, [
      '-v',
      'error',
      '-show_entries',
      'stream=codec_type,codec_name,channels,sample_rate',
      '-of',
      'json',
      file.path,
    ]);
    expect(probe.exitCode, 0);
    final streams =
        (jsonDecode(probe.stdout as String) as Map)['streams'] as List;
    uploads.add({
      'bytes': bytes.length,
      'streams': streams,
      'filename': multipart.files.single.filename,
      'model': multipart.fields['model'],
    });
    final status = call < statuses.length ? statuses[call] : 200;
    return http.StreamedResponse(
      Stream.value(
        utf8.encode(
          status == 200 ? '{"text":"synthetic speech"}' : '{"error":{}}',
        ),
      ),
      status,
      headers: status == 200 ? const {} : headers,
    );
  }
}

void main() {
  final ffmpeg = Platform.environment['FFMPEG_PATH'] ?? '/usr/bin/ffmpeg';
  final ffprobe = Platform.environment['FFPROBE_PATH'] ?? '/usr/bin/ffprobe';
  late Directory directory;
  final fixtures = <String, File>{};

  /// Builds a fixture once: [video] adds a tiny picture stream, [audio] a
  /// 440 Hz tone of [seconds].
  Future<File> fixture(
    String name, {
    required List<String> codecs,
    bool video = true,
    bool audio = true,
    int seconds = 1,
    String? format,
  }) async {
    final cached = fixtures[name];
    if (cached != null) return cached;
    final file = File('${directory.path}/fixtures/$name');
    await file.parent.create(recursive: true);
    final result = await Process.run(ffmpeg, [
      '-nostdin',
      '-v',
      'error',
      '-threads',
      '1',
      if (video) ...[
        '-f',
        'lavfi',
        '-i',
        'color=c=black:s=64x64:r=5:d=$seconds',
      ],
      if (audio) ...[
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:sample_rate=16000:duration=$seconds',
      ],
      ...codecs,
      if (video && audio) '-shortest',
      '-metadata',
      'title=PRIVATE_FIXTURE_TITLE',
      if (format != null) ...['-f', format],
      file.path,
    ]);
    expect(
      result.exitCode,
      0,
      reason: 'ffmpeg must encode the $name fixture: ${result.stderr}',
    );
    return fixtures[name] = file;
  }

  setUpAll(() async {
    expect(
      Process.runSync(ffmpeg, ['-version']).exitCode,
      0,
      reason: 'Configure FFMPEG_PATH; media tests must not silently skip.',
    );
    directory = await Directory.systemTemp.createTemp('media_extraction_');
  });
  tearDownAll(() => directory.delete(recursive: true));

  OpenAiTranscriber transcriber(
    _FakeProvider provider, {
    String? probe,
    List<Duration>? sleeps,
  }) => OpenAiTranscriber(
    'synthetic-key',
    temporaryRoot: '${directory.path}/work',
    ffmpeg: ffmpeg,
    ffprobe: probe ?? ffprobe,
    clientFactory: () => provider,
    sleep: (wait) async => sleeps?.add(wait),
  );

  Future<void> expectCleanWorkDirectory() async {
    final work = Directory('${directory.path}/work');
    if (await work.exists()) expect(await work.list().toList(), isEmpty);
  }

  final containers = <(String, String, List<String>, String?)>[
    ('mp4 (H.264/AAC)', 'clip.mp4', ['-c:v', 'libx264', '-c:a', 'aac'], null),
    (
      'webm (VP8/Opus)',
      'clip.webm',
      ['-c:v', 'libvpx', '-deadline', 'realtime', '-c:a', 'libopus'],
      null,
    ),
    (
      'mov (MJPEG/PCM)',
      'clip.mov',
      ['-c:v', 'mjpeg', '-c:a', 'pcm_s16le'],
      null,
    ),
    ('3gp (H.264/AAC)', 'clip.3gp', ['-c:v', 'libx264', '-c:a', 'aac'], '3gp'),
    ('mkv (MJPEG/FLAC)', 'clip.mkv', ['-c:v', 'mjpeg', '-c:a', 'flac'], null),
    ('m4v (H.264/AAC)', 'clip.m4v', ['-c:v', 'libx264', '-c:a', 'aac'], 'mp4'),
  ];

  for (final (label, name, codecs, format) in containers) {
    test('video $label: only the audio track reaches the provider', () async {
      final source = await fixture(name, codecs: codecs, format: format);
      final provider = _FakeProvider(ffprobe, directory);
      double? measured;
      final result = await transcriber(provider).transcribe(
        AudioSource(await source.readAsBytes(), 'video/x-test'),
        null,
        Cancellation(),
        (duration, _) => measured = duration,
      );
      expect(result.text, 'synthetic speech');
      expect(measured, closeTo(1, 0.15));
      expect(provider.uploads, hasLength(1));
      final upload = provider.uploads.single;
      expect(upload['filename'], 'audio.mp3');
      expect(upload['model'], transcriptionModel);
      final streams = upload['streams'] as List;
      expect(streams, hasLength(1), reason: 'no video stream is uploaded');
      expect(streams.single['codec_type'], 'audio');
      expect(streams.single['codec_name'], 'mp3');
      expect(streams.single['channels'], 1);
      expect(streams.single['sample_rate'], transcriptionSampleRate);
      // About 4 KB per second at 32 kbit/s.
      expect(upload['bytes'] as int, lessThan(12000));
      await expectCleanWorkDirectory();
    });
  }

  for (final (label, name, codecs) in [
    ('ogg opus voice note', 'voice.ogg', ['-c:a', 'libopus']),
    ('mp3 audio', 'audio.mp3', ['-c:a', 'libmp3lame']),
    ('m4a audio', 'audio.m4a', ['-c:a', 'aac']),
  ]) {
    test('$label converts to mono 16 kHz MP3', () async {
      final source = await fixture(name, codecs: codecs, video: false);
      final provider = _FakeProvider(ffprobe, directory);
      await transcriber(provider).transcribe(
        AudioSource(await source.readAsBytes(), 'audio/x-test'),
        null,
        Cancellation(),
        (_, _) {},
      );
      expect(provider.uploads, hasLength(1));
      final streams = provider.uploads.single['streams'] as List;
      expect(streams.single['sample_rate'], transcriptionSampleRate);
      await expectCleanWorkDirectory();
    });
  }

  for (final probe in ['ffprobe', 'no ffprobe']) {
    test('video without an audio track is skipped unpaid ($probe)', () async {
      final source = await fixture(
        'silent.mp4',
        codecs: ['-c:v', 'libx264'],
        audio: false,
      );
      final provider = _FakeProvider(ffprobe, directory);
      var estimated = false;
      await expectLater(
        transcriber(
          provider,
          probe: probe == 'ffprobe' ? ffprobe : '',
        ).transcribe(
          AudioSource(await source.readAsBytes(), 'video/mp4'),
          null,
          Cancellation(),
          (_, _) => estimated = true,
        ),
        throwsA(
          isA<WorkerFailure>().having((e) => e.code, 'code', 'no_audio_track'),
        ),
      );
      expect(provider.calls, 0);
      expect(estimated, isFalse);
      await expectCleanWorkDirectory();
    });
  }

  test('an over-long clip is measured and stopped before upload', () async {
    final source = await fixture(
      'long.mp4',
      codecs: ['-c:v', 'libx264', '-c:a', 'aac'],
      seconds: 12,
    );
    final provider = _FakeProvider(ffprobe, directory);
    await expectLater(
      transcriber(provider).transcribe(
        AudioSource(await source.readAsBytes(), 'video/mp4'),
        null,
        Cancellation(),
        (duration, _) {
          // The engine's automatic limit (e.g. maxSeconds 10) throws here.
          expect(duration, closeTo(12, 0.2));
          throw const WorkerFailure('auto_skipped_duration');
        },
      ),
      throwsA(
        isA<WorkerFailure>().having(
          (e) => e.code,
          'code',
          'auto_skipped_duration',
        ),
      ),
    );
    expect(provider.calls, 0);
    await expectCleanWorkDirectory();
  });

  test('metadata and the video stream never reach the provider', () async {
    final source = await fixture(
      'clip.mp4',
      codecs: ['-c:v', 'libx264', '-c:a', 'aac'],
    );
    final provider = _FakeProvider(ffprobe, directory);
    await transcriber(provider).transcribe(
      AudioSource(await source.readAsBytes(), 'video/mp4'),
      null,
      Cancellation(),
      (_, _) {},
    );
    final uploaded = await File('${directory.path}/upload-0.mp3').readAsBytes();
    expect(latin1.decode(uploaded), isNot(contains('PRIVATE_FIXTURE_TITLE')));
  });

  group('provider retries never double-charge', () {
    Future<File> voice() =>
        fixture('voice.ogg', codecs: ['-c:a', 'libopus'], video: false);

    test(
      '429 and 5xx are retried with backoff, honouring Retry-After',
      () async {
        final provider = _FakeProvider(
          ffprobe,
          directory,
          statuses: [429, 503],
          headers: {'retry-after': '5'},
        );
        final sleeps = <Duration>[];
        final result = await transcriber(provider, sleeps: sleeps).transcribe(
          AudioSource(await (await voice()).readAsBytes(), 'audio/ogg'),
          null,
          Cancellation(),
          (_, _) {},
        );
        expect(result.text, 'synthetic speech');
        expect(provider.calls, 3);
        expect(sleeps, [
          const Duration(seconds: 5),
          const Duration(seconds: 5),
        ]);
      },
    );

    test('persistent overload fails after the attempt limit', () async {
      final provider = _FakeProvider(
        ffprobe,
        directory,
        statuses: [503, 503, 503, 503],
      );
      final sleeps = <Duration>[];
      await expectLater(
        transcriber(provider, sleeps: sleeps).transcribe(
          AudioSource(await (await voice()).readAsBytes(), 'audio/ogg'),
          null,
          Cancellation(),
          (_, _) {},
        ),
        throwsA(
          isA<WorkerFailure>().having(
            (e) => e.code,
            'code',
            'openai_unavailable',
          ),
        ),
      );
      expect(provider.calls, transcriptionProviderAttempts);
      expect(sleeps, [const Duration(seconds: 1), const Duration(seconds: 2)]);
    });

    for (final status in [500, 504]) {
      test(
        '$status may follow a billed request: paid-unknown, no retry',
        () async {
          final provider = _FakeProvider(
            ffprobe,
            directory,
            statuses: [status],
          );
          await expectLater(
            transcriber(provider, sleeps: []).transcribe(
              AudioSource(await (await voice()).readAsBytes(), 'audio/ogg'),
              null,
              Cancellation(),
              (_, _) {},
            ),
            throwsA(isA<PaidRequestUnknown>()),
          );
          expect(provider.calls, 1);
        },
      );
    }

    test('502 is retried like 503', () async {
      final provider = _FakeProvider(ffprobe, directory, statuses: [502]);
      final sleeps = <Duration>[];
      await transcriber(provider, sleeps: sleeps).transcribe(
        AudioSource(await (await voice()).readAsBytes(), 'audio/ogg'),
        null,
        Cancellation(),
        (_, _) {},
      );
      expect(provider.calls, 2);
      expect(sleeps, [const Duration(seconds: 1)]);
    });

    test('a definitive rejection is not retried', () async {
      final provider = _FakeProvider(ffprobe, directory, statuses: [400]);
      await expectLater(
        transcriber(provider).transcribe(
          AudioSource(await (await voice()).readAsBytes(), 'audio/ogg'),
          null,
          Cancellation(),
          (_, _) {},
        ),
        throwsA(
          isA<WorkerFailure>().having((e) => e.code, 'code', 'openai_rejected'),
        ),
      );
      expect(provider.calls, 1);
    });

    test('a refused connection is retried; a dropped one is not', () async {
      final refused = _FakeProvider(
        ffprobe,
        directory,
        failure: (call) => call == 0
            ? const SocketException(
                'Connection refused',
                osError: OSError('Connection refused', 111),
              )
            : null,
      );
      final result = await transcriber(refused, sleeps: []).transcribe(
        AudioSource(await (await voice()).readAsBytes(), 'audio/ogg'),
        null,
        Cancellation(),
        (_, _) {},
      );
      expect(result.text, 'synthetic speech');
      expect(refused.calls, 2);

      final dropped = _FakeProvider(
        ffprobe,
        directory,
        failure: (_) => const SocketException('Connection reset by peer'),
      );
      await expectLater(
        transcriber(dropped, sleeps: []).transcribe(
          AudioSource(await (await voice()).readAsBytes(), 'audio/ogg'),
          null,
          Cancellation(),
          (_, _) {},
        ),
        throwsA(isA<PaidRequestUnknown>()),
      );
      expect(dropped.calls, 1);
    });
  });
}

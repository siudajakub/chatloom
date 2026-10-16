// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/config.dart';
import 'package:personal_worker/src/transcriber.dart';
import 'package:test/test.dart';

Uint8List syntheticWav({int seconds = 1}) {
  final samples = 16000 * seconds;
  final bytes = Uint8List(44 + samples * 2);
  final data = ByteData.sublistView(bytes);
  for (final entry in {0: 'RIFF', 8: 'WAVE', 12: 'fmt ', 36: 'data'}.entries) {
    bytes.setRange(entry.key, entry.key + 4, ascii.encode(entry.value));
  }
  data.setUint32(4, bytes.length - 8, Endian.little);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  data.setUint32(40, samples * 2, Endian.little);
  return bytes;
}

void main() {
  final ffmpeg = Platform.environment['FFMPEG_PATH'] ?? 'ffmpeg';
  setUpAll(() {
    expect(
      Process.runSync(ffmpeg, ['-version']).exitCode,
      0,
      reason:
          'Run scripts/setup-media-runtime.sh and configure FFMPEG_PATH; media tests must not silently skip.',
    );
  });
  test(
    'converts silent WAV, uploads only audio/model and cleans temp',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'worker-audio-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      var calls = 0;
      double? estimate;
      final service = OpenAiTranscriber(
        'synthetic-key',
        temporaryRoot: directory.path,
        clientFactory: () => MockClient((request) async {
          calls++;
          expect(
            request.url.toString(),
            'https://api.openai.com/v1/audio/transcriptions',
          );
          final body = latin1.decode(request.bodyBytes);
          expect(body, contains('gpt-transcribe'));
          expect(body, contains('audio.mp3'));
          expect(request.bodyBytes.length, lessThan(transcriptionMaxBytes));
          expect(body, isNot(contains('chatID')));
          expect(body, isNot(contains('roomId')));
          expect(body, isNot(contains('senderName')));
          return http.Response(jsonEncode({'text': 'Synthetic result'}), 200);
        }),
      );
      final result = await service.transcribe(
        AudioSource(syntheticWav(), 'audio/wav'),
        null,
        Cancellation(),
        (_, cost) => estimate = cost,
      );
      expect(result.text, 'Synthetic result');
      expect(estimate, closeTo(0.0045 / 60, 0.000001));
      expect(calls, 1);
      expect(await directory.list().toList(), isEmpty);
    },
  );
  test('uncertain provider failure does not retry paid request', () async {
    final directory = await Directory.systemTemp.createTemp(
      'worker-audio-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    var calls = 0;
    final service = OpenAiTranscriber(
      'synthetic-key',
      temporaryRoot: directory.path,
      clientFactory: () => MockClient((_) async {
        calls++;
        throw const SocketException('synthetic');
      }),
    );
    await expectLater(
      service.transcribe(
        AudioSource(syntheticWav(), 'audio/wav'),
        null,
        Cancellation(),
        (_, _) {},
      ),
      throwsA(isA<PaidRequestUnknown>()),
    );
    expect(calls, 1);
    expect(await directory.list().toList(), isEmpty);
  });
  test('cancel before conversion makes no paid request', () async {
    final directory = await Directory.systemTemp.createTemp(
      'worker-audio-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    var calls = 0;
    final service = OpenAiTranscriber(
      'synthetic-key',
      temporaryRoot: directory.path,
      clientFactory: () => MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    final cancellation = Cancellation()..cancel();
    await expectLater(
      service.transcribe(
        AudioSource(syntheticWav(), 'audio/wav'),
        null,
        cancellation,
        (_, _) {},
      ),
      throwsA(isA<WorkerFailure>()),
    );
    expect(calls, 0);
    expect(await directory.list().toList(), isEmpty);
  });
  test(
    'missing ffprobe decodes duration with exact configured ffmpeg',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'worker-probe-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final service = OpenAiTranscriber(
        'synthetic-key',
        temporaryRoot: directory.path,
        ffmpeg: ffmpeg,
        ffprobe: '${directory.path}/absent-ffprobe',
        clientFactory: () =>
            MockClient((_) async => http.Response('{"text":"fixture"}', 200)),
      );
      final result = await service.transcribe(
        AudioSource(syntheticWav(), 'audio/wav'),
        null,
        Cancellation(),
        (_, _) {},
      );
      expect(result.durationSeconds, closeTo(1, 0.01));
      expect(await directory.list().toList(), isEmpty);
    },
  );
  test(
    'real OGG Opus converts through ffmpeg fallback and no metadata upload',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'worker-ogg-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final wav = File('${directory.path}/input.wav');
      await wav.writeAsBytes(syntheticWav());
      final ogg = File('${directory.path}/input.ogg');
      final conversion = await Process.run(ffmpeg, [
        '-nostdin',
        '-v',
        'error',
        '-i',
        wav.path,
        '-c:a',
        'libopus',
        ogg.path,
      ]);
      expect(conversion.exitCode, 0);
      var calls = 0;
      final service = OpenAiTranscriber(
        'synthetic-key',
        temporaryRoot: '${directory.path}/audio',
        ffprobe: '',
        clientFactory: () => MockClient((request) async {
          calls++;
          expect(
            latin1.decode(request.bodyBytes),
            isNot(contains('input.ogg')),
          );
          return http.Response('{"text":"fixture"}', 200);
        }),
      );
      final result = await service.transcribe(
        AudioSource(await ogg.readAsBytes(), 'audio/ogg'),
        null,
        Cancellation(),
        (_, _) {},
      );
      expect(result.durationSeconds, closeTo(1, 0.03));
      expect(calls, 1);
      expect(
        await Directory('${directory.path}/audio').list().toList(),
        isEmpty,
      );
    },
  );
  test(
    'malformed audio makes no paid request and cleans temporary plaintext',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'worker-malformed-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      var calls = 0;
      final service = OpenAiTranscriber(
        'synthetic-key',
        temporaryRoot: directory.path,
        ffprobe: '',
        clientFactory: () => MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        service.transcribe(
          AudioSource(Uint8List.fromList([1, 2, 3]), 'audio/ogg'),
          null,
          Cancellation(),
          (_, _) {},
        ),
        throwsA(isA<WorkerFailure>()),
      );
      expect(calls, 0);
      expect(await directory.list().toList(), isEmpty);
    },
  );
  test(
    'input above 25 MB is compressed and split into safe actual uploads',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'worker-large-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final audio = syntheticWav(seconds: 901);
      expect(audio.length, greaterThan(transcriptionMaxBytes));
      var calls = 0;
      final service = OpenAiTranscriber(
        'synthetic-key',
        temporaryRoot: directory.path,
        ffprobe: '',
        clientFactory: () => MockClient((request) async {
          calls++;
          expect(request.bodyBytes.length, lessThan(transcriptionMaxBytes));
          return http.Response('{"text":"chunk"}', 200);
        }),
      );
      final result = await service.transcribe(
        AudioSource(audio, 'audio/wav'),
        null,
        Cancellation(),
        (_, _) {},
      );
      expect(result.durationSeconds, closeTo(901, 0.1));
      expect(calls, 2);
      expect(result.text, 'chunk\n\nchunk');
      expect(await directory.list().toList(), isEmpty);
    },
  );
  test(
    'process timeout kills child and cleans plaintext before any upload',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'worker-timeout-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final executable = File('${directory.path}/slow-ffmpeg');
      await executable.writeAsString(
        '#!/usr/bin/env python3\nimport time\ntime.sleep(30)\n',
      );
      await Process.run('chmod', ['700', executable.path]);
      var calls = 0;
      final service = OpenAiTranscriber(
        'synthetic-key',
        temporaryRoot: '${directory.path}/audio',
        ffmpeg: executable.path,
        ffprobe: '',
        processTimeout: const Duration(milliseconds: 150),
        clientFactory: () => MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        service.transcribe(
          AudioSource(syntheticWav(), 'audio/wav'),
          null,
          Cancellation(),
          (_, _) {},
        ),
        throwsA(
          isA<WorkerFailure>().having(
            (failure) => failure.code,
            'code',
            'media_conversion_timeout',
          ),
        ),
      );
      expect(calls, 0);
      expect(
        await Directory('${directory.path}/audio').list().toList(),
        isEmpty,
      );
    },
  );
  test(
    'oversized converted artifact is rejected before provider upload',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'worker-boundary-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final executable = File('${directory.path}/oversize-ffmpeg');
      await executable.writeAsString('''#!/usr/bin/env python3
import pathlib,sys
if 's16le' in sys.argv:
    sys.stdout.buffer.write(bytes(32000))
else:
    target=pathlib.Path(sys.argv[-1].replace('%06d','000000'))
    with target.open('wb') as output: output.truncate(25000001)
''');
      await Process.run('chmod', ['700', executable.path]);
      var calls = 0;
      final service = OpenAiTranscriber(
        'synthetic-key',
        temporaryRoot: '${directory.path}/audio',
        ffmpeg: executable.path,
        ffprobe: '',
        clientFactory: () => MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        service.transcribe(
          AudioSource(syntheticWav(), 'audio/wav'),
          null,
          Cancellation(),
          (_, _) {},
        ),
        throwsA(
          isA<WorkerFailure>().having(
            (failure) => failure.code,
            'code',
            'audio_chunk_too_large',
          ),
        ),
      );
      expect(calls, 0);
      expect(
        await Directory('${directory.path}/audio').list().toList(),
        isEmpty,
      );
    },
  );
  test(
    'missing provider key fails before subprocess or temporary data',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'worker-key-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      var calls = 0;
      final service = OpenAiTranscriber(
        '',
        temporaryRoot: directory.path,
        ffmpeg: 'absent-binary',
        clientFactory: () => MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        service.transcribe(
          AudioSource(syntheticWav(), 'audio/wav'),
          null,
          Cancellation(),
          (_, _) {},
        ),
        throwsA(
          isA<WorkerFailure>().having(
            (failure) => failure.code,
            'code',
            'openai_key_missing',
          ),
        ),
      );
      expect(calls, 0);
      expect(await directory.list().toList(), isEmpty);
    },
  );
  test(
    'playlist disguised as audio cannot fetch network or upload local secret',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'worker-playlist-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final secret = File('${directory.path}/private-fixture.txt');
      await secret.writeAsString('LOCAL_PRIVATE_FIXTURE_DO_NOT_SEND');
      final canary = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var fetched = 0;
      var uploads = 0;
      final subscription = canary.listen((request) {
        fetched++;
        request.response.add(syntheticWav());
        request.response.close();
      });
      addTearDown(() async {
        await subscription.cancel();
        await canary.close(force: true);
      });
      final playlist =
          '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:1,\nhttp://127.0.0.1:${canary.port}/canary.wav\n#EXTINF:1,\n${secret.uri}\n#EXT-X-ENDLIST\n';
      final service = OpenAiTranscriber(
        'synthetic-key',
        temporaryRoot: '${directory.path}/audio',
        ffprobe: '',
        clientFactory: () => MockClient((request) async {
          uploads++;
          expect(
            latin1.decode(request.bodyBytes),
            isNot(contains('LOCAL_PRIVATE_FIXTURE_DO_NOT_SEND')),
          );
          return http.Response('{"text":"unexpected"}', 200);
        }),
      );
      await expectLater(
        service.transcribe(
          AudioSource(Uint8List.fromList(utf8.encode(playlist)), 'audio/ogg'),
          null,
          Cancellation(),
          (_, _) {},
        ),
        throwsA(isA<WorkerFailure>()),
      );
      expect(fetched, 0);
      expect(uploads, 0);
      expect(
        await Directory('${directory.path}/audio').list().toList(),
        isEmpty,
      );
    },
  );
  test('media subprocess receives no parent credentials or HOME', () async {
    final directory = await Directory.systemTemp.createTemp(
      'worker-child-env-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final witness = File('${directory.path}/child-env-keys.json');
    final executable = File('${directory.path}/env-ffmpeg');
    await executable.writeAsString('''#!/usr/bin/env python3
import json,os,pathlib,sys
pathlib.Path(${jsonEncode(witness.path)}).write_text(json.dumps(sorted(os.environ)))
if 's16le' in sys.argv:
    sys.stdout.buffer.write(bytes(32000))
else:
    pathlib.Path(sys.argv[-1].replace('%06d','000000')).write_bytes(b'fixture')
''');
    await Process.run('chmod', ['700', executable.path]);
    final service = OpenAiTranscriber(
      'synthetic-key',
      temporaryRoot: '${directory.path}/audio',
      ffmpeg: executable.path,
      ffprobe: '',
      clientFactory: () =>
          MockClient((_) async => http.Response('{"text":"fixture"}', 200)),
    );
    await service.transcribe(
      AudioSource(syntheticWav(), 'audio/wav'),
      null,
      Cancellation(),
      (_, _) {},
    );
    final keys = (jsonDecode(await witness.readAsString()) as List)
        .cast<String>();
    expect(keys, contains('PATH'));
    for (final key in [
      'OPENAI_API_KEY',
      'HOME',
      'CREDENTIALS_DIRECTORY',
      'DATABASE_CIPHER',
      'PUB_CACHE',
      'CARGO_HOME',
      'RUSTUP_HOME',
    ]) {
      expect(keys, isNot(contains(key)));
    }
    expect(await Directory('${directory.path}/audio').list().toList(), isEmpty);
  });
  test('worker credential guard refuses group/world-readable files', () async {
    final directory = await Directory.systemTemp.createTemp(
      'worker-credential-guard-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/fixture-credentials.json');
    await file.writeAsString('{"fixture":true}');
    await Process.run('chmod', ['644', file.path]);
    expect(
      () => requirePrivateFile(file.path),
      throwsA(
        isA<WorkerFailure>().having(
          (failure) => failure.code,
          'code',
          'credentials_permissions',
        ),
      ),
    );
    await Process.run('chmod', ['600', file.path]);
    expect(() => requirePrivateFile(file.path), returnsNormally);
  });
  test('incomplete PCM sample is rejected without provider upload', () async {
    final directory = await Directory.systemTemp.createTemp(
      'worker-progress-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final executable = File('${directory.path}/incomplete-ffmpeg');
    await executable.writeAsString(
      '#!/usr/bin/env python3\nimport sys\nsys.stdout.buffer.write(bytes(1))\n',
    );
    await Process.run('chmod', ['700', executable.path]);
    var calls = 0;
    final service = OpenAiTranscriber(
      'synthetic-key',
      temporaryRoot: '${directory.path}/audio',
      ffmpeg: executable.path,
      ffprobe: '',
      clientFactory: () => MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    await expectLater(
      service.transcribe(
        AudioSource(syntheticWav(), 'audio/wav'),
        null,
        Cancellation(),
        (_, _) {},
      ),
      throwsA(
        isA<WorkerFailure>().having(
          (failure) => failure.code,
          'code',
          'invalid_audio_duration',
        ),
      ),
    );
    expect(calls, 0);
    expect(await Directory('${directory.path}/audio').list().toList(), isEmpty);
  });
  test(
    'explicit codec sandbox requirement refuses before decode or provider upload',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'worker-optional-sandbox-',
      );
      addTearDown(() => directory.delete(recursive: true));
      var calls = 0;
      final service = OpenAiTranscriber(
        'synthetic-key',
        temporaryRoot: directory.path,
        requireCodecSandbox: true,
        ffmpeg: 'absent-binary',
        clientFactory: () => MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        service.transcribe(
          AudioSource(syntheticWav(), 'audio/wav'),
          null,
          Cancellation(),
          (_, _) {},
        ),
        throwsA(
          isA<WorkerFailure>().having(
            (failure) => failure.code,
            'code',
            'codec_sandbox_required',
          ),
        ),
      );
      expect(calls, 0);
      expect(await directory.list().toList(), isEmpty);
    },
  );
}

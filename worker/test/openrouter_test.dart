// SPDX-License-Identifier: AGPL-3.0-or-later
// Transcription through OpenRouter with x-ai/grok-stt-1.0 (the default since
// 2026-10-31): request shape, retries and paid uncertainty, key handling,
// config selection, the stdin probe and timestamp anchoring of Grok-shaped
// answers. Synthetic answers only, written to mirror the structure of real
// Grok answers: nothing here reaches a provider or costs anything.
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/config.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/transcriber.dart';
import 'package:personal_worker/src/transcript_timestamps.dart';
import 'package:personal_worker/src/transcription_check.dart';
import 'package:test/test.dart';

import 'transcriber_test.dart' show syntheticWav;

const _text = 'Cześć Anna, dzwonię w sprawie jutra. Czy o 5 pasuje? Daj znać';

const _words = [
  ('Cześć', 0.12, 0.5),
  ('Anna,', 0.55, 0.9),
  // Grok's tokens carry punctuation the text need not have…
  ('dzwonię,', 1.0, 1.4),
  ('w', 1.45, 1.5),
  ('sprawie', 1.5, 1.9),
  ('jutra.', 1.9, 2.4),
  // …and may differ in case.
  ('czy', 2.9, 3.1),
  ('o', 3.1, 3.2),
  ('5', 3.2, 3.5),
  ('pasuje?', 3.5, 4.1),
  ('Daj', 5.0, 5.3),
  ('znać.', 5.3, 7.6),
];

/// A `verbose_json` answer shaped like Grok's through OpenRouter: one
/// segment holding the whole text (an integer start), every word at the top
/// level (or, [nested], inside the segment), the measured duration and the
/// billed usage.
Map<String, Object?> _grokAnswer({bool nested = false, bool segments = true}) {
  final words = [
    for (final (word, start, end) in _words)
      {'word': word, 'start': start, 'end': end},
  ];
  return {
    'text': _text,
    'usage': {'seconds': 7.8, 'cost': 0.000217},
    'language': 'pl',
    'duration': 7.8,
    if (segments)
      'segments': [
        {
          'id': 0,
          'start': 0,
          'end': 7.6,
          'text': _text,
          if (nested) 'words': words,
        },
      ],
    if (!nested) 'words': words,
  };
}

const _ms = Duration(milliseconds: 1);

List<String> _spans(String text, List<TranscriptSpan> spans) => [
  for (final span in spans) text.substring(span.textStart, span.textEnd),
];

const _anchoredWords = [
  'Cześć',
  'Anna',
  'dzwonię',
  'w',
  'sprawie',
  'jutra',
  'Czy',
  'o',
  '5',
  'pasuje',
  'Daj',
  'znać',
];

void main() {
  group('Grok timestamps', () {
    test('every word anchors despite punctuation and case', () {
      final stamps = chunkTimestamps(_grokAnswer(), _text)!;
      expect(_spans(_text, stamps.segments), [_text]);
      expect(stamps.segments.single.start, Duration.zero);
      expect(stamps.segments.single.end, _ms * 7600);
      expect(_spans(_text, stamps.words), _anchoredWords);
      expect(stamps.words[6].start, _ms * 2900);
      expect(stamps.duration, _ms * 7800);
    });

    test('the apps read word-timed lines from the record', () {
      final record = transcriptTimingRecord(
        [_text],
        [chunkTimestamps(_grokAnswer(), _text)],
      )!;
      final timing = TranscriptTiming.tryParse(record, _text)!;
      expect(timing.approximate, isFalse);
      expect(
        [for (final line in timing.lines) line.text],
        ['Cześć Anna, dzwonię w sprawie jutra.', 'Czy o 5 pasuje?', 'Daj znać'],
      );
      // One segment for the whole note: each line takes its words' times.
      expect(
        [for (final line in timing.lines) line.start],
        [_ms * 120, _ms * 2900, _ms * 5000],
      );
      expect([for (final line in timing.lines) line.words.length], [6, 4, 2]);
      expect(timing.lines[1].wordAt(_ms * 3300), 2);
    });

    test('words nested in segments are used', () {
      final stamps = chunkTimestamps(_grokAnswer(nested: true), _text)!;
      expect(_spans(_text, stamps.words), _anchoredWords);
    });

    test('words without segments make one segment over the text', () {
      final stamps = chunkTimestamps(_grokAnswer(segments: false), _text)!;
      expect(_spans(_text, stamps.segments), [_text]);
      expect(stamps.segments.single.start, _ms * 120);
      expect(stamps.segments.single.end, _ms * 7600);
      expect(stamps.words, hasLength(12));
    });

    test('segments anchor when their punctuation and case differ', () {
      final stamps = chunkTimestamps({
        'text': _text,
        'segments': [
          {'start': 0.1, 'end': 2.4, 'text': ' cześć anna dzwonię w sprawie'},
          {'start': 2.9, 'end': 7.6, 'text': ' czy o 5 pasuje, daj znać.'},
        ],
      }, _text)!;
      expect(_spans(_text, stamps.segments), [
        'Cześć Anna, dzwonię w sprawie jutra.',
        'Czy o 5 pasuje? Daj znać',
      ]);
      expect(stamps.words, isEmpty);
    });

    test('a skipped word moves on to the start of a word only', () {
      const text = 'Ania i ja';
      final stamps = chunkTimestamps({
        'text': text,
        'segments': [
          {'start': 0, 'end': 2.0, 'text': text},
        ],
        // The word list leaves out "Ania": "i" is the separate word, not the
        // letter inside "Ania".
        'words': [
          {'word': 'i', 'start': 1.0, 'end': 1.2},
          {'word': 'ja', 'start': 1.3, 'end': 2.0},
        ],
      }, text)!;
      expect([for (final w in stamps.words) w.textStart], [5, 7]);
    });

    test('a word that is not in the text drops all words', () {
      final answer = _grokAnswer();
      (answer['words']! as List)[4] = {
        'word': 'sprawy',
        'start': 1.5,
        'end': 1.9,
      };
      final stamps = chunkTimestamps(answer, _text)!;
      expect(stamps.segments, hasLength(1));
      expect(stamps.words, isEmpty);
    });
  });

  group('config', () {
    late Directory directory;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('worker-config-');
    });
    tearDown(() => directory.delete(recursive: true));

    WorkerConfig read(Map<String, Object?> extra) {
      final file = File('${directory.path}/config.json')
        ..writeAsStringSync(
          jsonEncode({
            'stateDirectory': '/var/lib/personal-worker',
            'temporaryDirectory': '/run/personal-worker/audio',
            'credentialsPath': '/run/personal-worker/credentials.json',
            ...extra,
          }),
        );
      return WorkerConfig.read(file.path);
    }

    test(
      'defaults to GPT through OpenRouter without an implicit second call',
      () {
        expect(
          read({}).transcriptionModel,
          TranscriptionModel.openRouterGptTranscribe,
        );
        expect(read({}).transcriptionTimingModel, isNull);
        expect(read({}).autoTranscriptionReels, isFalse);
        expect(
          read({'transcriptionProvider': 'openrouter'}).transcriptionModel,
          TranscriptionModel.openRouterGptTranscribe,
        );
        expect(
          TranscriptionModel.grokStt.pricePerMinute,
          closeTo(0.10 / 60, 1e-12),
        );
        expect(TranscriptionModel.grokStt.timestamps, isTrue);
      },
    );

    test('rollback to OpenAI is a config change', () {
      expect(
        read({'transcriptionProvider': 'openai'}).transcriptionModel,
        TranscriptionModel.gptTranscribe,
      );
      expect(
        read({'transcriptionModel': 'gpt-transcribe'}).transcriptionModel,
        TranscriptionModel.gptTranscribe,
      );
      expect(
        read({
          'transcriptionProvider': 'openai',
          'transcriptionModel': 'whisper-1',
        }).transcriptionModel,
        TranscriptionModel.whisper1,
      );
    });

    test('refuses unknown providers and models of another provider', () {
      for (final (extra, code) in [
        ({'transcriptionProvider': 'groq'}, 'invalid_transcription_provider'),
        ({'transcriptionProvider': 7}, 'invalid_transcription_provider'),
        (
          {
            'transcriptionProvider': 'openrouter',
            'transcriptionModel': 'gpt-transcribe',
          },
          'invalid_transcription_model',
        ),
        (
          {
            'transcriptionProvider': 'openai',
            'transcriptionModel': 'x-ai/grok-stt-1.0',
          },
          'invalid_transcription_model',
        ),
        (
          {'transcriptionModel': 'openai/whisper-1'},
          'invalid_transcription_model',
        ),
      ]) {
        expect(
          () => read(extra),
          throwsA(isA<WorkerFailure>().having((e) => e.code, 'code', code)),
          reason: '$extra',
        );
      }
    });

    test(
      'the deployment example selects GPT and Scribe through OpenRouter',
      () {
        final config = WorkerConfig.read('config.example.json');
        expect(
          config.transcriptionModel,
          TranscriptionModel.openRouterGptTranscribe,
        );
        expect(config.transcriptionTimingModel, TranscriptionModel.scribeV2);
        expect(config.autoTranscriptionReels, isFalse);
      },
    );

    test('timing model is explicit and refuses unsupported provider pairs', () {
      final config = read({
        'transcriptionModel': 'openai/gpt-transcribe',
        'transcriptionTimingModel': 'elevenlabs/scribe-v2',
        'autoTranscriptionReels': true,
      });
      expect(config.transcriptionTimingModel, TranscriptionModel.scribeV2);
      expect(config.autoTranscriptionReels, isTrue);
      for (final extra in <Map<String, Object?>>[
        {'transcriptionTimingModel': 7},
        {'transcriptionTimingModel': 'unknown'},
        {
          'transcriptionModel': 'gpt-transcribe',
          'transcriptionTimingModel': 'elevenlabs/scribe-v2',
        },
        {
          'transcriptionModel': 'x-ai/grok-stt-1.0',
          'transcriptionTimingModel': 'elevenlabs/scribe-v2',
        },
      ]) {
        expect(
          () => read(extra),
          throwsA(
            isA<WorkerFailure>().having(
              (e) => e.code,
              'code',
              'invalid_transcription_timing_model',
            ),
          ),
        );
      }
    });
  });

  group('OpenRouter key', () {
    late Directory directory;
    late File credentials;
    late File keyFile;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('worker-key-');
      credentials = File('${directory.path}/credentials.json');
      keyFile = File('${directory.path}/$openRouterKeyFile');
    });
    tearDown(() => directory.delete(recursive: true));

    WorkerConfig config(TranscriptionModel model) => WorkerConfig(
      stateDirectory: directory.path,
      temporaryDirectory: directory.path,
      credentialsPath: credentials.path,
      journalRoomId: '',
      trustedDeviceIds: const [],
      nativeLibraryDirectory: directory.path,
      transcriptionModel: model,
    );

    void chmod(File file, String mode) =>
        expect(Process.runSync('chmod', [mode, file.path]).exitCode, 0);

    test('the systemd credential next to the credentials JSON wins', () {
      keyFile.writeAsStringSync('sk-or-v1-synthetic-file\n');
      chmod(keyFile, '0600');
      expect(
        transcriptionApiKey(config(TranscriptionModel.grokStt), {
          'openrouterApiKey': 'sk-or-v1-synthetic-json',
        }),
        'sk-or-v1-synthetic-file',
      );
    });

    test('without the file the credentials JSON field is used', () {
      expect(
        transcriptionApiKey(config(TranscriptionModel.grokStt), {
          'openrouterApiKey': 'sk-or-v1-synthetic-json',
          'openaiApiKey': 'sk-synthetic-openai',
        }),
        'sk-or-v1-synthetic-json',
      );
      expect(transcriptionApiKey(config(TranscriptionModel.grokStt), {}), '');
    });

    test('OpenAI keeps its own key and ignores the OpenRouter file', () {
      keyFile.writeAsStringSync('sk-or-v1-synthetic-file');
      chmod(keyFile, '0600');
      expect(
        transcriptionApiKey(config(TranscriptionModel.gptTranscribe), {
          'openaiApiKey': 'sk-synthetic-openai',
        }),
        'sk-synthetic-openai',
      );
    });

    test('a readable, linked or malformed key file refuses to start', () {
      final model = config(TranscriptionModel.grokStt);
      keyFile.writeAsStringSync('sk-or-v1-synthetic');
      chmod(keyFile, '0640');
      expect(
        () => transcriptionApiKey(model, {}),
        throwsA(
          isA<WorkerFailure>().having(
            (e) => e.code,
            'code',
            'credentials_permissions',
          ),
        ),
      );
      chmod(keyFile, '0600');
      keyFile.writeAsStringSync('sk-or-v1 synthetic');
      expect(
        () => transcriptionApiKey(model, {}),
        throwsA(
          isA<WorkerFailure>().having(
            (e) => e.code,
            'code',
            'invalid_openrouter_key',
          ),
        ),
      );
      keyFile.deleteSync();
      final target = File('${directory.path}/target')
        ..writeAsStringSync('sk-or-v1-synthetic');
      chmod(target, '0600');
      Link(keyFile.path).createSync(target.path);
      expect(
        () => transcriptionApiKey(model, {}),
        throwsA(
          isA<WorkerFailure>().having(
            (e) => e.code,
            'code',
            'credentials_permissions',
          ),
        ),
      );
    });
  });

  group('SpeechTranscriber through OpenRouter', () {
    final ffmpeg = Platform.environment['FFMPEG_PATH'] ?? 'ffmpeg';
    setUpAll(() {
      expect(
        Process.runSync(ffmpeg, ['-version']).exitCode,
        0,
        reason:
            'Run scripts/setup-media-runtime.sh and configure FFMPEG_PATH; media tests must not silently skip.',
      );
    });

    late Directory directory;
    late List<http.Request> requests;
    late List<Duration> sleeps;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('worker-openrouter-');
      requests = [];
      sleeps = [];
    });
    tearDown(() => directory.delete(recursive: true));

    SpeechTranscriber service(
      List<http.Response> answers, {
      String key = 'sk-or-v1-synthetic',
    }) => SpeechTranscriber(
      key,
      temporaryRoot: directory.path,
      model: TranscriptionModel.grokStt,
      sleep: (wait) async => sleeps.add(wait),
      clientFactory: () => MockClient((request) async {
        requests.add(request);
        return answers.removeAt(0);
      }),
    );

    http.Response ok([Map<String, Object?>? answer]) => http.Response.bytes(
      utf8.encode(jsonEncode(answer ?? _grokAnswer())),
      200,
      headers: {'content-type': 'application/json'},
    );

    Future<TranscriptionResult> run(
      SpeechTranscriber transcriber, {
      String? language = 'pl',
      void Function(double, double)? estimate,
    }) => transcriber.transcribe(
      AudioSource(syntheticWav(seconds: 6), 'audio/wav'),
      language,
      Cancellation(),
      estimate ?? (_, _) {},
    );

    test('one JSON request: base64 MP3, language, timestamps, no data '
        'collection; the answer keeps its word times', () async {
      double? cost;
      final result = await run(
        service([ok()]),
        estimate: (_, estimate) => cost = estimate,
      );
      final request = requests.single;
      expect(
        request.url.toString(),
        'https://openrouter.ai/api/v1/audio/transcriptions',
      );
      expect(request.method, 'POST');
      expect(request.headers['Authorization'], 'Bearer sk-or-v1-synthetic');
      expect(request.headers['Content-Type'], startsWith('application/json'));
      final body = jsonDecode(request.body) as Map<String, Object?>;
      expect(body.keys.toSet(), {
        'model',
        'input_audio',
        'language',
        'response_format',
        'timestamp_granularities',
        'provider',
      });
      expect(body['model'], 'x-ai/grok-stt-1.0');
      expect(body['language'], 'pl');
      expect(body['response_format'], 'verbose_json');
      expect(body['timestamp_granularities'], ['segment', 'word']);
      expect(body['provider'], {'data_collection': 'deny'});
      final audio = body['input_audio']! as Map<String, Object?>;
      expect(audio['format'], 'mp3');
      final mp3 = base64Decode(audio['data']! as String);
      expect(mp3.length, inInclusiveRange(1, transcriptionMaxBytes));
      final mpegFrame = mp3[0] == 0xff && mp3[1] & 0xe0 == 0xe0;
      expect(mpegFrame || ascii.decode(mp3.sublist(0, 3)) == 'ID3', isTrue);
      expect(cost, closeTo(6 * 0.10 / 3600, 1e-9));
      expect(result.estimatedCostUsd, closeTo(6 * 0.10 / 3600, 1e-9));
      expect(result.text, _text);
      final timing = TranscriptTiming.tryParse(result.timing, result.text)!;
      expect(timing.approximate, isFalse);
      expect([for (final line in timing.lines) line.words.length], [6, 4, 2]);
      expect(await directory.list().toList(), isEmpty);
    });

    test('automatic language detection sends no language', () async {
      await run(service([ok()]), language: null);
      final body = jsonDecode(requests.single.body) as Map<String, Object?>;
      expect(body.containsKey('language'), isFalse);
    });

    test('an answer with unusable timestamps still yields the text', () async {
      final result = await run(
        service([
          ok({
            'text': _text,
            'segments': 'none',
            'words': [
              {'word': 'Cześć', 'start': 'soon', 'end': 1},
            ],
          }),
        ]),
      );
      expect(result.text, _text);
      expect(result.timing, isNull);
    });

    test('429, 502 and 503 are retried with backoff and Retry-After', () async {
      final result = await run(
        service([
          http.Response('{}', 429, headers: {'retry-after': '4'}),
          http.Response('{}', 502),
          ok(),
        ]),
      );
      expect(result.text, _text);
      expect(requests, hasLength(3));
      expect(sleeps, [const Duration(seconds: 4), const Duration(seconds: 2)]);
    });

    test('persistent overload stops after the attempt limit', () async {
      await expectLater(
        run(service([for (var i = 0; i < 4; i++) http.Response('{}', 503)])),
        throwsA(
          isA<WorkerFailure>().having(
            (e) => e.code,
            'code',
            'openai_unavailable',
          ),
        ),
      );
      expect(requests, hasLength(transcriptionProviderAttempts));
    });

    for (final status in [408, 500, 504]) {
      test(
        '$status may follow a billed request: paid-unknown, no retry',
        () async {
          await expectLater(
            run(service([http.Response('{}', status)])),
            throwsA(isA<PaidRequestUnknown>()),
          );
          expect(requests, hasLength(1));
          expect(await directory.list().toList(), isEmpty);
        },
      );
    }

    for (final (status, code) in [
      (400, 'openai_rejected'),
      (401, 'openai_auth_failed'),
      (402, 'openai_payment_required'),
      (403, 'openai_rejected'),
      (404, 'openai_rejected'),
    ]) {
      test('$status is final ($code), never retried', () async {
        await expectLater(
          run(service([http.Response('{}', status)])),
          throwsA(isA<WorkerFailure>().having((e) => e.code, 'code', code)),
        );
        expect(requests, hasLength(1));
      });
    }

    test('a missing key stops before any upload', () async {
      await expectLater(
        run(service([], key: '')),
        throwsA(
          isA<WorkerFailure>().having(
            (e) => e.code,
            'code',
            'openai_key_missing',
          ),
        ),
      );
      expect(requests, isEmpty);
    });

    test('transcribe-check prints counts only', () async {
      final output = await checkTranscription(
        Stream.value(syntheticWav(seconds: 6)),
        service([ok()]),
        language: 'pl',
      );
      expect(output, isNot(contains('Cześć')));
      final value = jsonDecode(output) as Map<String, Object?>;
      expect(value['status'], 'done');
      expect(value['provider'], 'openrouter');
      expect(value['model'], 'x-ai/grok-stt-1.0');
      expect(value['language'], 'pl');
      expect(value['transcriptCharacters'], _text.length);
      expect(value['timedSegments'], 1);
      expect(value['timedWords'], 12);
      expect(
        (jsonDecode(requests.single.body) as Map<String, Object?>)['language'],
        'pl',
      );
    });
  });
}

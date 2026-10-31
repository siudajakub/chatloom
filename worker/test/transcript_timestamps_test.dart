// SPDX-License-Identifier: AGPL-3.0-or-later
// Segment and word timestamps from the same single provider request
// (whisper-1 verbose_json), aligned to the transcript text and stored in the
// compact record the apps read. Synthetic provider answers only: nothing here
// reaches OpenAI or costs anything.
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/config.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/transcriber.dart';
import 'package:personal_worker/src/transcript_timestamps.dart';
import 'package:test/test.dart';

import 'transcriber_test.dart' show syntheticWav;

/// A verbose_json answer shaped like whisper-1's (segment texts start with a
/// space, words carry no punctuation).
Map<String, Object?> _answer({
  double duration = 6.2,
  bool words = true,
  String text = 'Hello Anna. How are you today? I am fine.',
}) => {
  'task': 'transcribe',
  'language': 'english',
  'duration': duration,
  'text': text,
  'segments': [
    {'id': 0, 'start': 0.32, 'end': 1.5, 'text': ' Hello Anna.'},
    {'id': 1, 'start': 2.0, 'end': 4.1, 'text': ' How are you today?'},
    {'id': 2, 'start': 4.4, 'end': 6.0, 'text': ' I am fine.'},
  ],
  if (words)
    'words': [
      for (final (word, start, end) in [
        ('Hello', .32, .7),
        ('Anna', .8, 1.5),
        ('How', 2.0, 2.3),
        ('are', 2.3, 2.5),
        ('you', 2.5, 2.8),
        ('today', 2.9, 4.1),
        ('I', 4.4, 4.6),
        ('am', 4.6, 4.9),
        ('fine', 5.0, 6.0),
      ])
        {'word': word, 'start': start, 'end': end},
    ],
};

void main() {
  const text = 'Hello Anna. How are you today? I am fine.';
  const ms = Duration(milliseconds: 1);

  group('chunkTimestamps', () {
    test('anchors segments in the text and covers all of it', () {
      final stamps = chunkTimestamps(_answer(), text)!;
      expect(
        [
          for (final s in stamps.segments)
            text.substring(s.textStart, s.textEnd),
        ],
        ['Hello Anna.', 'How are you today?', 'I am fine.'],
      );
      expect(stamps.segments.first.start, ms * 320);
      expect(stamps.segments.last.end, ms * 6000);
      expect(stamps.words, hasLength(9));
      expect(
        text.substring(stamps.words[5].textStart, stamps.words[5].textEnd),
        'today',
      );
      expect(stamps.duration, ms * 6200);
    });

    test('keeps segments when the words do not line up', () {
      final answer = _answer();
      (answer['words']! as List)[3] = {
        'word': 'were',
        'start': 2.3,
        'end': 2.5,
      };
      final stamps = chunkTimestamps(answer, text)!;
      expect(stamps.segments, hasLength(3));
      expect(stamps.words, isEmpty);
    });

    test('gives up on segments that are not in the text or malformed', () {
      expect(chunkTimestamps(_answer(), 'Completely different words.'), isNull);
      expect(chunkTimestamps({'text': text}, text), isNull);
      expect(
        chunkTimestamps({
          'segments': [
            {'start': 'soon', 'end': 1, 'text': 'Hello'},
          ],
        }, text),
        isNull,
      );
    });
  });

  group('transcriptTimingRecord', () {
    test('the apps read exact lines and words from it', () {
      final record = transcriptTimingRecord(
        [text],
        [chunkTimestamps(_answer(), text)],
      )!;
      final timing = TranscriptTiming.tryParse(record, text)!;
      expect(timing.approximate, isFalse);
      expect(
        [for (final line in timing.lines) line.text],
        ['Hello Anna.', 'How are you today?', 'I am fine.'],
      );
      expect(timing.lines[1].start, ms * 2000);
      expect(timing.lines[1].words, hasLength(4));
      expect(timing.indexAt(ms * 4500), 2);
    });

    test('shifts later chunks by the earlier chunks time and text', () {
      const second = 'Second part here.';
      final record = transcriptTimingRecord(
        [text, second],
        [
          chunkTimestamps(_answer(duration: 900.04), text),
          chunkTimestamps({
            'duration': 3.0,
            'text': second,
            'segments': [
              {'start': 0.5, 'end': 2.5, 'text': ' Second part here.'},
            ],
            'words': [
              {'word': 'Second', 'start': 0.5, 'end': 1.0},
              {'word': 'part', 'start': 1.1, 'end': 1.5},
              {'word': 'here', 'start': 1.6, 'end': 2.5},
            ],
          }, second),
        ],
      )!;
      const whole = '$text\n\n$second';
      final timing = TranscriptTiming.tryParse(record, whole)!;
      expect(timing.lines.last.text, second);
      expect(timing.lines.last.start, ms * 900540);
      expect(timing.lines.last.words.first.textStart, 0);
    });

    test('a chunk without timestamps drops the record', () {
      expect(
        transcriptTimingRecord(
          [text, 'More.'],
          [chunkTimestamps(_answer(), text), null],
        ),
        isNull,
      );
    });

    test('stays within the budget, words first', () {
      final record = transcriptTimingRecord(
        [text],
        [chunkTimestamps(_answer(), text)],
        budget: 60,
      )!;
      expect(record.containsKey('words'), isFalse);
      expect(utf8.encode(jsonEncode(record)).length, lessThanOrEqualTo(60));
    });
  });

  group('config', () {
    test('defaults to gpt-transcribe and accepts whisper-1 only', () async {
      final directory = await Directory.systemTemp.createTemp('worker-config-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/config.json');
      Map<String, Object?> config([Object? model]) => {
        'stateDirectory': '/var/lib/personal-worker',
        'temporaryDirectory': '/run/personal-worker/audio',
        'credentialsPath': '/run/personal-worker/credentials.json',
        'transcriptionModel': ?model,
      };
      file.writeAsStringSync(jsonEncode(config()));
      expect(
        WorkerConfig.read(file.path).transcriptionModel,
        TranscriptionModel.gptTranscribe,
      );
      file.writeAsStringSync(jsonEncode(config('whisper-1')));
      expect(
        WorkerConfig.read(file.path).transcriptionModel,
        TranscriptionModel.whisper1,
      );
      for (final wrong in ['gpt-4o-transcribe', 7]) {
        file.writeAsStringSync(jsonEncode(config(wrong)));
        expect(
          () => WorkerConfig.read(file.path),
          throwsA(isA<WorkerFailure>()),
        );
      }
    });
  });

  group('OpenAiTranscriber', () {
    final ffmpeg = Platform.environment['FFMPEG_PATH'] ?? 'ffmpeg';
    setUpAll(() {
      expect(
        Process.runSync(ffmpeg, ['-version']).exitCode,
        0,
        reason:
            'Run scripts/setup-media-runtime.sh and configure FFMPEG_PATH; media tests must not silently skip.',
      );
    });

    Future<(TranscriptionResult, List<String>, double?)> run(
      TranscriptionModel model,
      Map<String, Object?> answer, {
      String? language,
    }) async {
      final directory = await Directory.systemTemp.createTemp('worker-ts-');
      addTearDown(() => directory.delete(recursive: true));
      final bodies = <String>[];
      double? estimate;
      final service = OpenAiTranscriber(
        'synthetic-key',
        temporaryRoot: directory.path,
        model: model,
        clientFactory: () => MockClient((request) async {
          bodies.add(latin1.decode(request.bodyBytes));
          return http.Response(jsonEncode(answer), 200);
        }),
      );
      final result = await service.transcribe(
        AudioSource(syntheticWav(seconds: 6), 'audio/wav'),
        language,
        Cancellation(),
        (_, cost) => estimate = cost,
      );
      return (result, bodies, estimate);
    }

    /// Values of the multipart form field [name] in [body].
    List<String> field(String body, String name) => [
      for (final match in RegExp(
        'name="${RegExp.escape(name)}"[^\\r]*\\r\\n(?:[^\\r]+\\r\\n)*\\r\\n([^\\r]*)\\r\\n',
      ).allMatches(body))
        match.group(1)!,
    ];

    test(
      'whisper-1 asks once for segments and words and stores them',
      () async {
        final (result, bodies, estimate) = await run(
          TranscriptionModel.whisper1,
          _answer(),
          language: 'en',
        );
        expect(bodies, hasLength(1));
        final body = bodies.single;
        expect(field(body, 'model'), ['whisper-1']);
        expect(field(body, 'response_format'), ['verbose_json']);
        expect(field(body, 'timestamp_granularities[]'), ['segment', 'word']);
        expect(field(body, 'language'), ['en']);
        expect(field(body, 'languages[]'), isEmpty);
        expect(estimate, closeTo(6 * 0.006 / 60, 0.000001));
        expect(result.text, text);
        final timing = TranscriptTiming.tryParse(result.timing, result.text)!;
        expect(timing.approximate, isFalse);
        expect(timing.lines.first.words, isNotEmpty);
      },
    );

    test('a whisper answer without timestamps still yields the text', () async {
      final (result, _, _) = await run(TranscriptionModel.whisper1, {
        'text': text,
      });
      expect(result.text, text);
      expect(result.timing, isNull);
    });

    test('gpt-transcribe keeps its plain request and stores none', () async {
      final (result, bodies, estimate) = await run(
        TranscriptionModel.gptTranscribe,
        _answer(),
        language: 'pl',
      );
      final body = bodies.single;
      expect(field(body, 'model'), ['gpt-transcribe']);
      expect(field(body, 'response_format'), ['json']);
      expect(field(body, 'timestamp_granularities[]'), isEmpty);
      expect(field(body, 'languages[]'), ['pl']);
      expect(estimate, closeTo(6 * transcriptionPricePerMinute / 60, 0.000001));
      expect(result.timing, isNull);
    });
  });
}

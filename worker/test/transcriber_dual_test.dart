// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/transcriber.dart';
import 'package:personal_worker/src/transcript_timestamps.dart';
import 'package:test/test.dart';

import 'transcriber_test.dart' show syntheticWav;

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('worker-dual-test-');
  });
  tearDown(() => directory.delete(recursive: true));

  SpeechTranscriber service(
    Future<http.Response> Function(http.Request) handler,
  ) => SpeechTranscriber(
    'synthetic-openrouter-key',
    temporaryRoot: directory.path,
    model: TranscriptionModel.openRouterGptTranscribe,
    timingModel: TranscriptionModel.scribeV2,
    clientFactory: () => MockClient(handler),
  );

  test(
    'both passes use OpenRouter key, GPT owns text and estimate covers both',
    () async {
      final models = <String>[];
      double? estimated;
      final result =
          await service((request) async {
            expect(
              request.headers['Authorization'],
              'Bearer synthetic-openrouter-key',
            );
            expect(request.url.host, 'openrouter.ai');
            final body = jsonDecode(request.body) as Map;
            models.add(body['model'] as String);
            expect(body['language'], 'en');
            expect(body['provider'], {'data_collection': 'deny'});
            if (models.length == 1) {
              expect(body['response_format'], 'json');
              return http.Response('{"text":"Hello, WORLD!"}', 200);
            }
            expect(body['response_format'], 'verbose_json');
            return http.Response(
              jsonEncode({
                'text': 'hello world',
                'duration': 9999,
                'words': [
                  {'word': 'hello', 'start': 0.1, 'end': 0.3},
                  {'word': 'world', 'start': 0.4, 'end': 0.8},
                ],
              }),
              200,
            );
          }).transcribe(
            AudioSource(syntheticWav(), 'audio/wav'),
            'en',
            Cancellation(),
            (_, cost) => estimated = cost,
          );
      expect(models, ['openai/gpt-transcribe', 'elevenlabs/scribe-v2']);
      expect(result.text, 'Hello, WORLD!');
      expect(result.timing?['words'], isNotNull);
      expect(
        estimated,
        closeTo(
          (TranscriptionModel.openRouterGptTranscribe.pricePerMinute +
                  TranscriptionModel.scribeV2.pricePerMinute) /
              60,
          0.000001,
        ),
      );
      expect(result.estimatedCostUsd, estimated);
      expect(await directory.list().toList(), isEmpty);
    },
  );

  for (final failure in [
    'auth',
    'rate_limit',
    'timeout',
    'malformed',
    'backwards',
    'bounds',
  ]) {
    test('secondary $failure preserves paid primary with no retries', () async {
      var calls = 0;
      final result =
          await service((request) async {
            calls++;
            if (calls == 1) {
              return http.Response('{"text":"Authoritative text"}', 200);
            }
            return switch (failure) {
              'auth' => http.Response('{}', 401),
              'rate_limit' => http.Response('{}', 429),
              'timeout' => throw TimeoutException('synthetic'),
              'backwards' => http.Response(
                '{"text":"Authoritative text","words":[{"word":"Authoritative","start":0.5,"end":0.1}]}',
                200,
              ),
              'bounds' => http.Response(
                '{"text":"Authoritative text","words":[{"word":"Authoritative","start":0,"end":100}]}',
                200,
              ),
              _ => http.Response('malformed', 200),
            };
          }).transcribe(
            AudioSource(syntheticWav(), 'audio/wav'),
            'en',
            Cancellation(),
            (_, _) {},
          );
      expect(result.text, 'Authoritative text');
      expect(result.timing, isNull);
      expect(calls, 2);
      expect(await directory.list().toList(), isEmpty);
    });
  }
  test('secondary cancellation still aborts and cleans plaintext', () async {
    var calls = 0;
    final cancellation = Cancellation();
    await expectLater(
      service((request) async {
        calls++;
        if (calls == 1) {
          return http.Response('{"text":"Authoritative text"}', 200);
        }
        cancellation.cancel();
        throw const SocketException('cancelled fixture');
      }).transcribe(
        AudioSource(syntheticWav(), 'audio/wav'),
        'en',
        cancellation,
        (_, _) {},
      ),
      throwsA(isA<WorkerFailure>().having((e) => e.code, 'code', 'cancelled')),
    );
    expect(calls, 2);
    expect(await directory.list().toList(), isEmpty);
  });
  test(
    'checkpoint precedes timing, and checkpoint failure sends no timing',
    () async {
      var calls = 0;
      await expectLater(
        service((request) async {
          calls++;
          return http.Response('{"text":"Paid primary"}', 200);
        }).transcribeStaged(
          AudioSource(syntheticWav(), 'audio/wav'),
          'en',
          Cancellation(),
          (_, _) {},
          (primary) async {
            expect(calls, 1);
            expect(primary.text, 'Paid primary');
            expect(primary.timing, isNull);
            throw const WorkerFailure('checkpoint_failed');
          },
        ),
        throwsA(
          isA<WorkerFailure>().having(
            (e) => e.code,
            'code',
            'checkpoint_failed',
          ),
        ),
      );
      expect(calls, 1);
    },
  );
  test(
    'all primary chunks complete first and offsets use local audio durations',
    () async {
      final models = <String>[];
      var checkpointed = false;
      final result =
          await service((request) async {
            final model = (jsonDecode(request.body) as Map)['model'] as String;
            models.add(model);
            final text = models.length.isOdd ? 'First chunk' : 'Second chunk';
            if (model == TranscriptionModel.openRouterGptTranscribe.name) {
              expect(checkpointed, isFalse);
              return http.Response(jsonEncode({'text': text}), 200);
            }
            expect(checkpointed, isTrue);
            return http.Response(
              jsonEncode({
                'text': text,
                'duration': 9999,
                'words': [
                  {'word': text.split(' ').first, 'start': 0.1, 'end': 0.3},
                  {'word': 'chunk', 'start': 0.4, 'end': 0.8},
                ],
              }),
              200,
            );
          }).transcribeStaged(
            AudioSource(syntheticWav(seconds: 901), 'audio/wav'),
            'en',
            Cancellation(),
            (_, _) {},
            (primary) async {
              expect(primary.text, 'First chunk\n\nSecond chunk');
              expect(models.length, 2);
              checkpointed = true;
            },
          );
      expect(models, [
        'openai/gpt-transcribe',
        'openai/gpt-transcribe',
        'elevenlabs/scribe-v2',
        'elevenlabs/scribe-v2',
      ]);
      final parsed = TranscriptTiming.tryParse(result.timing, result.text)!;
      expect(
        parsed.lines.last.start.inMilliseconds,
        inInclusiveRange(900000, 900200),
      );
      expect(parsed.lines.last.words.length, 2);
    },
  );
}

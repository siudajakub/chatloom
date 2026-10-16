// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/transcription_check.dart';
import 'package:test/test.dart';

class ProbeTranscriber implements Transcriber {
  int calls = 0;
  @override
  Future<TranscriptionResult> transcribe(
    AudioSource audio,
    String? language,
    Cancellation cancel,
    void Function(double, double) estimate,
  ) async {
    calls++;
    expect(audio.bytes, [1, 2, 3]);
    return const TranscriptionResult('PRIVATE_TRANSCRIPT', 3, 0.000225);
  }
}

void main() {
  test(
    'stdin chunks become one upload and stdout contains no transcript',
    () async {
      final transcriber = ProbeTranscriber();
      final output = await checkTranscription(
        Stream.fromIterable([
          [1],
          [2, 3],
        ]),
        transcriber,
      );
      expect(transcriber.calls, 1);
      expect(output, isNot(contains('PRIVATE_TRANSCRIPT')));
      expect(jsonDecode(output), {
        'status': 'done',
        'model': 'gpt-transcribe',
        'durationSeconds': 3.0,
        'estimatedCostUsd': 0.000225,
        'transcriptCharacters': 18,
      });
    },
  );
  test('empty or oversized stdin stops before a paid request', () async {
    for (final input in [
      <List<int>>[],
      [
        [1, 2, 3, 4],
      ],
    ]) {
      final transcriber = ProbeTranscriber();
      await expectLater(
        checkTranscription(
          Stream.fromIterable(input),
          transcriber,
          maximumInputBytes: 3,
        ),
        throwsA(isA<WorkerFailure>()),
      );
      expect(transcriber.calls, 0);
    }
  });
}

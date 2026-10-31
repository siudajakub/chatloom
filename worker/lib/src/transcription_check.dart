// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';
import 'ports.dart';
import 'transcriber.dart';

/// Explicit, paid stdin probe of the deployed transcription pipeline. It never
/// opens a Matrix session, changes jobs, or publishes the returned transcript.
Future<String> checkTranscription(
  Stream<List<int>> input,
  Transcriber transcriber, {
  int maximumInputBytes = 64 * 1024 * 1024,
}) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in input) {
    if (bytes.length + chunk.length > maximumInputBytes) {
      throw const WorkerFailure('audio_check_input_too_large');
    }
    bytes.add(chunk);
  }
  if (bytes.isEmpty) throw const WorkerFailure('empty_audio');
  final result = await transcriber.transcribe(
    AudioSource(bytes.takeBytes(), 'application/octet-stream'),
    null,
    Cancellation(),
    (_, _) {},
  );
  final timing = result.timing;
  return jsonEncode({
    'status': 'done',
    'model': transcriber is OpenAiTranscriber
        ? transcriber.model.name
        : transcriptionModel,
    'durationSeconds': result.durationSeconds,
    'estimatedCostUsd': result.estimatedCostUsd,
    'transcriptCharacters': result.text.length,
    // Counts only: whether the model's timestamps arrived and fit.
    if (timing != null) ...{
      'timedSegments': ((timing['segments'] as List?)?.length ?? 0) ~/ 4,
      'timedWords': ((timing['words'] as List?)?.length ?? 0) ~/ 4,
    },
  });
}

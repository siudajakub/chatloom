// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Runs the worker's timestamp anchoring on saved speech-to-text answers of
// compare.py: would the worker keep each provider's segment and word times?
//
//   dart --packages=worker/.dart_tool/package_config.json \
//     scripts/stt-compare/anchor_check.dart RESULT.json...
//
// Prints one JSON line of counts per answer; never the transcript text.
import 'dart:convert';
import 'dart:io';

import 'package:personal_worker/src/transcript_timestamps.dart';

void main(List<String> paths) {
  final rows = <Map<String, Object?>>[];
  for (final path in paths) {
    final row = <String, Object?>{};
    rows.add(row);
    try {
      final record = jsonDecode(File(path).readAsStringSync());
      if (record is! Map) throw const FormatException('not an object');
      row['model'] = record['model'];
      row['sample'] = record['sample'];
      final answer = record['response'];
      if (answer is! Map) throw const FormatException('no response');
      final rawText = answer['text'];
      final text = rawText is String ? rawText.trim() : '';
      final segments = answer['segments'], words = answer['words'];
      row['raw_segments'] = segments is List ? segments.length : 0;
      row['raw_words'] = words is List ? words.length : 0;
      if (text.isEmpty) {
        row['note'] = 'empty text';
        continue;
      }
      // Exactly the worker's call (OpenAiTranscriber._uploadOnce).
      final stamps = chunkTimestamps(answer.cast<Object?, Object?>(), text);
      row['segments'] = stamps?.segments.length ?? 0;
      row['words'] = stamps?.words.length ?? 0;
      final timing = stamps == null
          ? null
          : transcriptTimingRecord([text], [stamps]);
      row['timing'] = timing != null;
      row['timing_bytes'] = timing == null ? 0 : jsonEncode(timing).length;
      if (stamps == null) {
        row['note'] = segments is List && segments.isNotEmpty
            ? 'segments could not be anchored in the text'
            : 'no top-level segments: worker keeps no timing';
      } else if (row['raw_words'] == 0 &&
          segments is List &&
          segments.any((s) => s is Map && s['words'] is List)) {
        row['note'] = 'words only inside segments[].words: worker drops them';
      } else if (row['raw_words'] != 0 && stamps.words.isEmpty) {
        row['note'] = 'words present but dropped (not found in order in text)';
      } else if (timing == null) {
        row['note'] = 'timing record over budget';
      }
    } catch (e) {
      row['note'] = 'error: ${e.runtimeType}';
    }
  }
  stdout.writeln(jsonEncode(rows));
}

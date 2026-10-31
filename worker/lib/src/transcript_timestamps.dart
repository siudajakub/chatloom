// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:personal_core/personal_core.dart';

/// A provider speech model the worker can use: its price and whether the
/// single transcription request also returns segment and word timestamps.
///
/// Verified against OpenAI's documentation on 2026-10-31: `gpt-transcribe`
/// (default, USD 0.0045/min) returns text and languages only;
/// `timestamp_granularities[]` is supported only by `whisper-1` (USD
/// 0.006/min, deprecated, usable until 2027-02-26), with
/// `response_format=verbose_json`. Timestamps never cost a second request.
class TranscriptionModel {
  final String name;
  final double pricePerMinute;
  final bool timestamps;
  const TranscriptionModel._(this.name, this.pricePerMinute, this.timestamps);

  static const gptTranscribe = TranscriptionModel._(
    'gpt-transcribe',
    0.0045,
    false,
  );
  static const whisper1 = TranscriptionModel._('whisper-1', 0.006, true);
  static const all = [gptTranscribe, whisper1];

  /// The model called [name]; null for an unknown name.
  static TranscriptionModel? byName(String? name) {
    for (final model in all) {
      if (model.name == name) return model;
    }
    return null;
  }

  @override
  String toString() => name;
}

/// Timestamps of one provider answer (one audio chunk), relative to that
/// chunk's start and to its trimmed text.
class ChunkTimestamps {
  final List<TranscriptSpan> segments;
  final List<TranscriptSpan> words;

  /// Length of the chunk as the provider measured it.
  final Duration? duration;
  const ChunkTimestamps(this.segments, this.words, this.duration);
}

/// How far a word may sit after the previous one in the text (punctuation,
/// spaces) before the words are considered misaligned.
const _wordLookahead = 32;

Duration? _seconds(Object? value) =>
    value is num && value.isFinite && value >= 0
    ? Duration(microseconds: (value * Duration.microsecondsPerSecond).round())
    : null;

bool _blank(String text, int start, int end) {
  for (var i = start; i < end; i++) {
    if (text.codeUnitAt(i) > 0x20) return false;
  }
  return true;
}

int _trimEnd(String text, int start, int end) {
  while (end > start && text.codeUnitAt(end - 1) <= 0x20) {
    end--;
  }
  return end;
}

/// Segment and word timestamps of a `verbose_json` answer for [text] (the
/// answer's text, trimmed), or null when it has no usable segments or they
/// cannot be found in [text] in order. Segments are anchored where their
/// text starts and run to the next segment, so together they cover the
/// whole text even when the provider's segment texts differ in spacing.
/// Words are kept only when every word is found in order.
ChunkTimestamps? chunkTimestamps(Map<Object?, Object?> answer, String text) {
  final rawSegments = answer['segments'];
  if (rawSegments is! List || text.trim().isEmpty) return null;
  final starts = <int>[];
  final times = <(Duration, Duration)>[];
  var cursor = 0;
  for (final segment in rawSegments) {
    if (segment is! Map) return null;
    final value = segment['text'];
    final from = _seconds(segment['start']), to = _seconds(segment['end']);
    if (value is! String || from == null || to == null) return null;
    final needle = value.trim();
    if (needle.isEmpty) continue;
    var at = text.indexOf(needle, cursor);
    var length = needle.length;
    if (at < 0) {
      // Spacing or punctuation may differ: anchor on the first characters.
      final head = needle.substring(0, math.min(12, needle.length));
      at = text.indexOf(head, cursor);
      length = head.length;
    }
    if (at < 0) return null;
    final previous = times.isEmpty ? Duration.zero : times.last.$1;
    final start = from < previous ? previous : from;
    starts.add(at);
    times.add((start, to < start ? start : to));
    cursor = at + length;
  }
  if (starts.isEmpty) return null;
  final segments = <TranscriptSpan>[];
  for (var i = 0; i < starts.length; i++) {
    // The first segment kept also takes any text before it.
    final start = segments.isEmpty ? 0 : starts[i];
    final end = _trimEnd(
      text,
      start,
      i + 1 < starts.length ? starts[i + 1] : text.length,
    );
    if (end <= start || _blank(text, start, end)) {
      // Two segments found at one place: the later one absorbs it.
      if (i + 1 < starts.length) continue;
      if (segments.isEmpty) return null;
      break;
    }
    segments.add(
      TranscriptSpan(
        start: times[i].$1,
        end: times[i].$2,
        textStart: start,
        textEnd: end,
      ),
    );
  }
  if (segments.isEmpty) return null;
  return ChunkTimestamps(
    segments,
    _words(answer['words'], text),
    _seconds(answer['duration']),
  );
}

List<TranscriptSpan> _words(Object? raw, String text) {
  if (raw is! List) return const [];
  final words = <TranscriptSpan>[];
  var cursor = 0;
  var previous = Duration.zero;
  for (final word in raw) {
    if (word is! Map) return const [];
    final value = word['word'];
    final from = _seconds(word['start']), to = _seconds(word['end']);
    if (value is! String || from == null || to == null) return const [];
    final needle = value.trim();
    if (needle.isEmpty) continue;
    final at = text.indexOf(needle, cursor);
    if (at < 0 || at - cursor > _wordLookahead) return const [];
    final start = from < previous ? previous : from;
    words.add(
      TranscriptSpan(
        start: start,
        end: to < start ? start : to,
        textStart: at,
        textEnd: at + needle.length,
      ),
    );
    previous = start;
    cursor = at + needle.length;
  }
  return words;
}

/// The `timing` record of a transcript made of [texts] (trimmed chunk
/// texts) joined by [separator], from each chunk's timestamps; null when a
/// chunk has none (a partial record would hide that chunk's text) or the
/// record does not fit [TranscriptTiming.encode]'s budget. A chunk starts
/// where the previous one ended by the provider's measure, or
/// [chunkLength] (the worker's split length) without one.
Map<String, Object?>? transcriptTimingRecord(
  List<String> texts,
  List<ChunkTimestamps?> chunks, {
  String separator = '\n\n',
  Duration chunkLength = const Duration(seconds: 900),
  int budget = transcriptTimingBudget,
}) {
  if (texts.isEmpty || texts.length != chunks.length) return null;
  final segments = <TranscriptSpan>[];
  final words = <TranscriptSpan>[];
  var textOffset = 0;
  var timeOffset = Duration.zero;
  TranscriptSpan shift(TranscriptSpan span) => TranscriptSpan(
    start: span.start + timeOffset,
    end: span.end + timeOffset,
    textStart: span.textStart + textOffset,
    textEnd: span.textEnd + textOffset,
  );
  for (var i = 0; i < texts.length; i++) {
    final chunk = chunks[i];
    if (chunk == null) return null;
    segments.addAll(chunk.segments.map(shift));
    words.addAll(chunk.words.map(shift));
    textOffset += texts[i].length + separator.length;
    timeOffset += chunk.duration ?? chunkLength;
  }
  // Words of a chunk that had none would leave gaps: all or nothing.
  final complete = chunks.every((chunk) => chunk!.words.isNotEmpty);
  return TranscriptTiming.encode(
    segments: segments,
    words: complete ? words : const [],
    budget: budget,
  );
}

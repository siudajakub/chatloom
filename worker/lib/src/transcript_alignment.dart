// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:personal_core/personal_core.dart';

import 'transcript_timestamps.dart';

final _lexeme = RegExp(r"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*", unicode: true);
String _fold(String word) => word.toLowerCase().replaceAll(RegExp("['’]"), '');

/// Reject malformed secondary times before the legacy parser can clamp
/// backwards timestamps. The source text is never logged or retained here.
bool validAlignmentAnswer(Map<Object?, Object?> answer) {
  var raw = answer['words'];
  if (raw is! List || raw.isEmpty) {
    final segments = answer['segments'];
    if (segments is! List) return false;
    raw = [
      for (final segment in segments)
        if (segment is Map && segment['words'] is List)
          ...segment['words'] as List,
    ];
  }
  if (raw.isEmpty || raw.length > 6000) return false;
  var previous = 0.0;
  for (final item in raw) {
    if (item is! Map) return false;
    final start = item['start'], end = item['end'];
    if (start is! num ||
        end is! num ||
        !start.isFinite ||
        !end.isFinite ||
        start < previous ||
        end < start) {
      return false;
    }
    previous = start.toDouble();
  }
  return true;
}

/// Transfer only exact lexical matches from secondary recognition onto the
/// authoritative GPT text. This is sequence alignment, not forced alignment:
/// substitutions never receive a word time. Memory and work are bounded to
/// 6000 words and a 64-word edit band (roughly a 15-minute audio chunk).
///
/// Lines with any unmatched GPT word have no word highlights: the reader
/// holds a previous word through gaps, which would imply false precision.
/// Every line remains in the segment record, preserving all primary text.
ChunkTimestamps? alignTranscriptWords(
  String text,
  String secondaryText,
  ChunkTimestamps secondary,
  Duration duration,
) {
  final target = _lexeme.allMatches(text).toList();
  final source = secondary.words;
  if (target.isEmpty ||
      target.length > 6000 ||
      source.isEmpty ||
      source.length > 6000 ||
      duration <= Duration.zero) {
    return null;
  }
  final sourceWords = <String>[];
  var previousStart = Duration.zero;
  var previousTextEnd = 0;
  for (final word in source) {
    if (word.textStart < previousTextEnd ||
        word.textEnd > secondaryText.length ||
        word.textEnd <= word.textStart ||
        word.start < previousStart ||
        word.end < word.start ||
        word.end > duration) {
      return null;
    }
    final lexemes = _lexeme
        .allMatches(secondaryText.substring(word.textStart, word.textEnd))
        .toList();
    // A multiword token has only one interval; do not invent its word splits.
    if (lexemes.length != 1) return null;
    sourceWords.add(_fold(lexemes.single.group(0)!));
    previousStart = word.start;
    previousTextEnd = word.textEnd;
  }
  final targetWords = [for (final word in target) _fold(word.group(0)!)];
  final matches = _matches(targetWords, sourceWords);
  if (matches == null ||
      matches.length / target.length < 0.8 ||
      matches.length / source.length < 0.8) {
    return null;
  }
  final mapped = <int, TranscriptSpan>{};
  for (final (to, from) in matches) {
    mapped[to] = TranscriptSpan(
      start: source[from].start,
      end: source[from].end,
      textStart: target[to].start,
      textEnd: target[to].end,
    );
  }
  final segments = <TranscriptSpan>[];
  final words = <TranscriptSpan>[];
  var wordIndex = 0;
  for (final (start, end) in transcriptLineRanges(text)) {
    final inside = <TranscriptSpan>[];
    var complete = true;
    while (wordIndex < target.length && target[wordIndex].start < end) {
      final word = mapped[wordIndex];
      if (word == null) {
        complete = false;
      } else {
        inside.add(word);
      }
      wordIndex++;
    }
    // No reliably anchored word on a line: return a complete static
    // transcript rather than assign guessed exact segment times.
    if (inside.isEmpty) return null;
    segments.add(
      TranscriptSpan(
        start: inside.first.start,
        end: inside.last.end,
        textStart: start,
        textEnd: end,
      ),
    );
    if (complete) words.addAll(inside);
  }
  return ChunkTimestamps(segments, words, duration);
}

List<(int, int)>? _matches(List<String> target, List<String> source) {
  const band = 64, width = band * 2 + 1, infinity = 65500;
  if ((target.length - source.length).abs() > band) return null;
  final trace = Uint8List((target.length + 1) * width);
  var previous = Uint16List(width)..fillRange(0, width, infinity);
  for (var j = 0; j <= math.min(source.length, band); j++) {
    previous[j + band] = j;
    trace[j + band] = 2;
  }
  for (var i = 1; i <= target.length; i++) {
    final row = Uint16List(width)..fillRange(0, width, infinity);
    if (i <= band) row[band - i] = i;
    final low = math.max(1, i - band), high = math.min(source.length, i + band);
    for (var j = low; j <= high; j++) {
      final same = target[i - 1] == source[j - 1];
      final at = j - i + band;
      var score = previous[at] + (same ? 0 : 1);
      var direction = 0;
      if (at + 1 < width && previous[at + 1] + 1 < score) {
        score = previous[at + 1] + 1;
        direction = 1;
      }
      if (at > 0 && row[at - 1] + 1 < score) {
        score = row[at - 1] + 1;
        direction = 2;
      }
      row[at] = score;
      trace[i * width + j - i + band] = direction;
    }
    previous = row;
  }
  if (previous[source.length - target.length + band] >
      math.max(target.length, source.length) * 0.2) {
    return null;
  }
  final matches = <(int, int)>[];
  var i = target.length, j = source.length;
  while (i > 0 && j > 0) {
    final at = j - i + band;
    if (at < 0 || at >= width) return null;
    switch (trace[i * width + at]) {
      case 0:
        if (target[i - 1] == source[j - 1]) matches.add((i - 1, j - 1));
        i--;
        j--;
      case 1:
        i--;
      case 2:
        j--;
    }
  }
  return matches.reversed.toList();
}

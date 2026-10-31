// SPDX-License-Identifier: AGPL-3.0-or-later

/// Time-synced lines of a transcript, for the live view of a playing voice
/// note, round or video (Apple Music style lyrics). Pure Dart, shared with
/// the worker, so a future worker that stores timestamps writes exactly the
/// format the apps read.
///
/// Two sources:
///
/// * **exact**: the optional `timing` record of a done transcript result
///   ([TranscriptTiming.tryParse], written with [TranscriptTiming.encode]):
///   segment (and, when they fit, word) timestamps from the speech model,
///   as compact delta-encoded centisecond times plus UTF-16 offsets into the
///   transcript `text`, so the text is never duplicated. Only a worker whose
///   provider model returns timestamps writes it.
/// * **approximate** ([TranscriptTiming.approximate]): the text is split into
///   sentences and short lines, and the media duration is shared out by
///   their length. Speech rate varies and pauses are unknown, so such lines
///   drift by a few seconds; apps label them as approximate and never
///   highlight words.
library;

import 'dart:math' as math;

/// Current version of the stored `timing` record.
const transcriptTimingVersion = 1;

/// Upper bounds of a stored record; a larger one is ignored as a whole.
const transcriptTimingMaxSegments = 5000;
const transcriptTimingMaxWords = 50000;

/// Most JSON bytes of a `timing` record in one journal event. With the text
/// budget ([transcriptTextEventBudget], 24000) and the rest of a result the
/// plaintext event stays near 38 KB, below the SDK's 60000-byte limit after
/// megolm. Words go first when a record would not fit (about 10 bytes per
/// word: roughly 15 minutes of speech with words, hours with segments only).
const transcriptTimingBudget = 12000;

/// Time unit of a stored record (centiseconds).
const _unitMs = 10;

/// A timed span of a transcript: its time and its UTF-16 range in the text.
class TranscriptSpan {
  final Duration start, end;
  final int textStart, textEnd;
  const TranscriptSpan({
    required this.start,
    required this.end,
    required this.textStart,
    required this.textEnd,
  });

  @override
  bool operator ==(Object other) =>
      other is TranscriptSpan &&
      other.start == start &&
      other.end == end &&
      other.textStart == textStart &&
      other.textEnd == textEnd;

  @override
  int get hashCode => Object.hash(start, end, textStart, textEnd);

  @override
  String toString() => 'TranscriptSpan($start–$end, $textStart:$textEnd)';
}

/// A display line longer than this is split at a clause or a word boundary.
const transcriptLineMaxChars = 60;

/// A sentence shorter than this joins the next one when both fit a line.
const transcriptLineMinChars = 12;

/// One word of a [TranscriptLine]: its time and its UTF-16 range inside the
/// line's [TranscriptLine.text].
class TranscriptWord {
  final Duration start, end;
  final int textStart, textEnd;
  const TranscriptWord({
    required this.start,
    required this.end,
    required this.textStart,
    required this.textEnd,
  });

  @override
  bool operator ==(Object other) =>
      other is TranscriptWord &&
      other.start == start &&
      other.end == end &&
      other.textStart == textStart &&
      other.textEnd == textEnd;

  @override
  int get hashCode => Object.hash(start, end, textStart, textEnd);

  @override
  String toString() => 'TranscriptWord($start–$end, $textStart:$textEnd)';
}

/// One display line: shown from [start] until the next line starts.
class TranscriptLine {
  final Duration start, end;
  final String text;

  /// Timed words, in order; empty when only the line is timed.
  final List<TranscriptWord> words;
  TranscriptLine({
    required this.start,
    required this.end,
    required this.text,
    List<TranscriptWord> words = const [],
  }) : words = List.unmodifiable(words);

  /// Index of the word spoken at [position], -1 before the first word (or
  /// without words). Between words the previous one stays current.
  int wordAt(Duration position) =>
      _lastStartAtOrBefore(words.length, (i) => words[i].start, position);

  @override
  String toString() => 'TranscriptLine($start–$end, ${text.length} chars)';
}

/// The lines of one transcript with their times.
class TranscriptTiming {
  final List<TranscriptLine> lines;

  /// True when the times were estimated from the text length.
  final bool approximate;

  TranscriptTiming._(List<TranscriptLine> lines, {required this.approximate})
    : lines = List.unmodifiable(lines);

  /// Index of the line spoken at [position]: the last line that started at
  /// or before it (a line stays current through a pause after it), -1 before
  /// the first line.
  int indexAt(Duration position) =>
      _lastStartAtOrBefore(lines.length, (i) => lines[i].start, position);

  /// Estimated timing: [text] split by [transcriptLineRanges], and
  /// [duration] shared out by the number of letters per line plus a short
  /// pause per line. Lines are contiguous from zero to [duration]. Empty for
  /// blank text; zero-length lines for a non-positive duration.
  factory TranscriptTiming.approximate(
    String text,
    Duration duration, {
    int maxChars = transcriptLineMaxChars,
    int minChars = transcriptLineMinChars,
  }) {
    final ranges = transcriptLineRanges(
      text,
      maxChars: maxChars,
      minChars: minChars,
    );
    final total = duration.isNegative ? 0 : duration.inMicroseconds;
    final weights = [
      for (final (start, end) in ranges)
        _letters(text, start, end) + _pauseWeight,
    ];
    final sum = weights.fold<int>(0, (a, b) => a + b);
    final lines = <TranscriptLine>[];
    var spent = 0;
    for (var i = 0; i < ranges.length; i++) {
      final (start, end) = ranges[i];
      spent += weights[i];
      final from = lines.isEmpty ? 0 : lines.last.end.inMicroseconds;
      final to = i == ranges.length - 1 ? total : total * spent ~/ sum;
      lines.add(
        TranscriptLine(
          start: Duration(microseconds: from),
          end: Duration(microseconds: math.max(from, to)),
          text: text.substring(start, end),
        ),
      );
    }
    return TranscriptTiming._(lines, approximate: true);
  }

  /// Exact timing from a stored `timing` record of [text], or null when
  /// [json] is absent, of another version or inconsistent with [text] (the
  /// caller then falls back to [TranscriptTiming.approximate]).
  ///
  /// Record (version 1), two flat integer lists of four numbers per span:
  ///
  /// ```json
  /// {"v": 1,
  ///  "segments": [startGap, length, textGap, textLength, ...],
  ///  "words": [startGap, length, textGap, textLength, ...]}
  /// ```
  ///
  /// Times are centiseconds: `startGap` is the span's start minus the
  /// previous span's start (the first: minus zero), `length` its end minus
  /// its start. Text offsets are UTF-16 code units (Dart string indices):
  /// `textGap` is the span's first offset minus the previous span's end
  /// offset, `textLength` its length. So spans are in order and never
  /// overlap in the text, and every number is a small non-negative integer
  /// (about 10 bytes per word). Segments must cover every non-blank part of
  /// [text]; `words` is optional and is dropped as a whole when any word
  /// lies outside the segments. A segment longer than a display line is
  /// split like approximate text; its parts take their times from their
  /// words, or share the segment's time by length when there are none.
  static TranscriptTiming? tryParse(Object? json, String text) {
    if (json is! Map || json['v'] != transcriptTimingVersion) return null;
    final segments = _ranges(
      json['segments'],
      text.length,
      transcriptTimingMaxSegments,
    );
    if (segments == null || segments.isEmpty) return null;
    // Text outside every segment would never be shown.
    var covered = 0;
    for (final segment in segments) {
      if (_letters(text, covered, segment.textStart) > 0) return null;
      covered = segment.textEnd;
    }
    if (_letters(text, covered, text.length) > 0) return null;
    final words = json.containsKey('words')
        ? _ranges(json['words'], text.length, transcriptTimingMaxWords)
        : const <_Range>[];
    final perSegment = _assignWords(segments, words ?? const []);
    final lines = <TranscriptLine>[];
    for (var s = 0; s < segments.length; s++) {
      lines.addAll(
        _segmentLines(text, segments[s], perSegment?[s] ?? const []),
      );
    }
    if (lines.isEmpty) return null;
    return TranscriptTiming._(lines, approximate: false);
  }

  /// The stored record of [segments] and [words] (see [tryParse]), for the
  /// worker. Spans must be in time and text order without overlapping text
  /// (an out-of-order one returns null). [words] are left out when the
  /// record with them exceeds [budget] JSON bytes; null when even the
  /// segments alone exceed it or there are none.
  static Map<String, Object?>? encode({
    required List<TranscriptSpan> segments,
    List<TranscriptSpan> words = const [],
    int budget = transcriptTimingBudget,
  }) {
    final encodedSegments = _encodeSpans(segments);
    if (encodedSegments == null || segments.isEmpty) return null;
    final encodedWords = words.isEmpty ? null : _encodeSpans(words);
    final full = {
      'v': transcriptTimingVersion,
      'segments': encodedSegments,
      'words': ?encodedWords,
    };
    if (_jsonBytes(full) <= budget) return full;
    full.remove('words');
    return _jsonBytes(full) <= budget ? full : null;
  }

  @override
  String toString() =>
      'TranscriptTiming(${lines.length} lines, '
      '${approximate ? 'approximate' : 'exact'})';
}

/// Every line, in time order, gets this many letters of extra weight: a
/// short pause between sentences and lines.
const _pauseWeight = 3;

int _lastStartAtOrBefore(
  int length,
  Duration Function(int index) startOf,
  Duration position,
) {
  var low = 0, high = length - 1, found = -1;
  while (low <= high) {
    final middle = (low + high) >> 1;
    if (startOf(middle) <= position) {
      found = middle;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return found;
}

bool _space(int unit) =>
    unit == 0x20 ||
    unit == 0x09 ||
    unit == 0x0a ||
    unit == 0x0d ||
    unit == 0xa0 ||
    unit == 0x2028 ||
    unit == 0x2029 ||
    unit == 0x3000;

bool _newline(int unit) =>
    unit == 0x0a || unit == 0x0d || unit == 0x2028 || unit == 0x2029;

/// . ! ? … and the Armenian, CJK and Devanagari full stops.
bool _sentenceEnd(int unit) =>
    unit == 0x2e ||
    unit == 0x21 ||
    unit == 0x3f ||
    unit == 0x2026 ||
    unit == 0x0589 ||
    unit == 0x3002 ||
    unit == 0xff01 ||
    unit == 0xff1f ||
    unit == 0x0964;

/// Quotes and brackets that may close a sentence after its stop.
bool _closer(int unit) =>
    unit == 0x22 ||
    unit == 0x27 ||
    unit == 0x29 ||
    unit == 0x5d ||
    unit == 0xbb ||
    unit == 0x201d ||
    unit == 0x2019 ||
    unit == 0x201e;

/// , ; : and dashes: a soft break inside a long sentence.
bool _clause(int unit) =>
    unit == 0x2c ||
    unit == 0x3b ||
    unit == 0x3a ||
    unit == 0x2013 ||
    unit == 0x2014 ||
    unit == 0x060c ||
    unit == 0x3001;

int _letters(String text, int start, int end) {
  var count = 0;
  for (var i = start; i < end; i++) {
    final unit = text.codeUnitAt(i);
    // A surrogate pair (emoji) counts once.
    if (unit >= 0xdc00 && unit <= 0xdfff) continue;
    if (!_space(unit)) count++;
  }
  return count;
}

(int, int)? _trim(String text, int start, int end) {
  while (start < end && _space(text.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _space(text.codeUnitAt(end - 1))) {
    end--;
  }
  return start < end ? (start, end) : null;
}

/// Display lines of [text] as trimmed, half-open UTF-16 ranges, in order.
///
/// Every line break ends a line; a sentence ends after `.`, `!`, `?`, `…`
/// (and the Armenian `։`) plus closing quotes, followed by a space. A
/// sentence longer than [maxChars] is split into near-equal parts, at a
/// clause mark (`,` `;` `:` dash) when one is close to the target length,
/// otherwise at a space; a word longer than a line is cut. A sentence shorter
/// than [minChars] joins the next sentence of the same paragraph when both
/// fit one line.
List<(int, int)> transcriptLineRanges(
  String text, {
  int maxChars = transcriptLineMaxChars,
  int minChars = transcriptLineMinChars,
}) {
  assert(maxChars > 0);
  final lines = <(int, int)>[];
  var paragraph = 0;
  for (var i = 0; i <= text.length; i++) {
    if (i < text.length && !_newline(text.codeUnitAt(i))) continue;
    _paragraphLines(text, paragraph, i, maxChars, minChars, lines);
    paragraph = i + 1;
  }
  return lines;
}

void _paragraphLines(
  String text,
  int start,
  int end,
  int maxChars,
  int minChars,
  List<(int, int)> out,
) {
  final sentences = <(int, int)>[];
  var from = start;
  var i = start;
  while (i < end) {
    if (_sentenceEnd(text.codeUnitAt(i))) {
      var stop = i + 1;
      while (stop < end &&
          (_sentenceEnd(text.codeUnitAt(stop)) ||
              _closer(text.codeUnitAt(stop)))) {
        stop++;
      }
      if (stop == end || _space(text.codeUnitAt(stop))) {
        final range = _trim(text, from, stop);
        if (range != null) sentences.add(range);
        from = stop;
      }
      i = stop;
    } else {
      i++;
    }
  }
  final rest = _trim(text, from, end);
  if (rest != null) sentences.add(rest);

  // Short sentences ("Yes.", "OK, so.") join the next one when both fit.
  final joined = <(int, int)>[];
  for (var s = 0; s < sentences.length; s++) {
    var (a, b) = sentences[s];
    while (b - a < minChars &&
        s + 1 < sentences.length &&
        sentences[s + 1].$2 - a <= maxChars) {
      b = sentences[++s].$2;
    }
    joined.add((a, b));
  }
  for (final (a, b) in joined) {
    _split(text, a, b, maxChars, out);
  }
}

/// Splits one sentence into near-equal parts of at most [maxChars].
void _split(
  String text,
  int start,
  int end,
  int maxChars,
  List<(int, int)> out,
) {
  while (end - start > maxChars) {
    final parts = ((end - start) / maxChars).ceil();
    final target = start + (end - start) ~/ parts;
    final low = start + math.max<int>(1, (target - start) * 6 ~/ 10);
    final high = math.min<int>(start + maxChars, end - 1);
    var cut = -1;
    // A clause mark followed by a space, nearest the target.
    for (var i = low; i <= high; i++) {
      if (_clause(text.codeUnitAt(i - 1)) && _space(text.codeUnitAt(i))) {
        if (cut < 0 || (i - target).abs() < (cut - target).abs()) cut = i;
      }
    }
    // Otherwise the space nearest the target.
    if (cut < 0) {
      for (var i = low; i <= high; i++) {
        if (_space(text.codeUnitAt(i))) {
          if (cut < 0 || (i - target).abs() < (cut - target).abs()) cut = i;
        }
      }
    }
    if (cut < 0) {
      cut = start + maxChars;
      // Never between the halves of a surrogate pair.
      final unit = text.codeUnitAt(cut);
      if (unit >= 0xdc00 && unit <= 0xdfff) cut--;
    }
    final head = _trim(text, start, cut);
    if (head != null) out.add(head);
    final tail = _trim(text, cut, end);
    if (tail == null) return;
    (start, end) = tail;
  }
  out.add((start, end));
}

/// A decoded span: times in milliseconds, half-open text range.
class _Range {
  final int from, to, textStart, textEnd;
  const _Range(this.from, this.to, this.textStart, this.textEnd);
}

/// The flat delta encoding of [spans], or null when they are out of order.
List<int>? _encodeSpans(List<TranscriptSpan> spans) {
  final out = <int>[];
  var start = 0, textEnd = 0;
  for (final span in spans) {
    final from = span.start.inMilliseconds ~/ _unitMs;
    final to = span.end.inMilliseconds ~/ _unitMs;
    if (from < start ||
        to < from ||
        span.textStart < textEnd ||
        span.textEnd <= span.textStart) {
      return null;
    }
    out.addAll([
      from - start,
      to - from,
      span.textStart - textEnd,
      span.textEnd - span.textStart,
    ]);
    start = from;
    textEnd = span.textEnd;
  }
  return out;
}

/// Decoded spans of a flat delta list, or null when it is malformed, too
/// long or reaches past [textLength].
List<_Range>? _ranges(Object? value, int textLength, int maxSpans) {
  if (value is! List || value.length % 4 != 0) return null;
  if (value.length ~/ 4 > maxSpans) return null;
  final ranges = <_Range>[];
  var start = 0, textEnd = 0;
  for (var i = 0; i < value.length; i += 4) {
    final startGap = value[i], length = value[i + 1];
    final textGap = value[i + 2], textLength_ = value[i + 3];
    if (startGap is! int ||
        length is! int ||
        textGap is! int ||
        textLength_ is! int ||
        startGap < 0 ||
        length < 0 ||
        textGap < 0 ||
        textLength_ <= 0) {
      return null;
    }
    start += startGap;
    final textStart = textEnd + textGap;
    textEnd = textStart + textLength_;
    if (textEnd > textLength) return null;
    ranges.add(
      _Range(start * _unitMs, (start + length) * _unitMs, textStart, textEnd),
    );
  }
  return ranges;
}

/// UTF-8 bytes of [value] as JSON (numbers and ASCII keys only).
int _jsonBytes(Map<String, Object?> value) {
  var bytes = 2;
  var first = true;
  for (final MapEntry(:key, value: entry) in value.entries) {
    if (!first) bytes++;
    first = false;
    bytes += key.length + 3;
    if (entry is List<int>) {
      bytes += 2 + (entry.isEmpty ? 0 : entry.length - 1);
      for (final number in entry) {
        bytes += number.toString().length;
      }
    } else {
      bytes += entry.toString().length;
    }
  }
  return bytes;
}

/// Words per segment by text offset, or null when a word lies outside every
/// segment or the words are out of order.
List<List<_Range>>? _assignWords(List<_Range> segments, List<_Range> words) {
  final result = [for (final _ in segments) <_Range>[]];
  var s = 0;
  for (var w = 0; w < words.length; w++) {
    final word = words[w];
    if (w > 0 && (word.textStart < words[w - 1].textEnd)) return null;
    while (s < segments.length && segments[s].textEnd <= word.textStart) {
      s++;
    }
    if (s == segments.length ||
        word.textStart < segments[s].textStart ||
        word.textEnd > segments[s].textEnd) {
      return null;
    }
    result[s].add(word);
  }
  return result;
}

List<TranscriptLine> _segmentLines(
  String text,
  _Range segment,
  List<_Range> words,
) {
  final ranges = <(int, int)>[];
  for (final (start, end) in transcriptLineRanges(
    text.substring(segment.textStart, segment.textEnd),
  )) {
    ranges.add((segment.textStart + start, segment.textStart + end));
  }
  if (ranges.isEmpty) return const [];
  final span = segment.to - segment.from;
  final letters = [for (final (a, b) in ranges) _letters(text, a, b) + 1];
  final total = letters.fold<int>(0, (a, b) => a + b);
  final lines = <TranscriptLine>[];
  var spent = 0;
  for (var i = 0; i < ranges.length; i++) {
    final (start, end) = ranges[i];
    final inside = [
      for (final word in words)
        if (word.textStart >= start && word.textEnd <= end) word,
    ];
    // Shared by length inside the segment, or the words' own times.
    var from = segment.from + span * spent ~/ total;
    spent += letters[i];
    var to = i == ranges.length - 1
        ? segment.to
        : segment.from + span * spent ~/ total;
    if (inside.isNotEmpty) {
      from = inside.first.from;
      to = math.max(from, inside.last.to);
    }
    lines.add(
      TranscriptLine(
        start: Duration(milliseconds: from),
        end: Duration(milliseconds: to),
        text: text.substring(start, end),
        words: [
          for (final word in inside)
            TranscriptWord(
              start: Duration(milliseconds: word.from),
              end: Duration(milliseconds: word.to),
              textStart: word.textStart - start,
              textEnd: word.textEnd - start,
            ),
        ],
      ),
    );
  }
  return lines;
}

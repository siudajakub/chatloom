// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:personal_core/personal_core.dart';

/// Where the worker sends audio (`transcriptionProvider` in the config).
enum TranscriptionProvider {
  /// OpenAI's API: multipart upload, key `openaiApiKey`.
  openai,

  /// OpenRouter's speech-to-text API: JSON body with the audio in base64 and
  /// `provider.data_collection: deny`; key `openrouterApiKey` or the
  /// `openrouter_api_key` systemd credential.
  openrouter;

  /// The provider called [name] in the config; null for an unknown name.
  static TranscriptionProvider? byName(Object? name) {
    for (final provider in values) {
      if (provider.name == name) return provider;
    }
    return null;
  }
}

/// A provider speech model the worker can use: its provider, price and
/// whether the single transcription request also returns segment and word
/// timestamps.
///
/// Verified against OpenAI's documentation on 2026-10-31: `gpt-transcribe`
/// (USD 0.0045/min) returns text and languages only;
/// `timestamp_granularities[]` is supported only by `whisper-1` (USD
/// 0.006/min, deprecated, usable until 2027-02-26), with
/// `response_format=verbose_json`. `x-ai/grok-stt-1.0` through OpenRouter:
/// USD 0.10 per hour of audio (OpenRouter models API, 2026-10-31), answers
/// `verbose_json` with segments and words in the same request (five real
/// answers checked on 2026-10-31). Timestamps never cost a second request.
class TranscriptionModel {
  final TranscriptionProvider provider;
  final String name;
  final double pricePerMinute;
  final bool timestamps;
  const TranscriptionModel._(
    this.provider,
    this.name,
    this.pricePerMinute,
    this.timestamps,
  );

  /// xAI's Grok speech-to-text through OpenRouter: the default (J,
  /// 2026-10-31).
  static const grokStt = TranscriptionModel._(
    TranscriptionProvider.openrouter,
    'x-ai/grok-stt-1.0',
    0.10 / 60,
    true,
  );
  static const gptTranscribe = TranscriptionModel._(
    TranscriptionProvider.openai,
    'gpt-transcribe',
    0.0045,
    false,
  );
  static const whisper1 = TranscriptionModel._(
    TranscriptionProvider.openai,
    'whisper-1',
    0.006,
    true,
  );
  static const all = [grokStt, gptTranscribe, whisper1];

  /// The model of a config that names neither a provider nor a model.
  static const standard = grokStt;

  /// The model of a config that names only [provider].
  static TranscriptionModel defaultFor(TranscriptionProvider provider) =>
      switch (provider) {
        TranscriptionProvider.openrouter => grokStt,
        TranscriptionProvider.openai => gptTranscribe,
      };

  /// The model called [name] (of [provider] when given); null for an unknown
  /// name or a model of another provider.
  static TranscriptionModel? byName(
    String? name, {
    TranscriptionProvider? provider,
  }) {
    for (final model in all) {
      if (model.name == name &&
          (provider == null || model.provider == provider)) {
        return model;
      }
    }
    return null;
  }

  @override
  String toString() => '${provider.name}/$name';
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

/// How many letters of the text a word may skip after the previous one
/// (a word the provider left out of its word list) before the words are
/// considered misaligned.
const _wordLookahead = 32;

/// A segment whose text is not found as it is anchors on its first letters.
const _segmentHead = 12;

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

/// Characters that never decide whether a provider's word or segment
/// matches the transcript: spaces, controls, ASCII punctuation and symbols,
/// and the punctuation of the scripts the worker transcribes (Latin-1 signs,
/// general punctuation with its quotes and dashes, Armenian, Arabic,
/// Devanagari, CJK and full-width marks, variation selectors).
bool _ignorable(int rune) {
  if (rune < 0x80) {
    return !((rune >= 0x30 && rune <= 0x39) ||
        (rune >= 0x41 && rune <= 0x5a) ||
        (rune >= 0x61 && rune <= 0x7a));
  }
  return rune <= 0xbf ||
      rune == 0xd7 ||
      rune == 0xf7 ||
      (rune >= 0x2b9 && rune <= 0x2df) ||
      (rune >= 0x55a && rune <= 0x55f) ||
      rune == 0x589 ||
      rune == 0x58a ||
      rune == 0x60c ||
      rune == 0x61b ||
      rune == 0x61f ||
      rune == 0x6d4 ||
      rune == 0x964 ||
      rune == 0x965 ||
      (rune >= 0x2000 && rune <= 0x206f) ||
      (rune >= 0x2e00 && rune <= 0x2e7f) ||
      (rune >= 0x3000 && rune <= 0x303f) ||
      (rune >= 0xfe00 && rune <= 0xfe0f) ||
      (rune >= 0xfe10 && rune <= 0xfe6f) ||
      (rune >= 0xff01 && rune <= 0xff0f) ||
      (rune >= 0xff1a && rune <= 0xff20) ||
      (rune >= 0xff3b && rune <= 0xff40) ||
      (rune >= 0xff5b && rune <= 0xff65);
}

/// A text reduced to the characters that decide a match (no spaces or
/// punctuation, lower case), each with its UTF-16 range in the text.
/// Providers differ in punctuation and case between their text, segments
/// and words (Grok's words carry the punctuation of its own tokens, which
/// the text need not have), never in letters or digits.
class _Folded {
  final chars = <String>[];
  final starts = <int>[];
  final ends = <int>[];

  _Folded(String text) {
    for (var i = 0; i < text.length;) {
      var rune = text.codeUnitAt(i);
      var width = 1;
      if (rune >= 0xd800 && rune <= 0xdbff && i + 1 < text.length) {
        final low = text.codeUnitAt(i + 1);
        if (low >= 0xdc00 && low <= 0xdfff) {
          rune = 0x10000 + ((rune - 0xd800) << 10) + (low - 0xdc00);
          width = 2;
        }
      }
      if (!_ignorable(rune)) {
        chars.add(text.substring(i, i + width).toLowerCase());
        starts.add(i);
        ends.add(i + width);
      }
      i += width;
    }
  }

  int get length => chars.length;

  /// Index of the first kept character at or after UTF-16 [offset].
  int indexAt(int offset) {
    var low = 0, high = starts.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (starts[middle] < offset) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  /// Whether the first [count] characters of [other] occur at [index].
  bool matches(_Folded other, int index, int count) {
    if (index + count > length) return false;
    for (var i = 0; i < count; i++) {
      if (chars[index + i] != other.chars[i]) return false;
    }
    return true;
  }

  /// A word starts at [index]: the start of the text, or after a space or
  /// punctuation.
  bool wordStart(int index) => index == 0 || ends[index - 1] < starts[index];
}

/// Segment and word timestamps of a `verbose_json` answer for [text] (the
/// answer's text, trimmed), or null when it has none that can be found in
/// [text] in order.
///
/// Segments are anchored where their text starts and run to the next
/// segment, so together they cover the whole text even when the provider's
/// segment texts differ in spacing, punctuation or case. An answer with
/// words but no segments gets one segment over the whole text.
///
/// Words come from the top-level `words` list, or from `segments[].words`
/// when the provider nests them. They are compared with the text without
/// case, spaces and punctuation, and kept only when every word is found in
/// order; a word's span covers its letters in the text.
ChunkTimestamps? chunkTimestamps(Map<Object?, Object?> answer, String text) {
  if (text.trim().isEmpty) return null;
  final folded = _Folded(text);
  final rawSegments = answer['segments'];
  final words = _words(_rawWords(answer), folded);
  final List<TranscriptSpan> segments;
  if (rawSegments is List && rawSegments.isNotEmpty) {
    segments = _segments(rawSegments, text, folded) ?? const [];
    if (segments.isEmpty) return null;
  } else if (words.isNotEmpty) {
    var end = words.first.end;
    for (final word in words) {
      if (word.end > end) end = word.end;
    }
    segments = [
      TranscriptSpan(
        start: words.first.start,
        end: end,
        textStart: 0,
        textEnd: _trimEnd(text, 0, text.length),
      ),
    ];
  } else {
    return null;
  }
  return ChunkTimestamps(segments, words, _seconds(answer['duration']));
}

List<TranscriptSpan>? _segments(
  List<Object?> rawSegments,
  String text,
  _Folded folded,
) {
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
      // Spacing may differ: anchor on the first characters.
      final head = needle.substring(0, math.min(_segmentHead, needle.length));
      at = text.indexOf(head, cursor);
      length = head.length;
    }
    if (at < 0) {
      // Punctuation or case may differ too: anchor on the first letters.
      final letters = _Folded(needle);
      final count = math.min(_segmentHead, letters.length);
      if (count == 0) continue;
      for (var i = folded.indexAt(cursor); i + count <= folded.length; i++) {
        if (folded.wordStart(i) && folded.matches(letters, i, count)) {
          at = folded.starts[i];
          length = folded.ends[i + count - 1] - at;
          break;
        }
      }
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
  return segments.isEmpty ? null : segments;
}

/// The answer's words: the top-level `words` list (OpenAI, Grok), or the
/// `words` of each segment when a provider nests them there.
List<Object?> _rawWords(Map<Object?, Object?> answer) {
  final top = answer['words'];
  if (top is List && top.isNotEmpty) return top;
  final segments = answer['segments'];
  if (segments is! List) return const [];
  final nested = <Object?>[];
  for (final segment in segments) {
    final words = segment is Map ? segment['words'] : null;
    if (words is List) nested.addAll(words);
  }
  return nested;
}

List<TranscriptSpan> _words(List<Object?> raw, _Folded folded) {
  final words = <TranscriptSpan>[];
  var cursor = 0;
  var previous = Duration.zero;
  for (final word in raw) {
    if (word is! Map) return const [];
    final value = word['word'] ?? word['text'];
    final from = _seconds(word['start']), to = _seconds(word['end']);
    if (value is! String || from == null || to == null) return const [];
    final needle = _Folded(value);
    // A token of punctuation only has nothing to anchor.
    if (needle.length == 0) continue;
    var at = -1;
    final last = math.min(
      cursor + _wordLookahead,
      folded.length - needle.length,
    );
    for (var i = cursor; i <= last; i++) {
      // Right after the previous word, or skipping to the start of a word.
      if ((i == cursor || folded.wordStart(i)) &&
          folded.matches(needle, i, needle.length)) {
        at = i;
        break;
      }
    }
    if (at < 0) return const [];
    final start = from < previous ? previous : from;
    words.add(
      TranscriptSpan(
        start: start,
        end: to < start ? start : to,
        textStart: folded.starts[at],
        textEnd: folded.ends[at + needle.length - 1],
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

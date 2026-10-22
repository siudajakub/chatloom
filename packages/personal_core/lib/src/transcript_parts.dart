// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'transcription.dart' show sha256Hex;

/// Long transcripts in the private journal (worker → apps).
///
/// The Matrix SDK refuses a room event above 60000 bytes after megolm
/// encryption, which is about 1.34 x the plaintext event plus a few hundred
/// bytes: roughly 42 KB of transcript text, or 40 to 45 minutes of speech.
/// A longer transcript therefore travels as:
///
/// * the done `transcript.result`, whose `text` is a [transcriptPreviewSuffix]
///   terminated preview (what apps without part support show) and whose
///   `textParts` is a [TranscriptTextParts] record (count, length, SHA-256 of
///   the whole text);
/// * `count` events of kind [transcriptTextPartKind], each carrying one
///   consecutive slice of the whole text (index 0 first).
///
/// Apps with part support show the preview until every part has arrived and
/// the joined text matches the digest, then the whole text. The kind ends in
/// `.result`, so it is replayed through the same authenticated journal path
/// as every worker result; older replicas only record it as applied and keep
/// the preview. Nothing new is trusted: parts are ordinary encrypted journal
/// events of the worker device.
const transcriptTextPartKind = 'transcript.text.result';

/// Most JSON-encoded UTF-8 bytes of transcript text in one journal event.
/// With the rest of a result (about 1-2 KB) and megolm overhead, an event
/// stays near 36 KB, well below the SDK limit.
const transcriptTextEventBudget = 24000;

/// Upper bound of parts per transcript (64 x 24 KB, about 25 hours of speech).
/// Longer text is cut at this bound rather than published unbounded.
const transcriptTextMaxParts = 64;

/// Appended to the preview so readers of a truncated text can tell.
const transcriptPreviewSuffix = ' …';

/// Bytes [unit] (a UTF-16 code unit that is not part of a surrogate pair) can
/// take inside a JSON string, never less than the encoder writes.
int _unitBytes(int unit) {
  if (unit == 0x22 || unit == 0x5c) return 2; // \" and \\
  if (unit < 0x20) return 6; // \u00XX (or a shorter escape)
  if (unit < 0x80) return 1;
  if (unit < 0x800) return 2;
  if (unit >= 0xd800 && unit <= 0xdfff) return 6; // lone surrogate: \uXXXX
  return 3;
}

/// Upper bound of the UTF-8 bytes [text] takes inside a JSON string.
int transcriptJsonBytes(String text) {
  var bytes = 0;
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (_pairAt(text, i)) {
      bytes += 4;
      i++;
    } else {
      bytes += _unitBytes(unit);
    }
  }
  return bytes;
}

bool _pairAt(String text, int i) {
  final unit = text.codeUnitAt(i);
  if (unit < 0xd800 || unit > 0xdbff || i + 1 >= text.length) return false;
  final next = text.codeUnitAt(i + 1);
  return next >= 0xdc00 && next <= 0xdfff;
}

/// Whether [text] fits one journal event.
bool transcriptTextFits(
  String text, {
  int budget = transcriptTextEventBudget,
}) => transcriptJsonBytes(text) <= budget;

/// Consecutive slices of [text], each at most [budget] JSON-encoded UTF-8
/// bytes; surrogate pairs are never split, so joining the slices restores
/// [text] exactly. An empty text is one empty slice.
List<String> splitTranscriptText(
  String text, {
  int budget = transcriptTextEventBudget,
}) {
  if (budget < 8) throw ArgumentError.value(budget, 'budget');
  final parts = <String>[];
  var start = 0, bytes = 0, i = 0;
  while (i < text.length) {
    final pair = _pairAt(text, i);
    final width = pair ? 2 : 1;
    final cost = pair ? 4 : _unitBytes(text.codeUnitAt(i));
    if (bytes + cost > budget && i > start) {
      parts.add(text.substring(start, i));
      start = i;
      bytes = 0;
    }
    bytes += cost;
    i += width;
  }
  if (start < text.length || parts.isEmpty) parts.add(text.substring(start));
  return parts;
}

/// The `textParts` record of a done `transcript.result`.
class TranscriptTextParts {
  final int count;

  /// UTF-16 length of the whole text.
  final int length;

  /// Lowercase hex SHA-256 of the whole text's UTF-8 bytes.
  final String digest;

  const TranscriptTextParts({
    required this.count,
    required this.length,
    required this.digest,
  });

  static String digestOf(String text) => sha256Hex(utf8.encode(text));

  static final _hex = RegExp(r'^[0-9a-f]{64}$');

  Map<String, Object?> toJson() => {
    'count': count,
    'length': length,
    'sha256': digest,
  };

  /// Null for anything but a complete, plausible record.
  static TranscriptTextParts? tryParse(Object? value) {
    if (value is! Map) return null;
    final count = value['count'], length = value['length'];
    final digest = value['sha256'];
    if (count is! int ||
        count < 1 ||
        count > transcriptTextMaxParts ||
        length is! int ||
        length < 0 ||
        digest is! String ||
        !_hex.hasMatch(digest)) {
      return null;
    }
    return TranscriptTextParts(count: count, length: length, digest: digest);
  }

  /// Whether [text] is the whole text this record describes.
  bool matches(Object? text) =>
      text is String && text.length == length && digestOf(text) == digest;
}

/// One `transcript.text.result` payload.
class TranscriptTextPart {
  final int index;
  final int count;
  final String digest;
  final String text;
  const TranscriptTextPart({
    required this.index,
    required this.count,
    required this.digest,
    required this.text,
  });

  /// Null for a malformed part, or one whose text was erased (`text: null`
  /// after the source message was deleted).
  static TranscriptTextPart? tryParse(Map<String, dynamic> payload) {
    final index = payload['index'], count = payload['count'];
    final digest = payload['sha256'], text = payload['text'];
    if (index is! int ||
        count is! int ||
        count < 1 ||
        count > transcriptTextMaxParts ||
        index < 0 ||
        index >= count ||
        digest is! String ||
        !TranscriptTextParts._hex.hasMatch(digest) ||
        text is! String) {
      return null;
    }
    return TranscriptTextPart(
      index: index,
      count: count,
      digest: digest,
      text: text,
    );
  }
}

/// How a transcript text is published; null from [of] when it fits one event.
class TranscriptTextPublication {
  final String preview;
  final TranscriptTextParts meta;
  final List<String> parts;
  const TranscriptTextPublication(this.preview, this.meta, this.parts);

  static TranscriptTextPublication? of(
    String? text, {
    int budget = transcriptTextEventBudget,
  }) {
    if (text == null || transcriptTextFits(text, budget: budget)) return null;
    var parts = splitTranscriptText(text, budget: budget);
    var whole = text;
    if (parts.length > transcriptTextMaxParts) {
      parts = parts.sublist(0, transcriptTextMaxParts);
      whole = parts.join();
    }
    // The preview ends at a word boundary near the end of the first slice.
    var head = splitTranscriptText(
      text,
      budget: budget - transcriptJsonBytes(transcriptPreviewSuffix),
    ).first;
    final cut = head.lastIndexOf(RegExp(r'\s'));
    if (cut > head.length - 200 && cut > 0) head = head.substring(0, cut);
    return TranscriptTextPublication(
      '${head.trimRight()}$transcriptPreviewSuffix',
      TranscriptTextParts(
        count: parts.length,
        length: whole.length,
        digest: TranscriptTextParts.digestOf(whole),
      ),
      parts,
    );
  }

  /// Payload of part [index] for job [id] at [revision].
  Map<String, Object?> partPayload(String id, int revision, int index) => {
    'id': id,
    'revision': revision,
    'index': index,
    'count': meta.count,
    'sha256': meta.digest,
    'text': parts[index],
  };
}

/// The whole text from [parts] (index → slice), or null until every part is
/// present and the joined text matches [meta].
String? assembleTranscriptText(
  TranscriptTextParts meta,
  Map<int, String> parts,
) {
  if (parts.length < meta.count) return null;
  final buffer = StringBuffer();
  for (var i = 0; i < meta.count; i++) {
    final part = parts[i];
    if (part == null) return null;
    buffer.write(part);
  }
  final text = buffer.toString();
  return meta.matches(text) ? text : null;
}

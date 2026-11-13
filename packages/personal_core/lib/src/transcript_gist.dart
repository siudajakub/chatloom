// SPDX-License-Identifier: AGPL-3.0-or-later

/// The gist of a transcript: the cue a reply quote shows under "Voice
/// message" so the reader knows which voice note a reply answers without
/// playing it (J, 2026-11-13). Rules shared by the worker, which writes it,
/// and the app, which shows it or falls back to the transcript itself.
library;

/// A transcript of at most this many words (and
/// [transcriptGistVerbatimMaxChars]) is its own gist: quoted verbatim,
/// no model request.
const transcriptGistVerbatimMaxWords = 14;
const transcriptGistVerbatimMaxChars = 100;

/// Up to this many words the gist is one sentence; longer notes get two.
const transcriptGistOneSentenceMaxWords = 60;

/// Hard cap on a stored gist; anything longer is rejected, not cut.
const transcriptGistMaxChars = 240;

final _space = RegExp(r'\s+');

/// [text] on one line with single spaces.
String transcriptGistOneLine(String text) =>
    text.replaceAll(_space, ' ').trim();

int transcriptGistWordCount(String text) {
  final line = transcriptGistOneLine(text);
  return line.isEmpty ? 0 : line.split(' ').length;
}

/// [text] itself when it is short enough to quote as its gist, else null.
String? transcriptGistVerbatim(String text) {
  final line = transcriptGistOneLine(text);
  if (line.isEmpty) return null;
  if (line.length > transcriptGistVerbatimMaxChars) return null;
  if (transcriptGistWordCount(line) > transcriptGistVerbatimMaxWords) {
    return null;
  }
  return line;
}

/// How many sentences the model may use for [text]: 1 or 2.
int transcriptGistSentences(String text) =>
    transcriptGistWordCount(text) <= transcriptGistOneSentenceMaxWords ? 1 : 2;

/// A stored or generated gist as shown: one line, without wrapping quotes;
/// null when [value] is not a usable gist (missing, empty, too long).
String? normalizeTranscriptGist(Object? value) {
  if (value is! String) return null;
  var line = transcriptGistOneLine(value);
  const quotes = {'"': '"', '“': '”', '„': '”', '«': '»', "'": "'"};
  for (final entry in quotes.entries) {
    if (line.length > 1 &&
        line.startsWith(entry.key) &&
        line.endsWith(entry.value)) {
      line = line.substring(1, line.length - 1).trim();
      break;
    }
  }
  if (line.isEmpty || line.length > transcriptGistMaxChars) return null;
  return line;
}

/// What a reply quote shows for a transcript: the stored [gist], else the
/// transcript on one line (the quote cuts it to its lines).
String? transcriptQuoteText(String? text, String? gist) {
  final stored = normalizeTranscriptGist(gist);
  if (stored != null) return stored;
  if (text == null) return null;
  final line = transcriptGistOneLine(text);
  return line.isEmpty ? null : line;
}

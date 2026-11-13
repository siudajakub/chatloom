// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:personal_core/personal_core.dart';
import 'package:test/test.dart';

void main() {
  final source = SourceEventRef(
    conversation: const ConversationRef(
      accountId: '@self:example.invalid',
      roomId: '!room:example.invalid',
    ),
    eventId: r'$voice',
  );

  test('a short note is its own gist, a longer one is not', () {
    expect(
      transcriptGistVerbatim('  Okay,\n see you at eight! '),
      'Okay, see you at eight!',
    );
    expect(transcriptGistVerbatim('   '), isNull);
    expect(
      transcriptGistVerbatim(
        List.filled(transcriptGistVerbatimMaxWords + 1, 'tak').join(' '),
      ),
      isNull,
    );
    expect(
      transcriptGistVerbatim('x' * (transcriptGistVerbatimMaxChars + 1)),
      isNull,
    );
  });

  test('one sentence for a short note, two for a longer one', () {
    expect(transcriptGistSentences(List.filled(60, 'a').join(' ')), 1);
    expect(transcriptGistSentences(List.filled(61, 'a').join(' ')), 2);
  });

  test('a stored gist is one line without wrapping quotes, or nothing', () {
    expect(normalizeTranscriptGist('"Domek,\n900 zł."'), 'Domek, 900 zł.');
    expect(normalizeTranscriptGist('„Domek”'), 'Domek');
    expect(normalizeTranscriptGist('He said "no"'), 'He said "no"');
    expect(normalizeTranscriptGist(''), isNull);
    expect(normalizeTranscriptGist(42), isNull);
    expect(normalizeTranscriptGist('x' * (transcriptGistMaxChars + 1)), isNull);
  });

  test('a quote shows the gist, else the transcript on one line', () {
    expect(transcriptQuoteText('long text', 'Gist.'), 'Gist.');
    expect(transcriptQuoteText('long\ntext', null), 'long text');
    expect(transcriptQuoteText('long text', ''), 'long text');
    expect(transcriptQuoteText(null, null), isNull);
  });

  test('TranscriptionJob carries the gist and keeps the old shape without', () {
    final job = TranscriptionJob(
      id: 't',
      source: source,
      state: JobState.done,
      text: 'długa notatka',
      gist: 'Notatka.',
    );
    final json = job.toJson();
    expect(json['gist'], 'Notatka.');
    expect(TranscriptionJob.fromJson(json).gist, 'Notatka.');
    final plain = TranscriptionJob(
      id: 't',
      source: source,
      state: JobState.done,
      text: 'x',
    ).toJson();
    expect(plain.containsKey('gist'), isFalse);
    // An erased text takes its gist with it; a malformed gist is dropped.
    expect(TranscriptionJob.fromJson({...json, 'text': null}).gist, isNull);
    expect(TranscriptionJob.fromJson({...json, 'gist': 7}).gist, isNull);
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:personal_worker/src/transcript_alignment.dart';
import 'package:personal_worker/src/transcript_timestamps.dart';
import 'package:test/test.dart';

ChunkTimestamps stamps(String text, {List<double>? starts, double end = 20}) {
  final words = text.split(' ');
  return chunkTimestamps({
    'words': [
      for (var i = 0; i < words.length; i++)
        {
          'word': words[i],
          'start': starts?[i] ?? i,
          'end': (starts?[i] ?? i) + 0.5,
        },
    ],
    'duration': end,
  }, text)!;
}

void main() {
  test(
    'insertions and deletions resynchronise without invented word times',
    () {
      const primary = 'one two three four five six seven eight nine ten';
      const secondary = 'one two extra three four five seven eight nine ten';
      final result = alignTranscriptWords(
        primary,
        secondary,
        stamps(secondary),
        const Duration(seconds: 20),
      )!;
      // The line containing missing "six" remains readable without word
      // highlights; no interval is invented for that primary-only word.
      expect(result.words, isEmpty);
      expect(result.segments.single.textEnd, primary.length);
    },
  );
  test('long matching chunks stay within the bounded alignment band', () {
    final text = List.generate(2000, (i) => 'word$i').join(' ');
    final result = alignTranscriptWords(
      text,
      text,
      stamps(text),
      const Duration(seconds: 2100),
    )!;
    expect(result.words.length, 2000);
  });
  test(
    'case, punctuation and contractions preserve authoritative text ranges',
    () {
      const primary = "Hello, WORLD! Don't stop.";
      const secondary = "hello world don't stop";
      final result = alignTranscriptWords(
        primary,
        secondary,
        stamps(secondary),
        const Duration(seconds: 20),
      )!;
      expect(
        result.words.map((w) => primary.substring(w.textStart, w.textEnd)),
        ['Hello', 'WORLD', "Don't", 'stop'],
      );
      expect(result.duration, const Duration(seconds: 20));
    },
  );
  test('substitution leaves its entire line without word highlighting', () {
    const primary =
        'We really enjoy the beautiful English weather today.\n'
        'Please bring the large blue umbrella with you.';
    const secondary =
        'we really enjoy the beautiful English whether today '
        'please bring the large blue umbrella with you';
    final result = alignTranscriptWords(
      primary,
      secondary,
      stamps(secondary),
      const Duration(seconds: 30),
    )!;
    expect(result.segments.length, 2);
    expect(
      result.words.every((w) => w.textStart > primary.indexOf('\n')),
      isTrue,
    );
    final record = transcriptTimingRecord([primary], [result])!;
    expect(record['words'], isNotNull);
  });
  test(
    'low coverage, invalid bounds and excessive sequence drift drop timing',
    () {
      const text = 'This is the authoritative English transcript';
      expect(
        alignTranscriptWords(
          text,
          'Something completely different',
          stamps('Something completely different'),
          const Duration(seconds: 20),
        ),
        isNull,
      );
      expect(
        alignTranscriptWords(
          text,
          text,
          stamps(text),
          const Duration(seconds: 1),
        ),
        isNull,
      );
      final long = List.filled(6100, 'word').join(' ');
      expect(
        alignTranscriptWords(
          long,
          'word',
          stamps('word'),
          const Duration(seconds: 20),
        ),
        isNull,
      );
    },
  );
  test('malformed secondary timestamps are rejected before clamping', () {
    for (final words in [
      [
        {'word': 'one', 'start': 2, 'end': 1},
      ],
      [
        {'word': 'one', 'start': 1, 'end': 2},
        {'word': 'two', 'start': 0, 'end': 1},
      ],
      [
        {'word': 'one', 'start': -1, 'end': 1},
      ],
    ]) {
      expect(validAlignmentAnswer({'words': words}), isFalse);
    }
    expect(
      validAlignmentAnswer({
        'words': [
          {'word': 'one', 'start': 0, 'end': 1},
        ],
      }),
      isTrue,
    );
  });
}

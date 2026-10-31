// SPDX-License-Identifier: AGPL-3.0-or-later
// Time-synced transcript lines: approximate estimate and the stored record.
import 'package:personal_core/personal_core.dart';
import 'package:test/test.dart';

const _s = Duration(seconds: 1);

List<String> _texts(String text, List<(int, int)> ranges) => [
  for (final (start, end) in ranges) text.substring(start, end),
];

void main() {
  group('transcriptLineRanges', () {
    test('splits sentences and line breaks, trims, keeps abbreviations', () {
      const text =
          '  Hello there, Anna! How was the trip?\n\n'
          'The price was 3.5 euro… “Fine.” See you at 10.  ';
      expect(_texts(text, transcriptLineRanges(text)), [
        'Hello there, Anna!',
        'How was the trip?',
        'The price was 3.5 euro…',
        '“Fine.” See you at 10.',
      ]);
    });

    test('joins short sentences while they fit one line', () {
      const text = 'Yes. OK. So tomorrow we meet at the station, right?';
      expect(_texts(text, transcriptLineRanges(text)), [
        'Yes. OK. So tomorrow we meet at the station, right?',
      ]);
    });

    test('splits long sentences near-equally at clauses, then spaces', () {
      const text =
          'We went to the market in the morning, bought bread and cheese, '
          'and then we walked along the river until it got dark';
      final lines = _texts(text, transcriptLineRanges(text, maxChars: 60));
      expect(lines, [
        'We went to the market in the morning,',
        'bought bread and cheese,',
        'and then we walked along the river until it got dark',
      ]);
      expect(lines.every((line) => line.length <= 60), isTrue);
      expect(lines.join(' '), text);
    });

    test('cuts a word longer than a line without splitting an emoji', () {
      final word = '${'a' * 59}🎙️${'b' * 20}';
      final lines = _texts(word, transcriptLineRanges(word, maxChars: 60));
      expect(lines.every((line) => line.length <= 60), isTrue);
      expect(lines.join(), word);
      for (final line in lines) {
        final last = line.codeUnitAt(line.length - 1);
        expect(last >= 0xd800 && last <= 0xdbff, isFalse);
      }
    });

    test('handles Armenian full stops and blank text', () {
      const text = 'Բարև։ Ինչպե՞ս ես, իմ ընկեր։';
      expect(transcriptLineRanges(text, minChars: 1), hasLength(2));
      expect(transcriptLineRanges('  \n\n '), isEmpty);
    });
  });

  group('TranscriptTiming.approximate', () {
    test('shares the duration by length, contiguous from zero to the end', () {
      const text = 'Short one. This sentence is clearly a lot longer than it.';
      final timing = TranscriptTiming.approximate(
        text,
        const Duration(seconds: 10),
        minChars: 1,
      );
      expect(timing.approximate, isTrue);
      expect(timing.lines, hasLength(2));
      final [first, second] = timing.lines;
      expect(first.start, Duration.zero);
      expect(first.end, second.start);
      expect(second.end, const Duration(seconds: 10));
      expect(first.end - first.start < second.end - second.start, isTrue);
      expect(first.words, isEmpty);
    });

    test('finds the line at a position', () {
      final timing = TranscriptTiming.approximate(
        'One line here. Another line there. And a third line now.',
        const Duration(seconds: 9),
        minChars: 1,
      );
      expect(timing.indexAt(Duration.zero), 0);
      expect(timing.indexAt(timing.lines[1].start), 1);
      expect(timing.indexAt(timing.lines[1].start - _s * .001), 0);
      expect(timing.indexAt(const Duration(minutes: 5)), 2);
      expect(timing.indexAt(-_s), -1);
    });

    test('is empty for blank text and safe for no duration', () {
      expect(TranscriptTiming.approximate(' ', _s).lines, isEmpty);
      final zero = TranscriptTiming.approximate('A. B.', Duration.zero);
      expect(zero.lines.every((l) => l.start == Duration.zero), isTrue);
    });
  });

  group('TranscriptTiming.tryParse', () {
    const text = 'Hello Anna. How are you today?';
    TranscriptSpan span(double from, double to, int start, int end) =>
        TranscriptSpan(
          start: _s * from,
          end: _s * to,
          textStart: start,
          textEnd: end,
        );
    final segments = [span(.5, 1.6, 0, 11), span(2.4, 4, 12, 30)];
    final words = [
      span(.5, .9, 0, 5),
      span(1, 1.6, 6, 11),
      span(2.4, 2.6, 12, 15),
      span(2.7, 2.9, 16, 19),
      span(3, 3.2, 20, 23),
      span(3.3, 4, 24, 30),
    ];
    final record = TranscriptTiming.encode(segments: segments, words: words)!;

    test('encodes compact deltas in centiseconds', () {
      expect(record['segments'], [50, 110, 0, 11, 190, 160, 1, 18]);
      expect((record['words']! as List).take(8), [50, 40, 0, 5, 50, 60, 1, 5]);
    });

    test('reads exact segments and words', () {
      final timing = TranscriptTiming.tryParse(record, text)!;
      expect(timing.approximate, isFalse);
      expect(
        [for (final line in timing.lines) line.text],
        ['Hello Anna.', 'How are you today?'],
      );
      final [first, second] = timing.lines;
      expect(first.start, _s * .5);
      expect(second.start, _s * 2.4);
      expect(timing.indexAt(_s * .2), -1);
      // A pause keeps the previous line.
      expect(timing.indexAt(_s * 2), 0);
      expect(second.words, hasLength(4));
      expect(second.words.first.textStart, 0);
      expect(second.text.substring(4, 7), 'are');
      expect(second.wordAt(_s * 2.8), 1);
      expect(second.wordAt(_s * 2), -1);
    });

    test('drops words outside the segments but keeps the segments', () {
      final broken = {
        ...record,
        'words': [0, 10, 5, 9],
      };
      final timing = TranscriptTiming.tryParse(broken, text)!;
      expect(timing.lines.every((line) => line.words.isEmpty), isTrue);
    });

    test('leaves words out, then everything, past the budget', () {
      final small = TranscriptTiming.encode(
        segments: segments,
        words: words,
        budget: 60,
      )!;
      expect(small.containsKey('words'), isFalse);
      expect(TranscriptTiming.tryParse(small, text), isNotNull);
      expect(TranscriptTiming.encode(segments: segments, budget: 10), isNull);
      expect(TranscriptTiming.encode(segments: const []), isNull);
      // Out of order.
      expect(
        TranscriptTiming.encode(segments: segments.reversed.toList()),
        isNull,
      );
    });

    test('splits a long segment by its words, or by length', () {
      const long =
          'We went to the market in the morning, bought bread and cheese, '
          'and then we walked along the river until it got dark';
      final segment = TranscriptTiming.encode(segments: [span(0, 10, 0, 115)]);
      final timing = TranscriptTiming.tryParse(segment, long)!;
      expect(timing.lines.length, greaterThan(1));
      expect(timing.lines.first.start, Duration.zero);
      expect(timing.lines.last.end, _s * 10);
      for (var i = 1; i < timing.lines.length; i++) {
        expect(timing.lines[i].start, timing.lines[i - 1].end);
      }
    });

    test('refuses inconsistent records', () {
      expect(TranscriptTiming.tryParse(null, text), isNull);
      expect(TranscriptTiming.tryParse({'v': 2, 'segments': []}, text), isNull);
      // Past the end of the text.
      expect(
        TranscriptTiming.tryParse({
          'v': 1,
          'segments': [0, 100, 0, 99],
        }, text),
        isNull,
      );
      // Negative gap, a fractional number, a ragged list.
      for (final segments in [
        [0, 100, 0, 11, -10, 100, 1, 18],
        [0, 100.5, 0, 30],
        [0, 100, 0, 30, 1],
      ]) {
        expect(
          TranscriptTiming.tryParse({'v': 1, 'segments': segments}, text),
          isNull,
        );
      }
      // Text left outside every segment would never be shown.
      expect(
        TranscriptTiming.tryParse({
          'v': 1,
          'segments': [0, 100, 0, 11],
        }, text),
        isNull,
      );
    });
  });

  group('TranscriptionJob.timing', () {
    const source = SourceEventRef(
      conversation: ConversationRef(
        accountId: '@synthetic:example.invalid',
        roomId: '!synthetic:example.invalid',
      ),
      eventId: r'$synthetic',
    );

    test('round-trips and keeps the old JSON shape without it', () {
      const plain = TranscriptionJob(
        id: 'transcript:x',
        source: source,
        state: JobState.done,
        text: 'Hi.',
      );
      expect(plain.toJson().containsKey('timing'), isFalse);
      final timed = TranscriptionJob.fromJson({
        ...plain.toJson(),
        'timing': {
          'v': 1,
          'segments': [0, 50, 0, 3],
        },
      });
      expect(TranscriptTiming.tryParse(timed.timing, timed.text!), isNotNull);
      expect(timed.toJson()['timing'], timed.timing);
    });

    test('an erased text carries no timing', () {
      final erased = TranscriptionJob.fromJson({
        'id': 'transcript:x',
        'source': source.toJson(),
        'state': 'cancelled',
        'text': null,
        'timing': {'v': 1, 'segments': []},
      });
      expect(erased.timing, isNull);
    });
  });
}

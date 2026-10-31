// SPDX-License-Identifier: AGPL-3.0-or-later
// NotionSyncedTranscript (live transcript of a playing message) and
// NotionLayoutFlip (the stage making room for it): following, seeking,
// pausing while the user scrolls, reduced motion and a resting golden.
// Run goldens through scripts/verify-notion-ui.py so fonts match.
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _height = 400.0;

final _lines = [
  for (var i = 0; i < 12; i++)
    NotionTranscriptLine(
      start: Duration(seconds: 3 * i),
      text: 'Line $i',
    ),
];

Widget _app(
  Widget child, {
  bool reduced = false,
  Size size = const Size(390, _height),
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: NotionTheme.build(Brightness.dark),
  builder: (context, app) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
    child: app!,
  ),
  home: Scaffold(
    backgroundColor: NotionMediaColors.viewer,
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox.fromSize(size: size, child: child),
    ),
  ),
);

/// How far line [i] is from its resting place: a line at the anchor has its
/// box (text plus `NotionSpace.xs` above and below) at `anchor` of the room
/// the box leaves in the view (`RenderAbstractViewport.getOffsetToReveal`).
double _offAnchor(WidgetTester tester, int i) {
  final text = tester.getRect(find.text('Line $i'));
  final box = text.height + 2 * NotionSpace.xs;
  final rest = NotionSyncedTranscript.defaultAnchor * (_height - box);
  return text.top - NotionSpace.xs - rest;
}

/// Word ranges of [text] split at single spaces.
List<NotionTranscriptWord> _words(String text, Duration start, Duration step) {
  final words = <NotionTranscriptWord>[];
  var offset = 0;
  for (final (i, word) in text.split(' ').indexed) {
    words.add(
      NotionTranscriptWord(
        start: start + step * i,
        textStart: offset,
        textEnd: offset + word.length,
      ),
    );
    offset += word.length + 1;
  }
  return words;
}

void main() {
  setUpAll(() async {
    final loader = FontLoader('Roboto');
    for (final name in ['Regular', 'Medium', 'Bold']) {
      loader.addFont(rootBundle.load('assets/notion/fonts/Roboto-$name.ttf'));
    }
    await loader.load();
  });

  test('finds the line and the word at a position', () {
    expect(
      NotionSyncedTranscript.indexAt(_lines, -const Duration(seconds: 1)),
      -1,
    );
    expect(NotionSyncedTranscript.indexAt(_lines, Duration.zero), 0);
    expect(
      NotionSyncedTranscript.indexAt(_lines, const Duration(seconds: 7)),
      2,
    );
    expect(
      NotionSyncedTranscript.indexAt(_lines, const Duration(hours: 1)),
      11,
    );
    const line = NotionTranscriptLine(
      start: Duration.zero,
      text: 'one two',
      words: [
        NotionTranscriptWord(
          start: Duration(milliseconds: 100),
          textStart: 0,
          textEnd: 3,
        ),
        NotionTranscriptWord(
          start: Duration(milliseconds: 500),
          textStart: 4,
          textEnd: 7,
        ),
      ],
    );
    expect(NotionSyncedTranscript.wordAt(line, Duration.zero), -1);
    expect(
      NotionSyncedTranscript.wordAt(line, const Duration(milliseconds: 600)),
      1,
    );
  });

  testWidgets('follows playback: the current line glides to the anchor', (
    tester,
  ) async {
    final position = ValueNotifier(const Duration(seconds: 1));
    addTearDown(position.dispose);
    await tester.pumpWidget(
      _app(NotionSyncedTranscript(lines: _lines, position: position)),
    );
    await tester.pump();
    expect(_offAnchor(tester, 0), closeTo(0, 1));

    position.value = const Duration(seconds: 13); // line 4
    await tester.pump();
    // The glide is under way, not a jump.
    await tester.pump(const Duration(milliseconds: 60));
    expect(_offAnchor(tester, 4).abs(), greaterThan(1));
    await tester.pumpAndSettle();
    expect(_offAnchor(tester, 4), closeTo(0, 1));
    final semantics = tester.ensureSemantics();
    await tester.pump();
    expect(
      tester.getSemantics(find.text('Line 4')),
      isSemantics(label: 'Line 4', isSelected: true),
    );
    expect(
      tester.getSemantics(find.text('Line 3')),
      isSemantics(label: 'Line 3', isSelected: false),
    );
    semantics.dispose();
  });

  testWidgets('a tap seeks to the line', (tester) async {
    final position = ValueNotifier(Duration.zero);
    addTearDown(position.dispose);
    final seeks = <Duration>[];
    await tester.pumpWidget(
      _app(
        NotionSyncedTranscript(
          lines: _lines,
          position: position,
          onSeek: seeks.add,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Line 3'));
    await tester.pumpAndSettle();
    expect(seeks, [const Duration(seconds: 9)]);
    // The tapped line comes to the anchor at once, before the player answers.
    expect(_offAnchor(tester, 3), closeTo(0, 1));
  });

  testWidgets('following pauses while the user scrolls and resumes later', (
    tester,
  ) async {
    final position = ValueNotifier(Duration.zero);
    addTearDown(position.dispose);
    await tester.pumpWidget(
      _app(NotionSyncedTranscript(lines: _lines, position: position)),
    );
    await tester.pump();
    await tester.timedDrag(
      find.text('Line 2'),
      const Offset(0, -150),
      const Duration(milliseconds: 600),
    );
    // Let the slow fling come to rest (the hold starts then).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final scrolled = _offAnchor(tester, 1);
    expect(scrolled.abs(), greaterThan(40));

    position.value = const Duration(seconds: 4); // line 1
    await tester.pump();
    await tester.pump(NotionMotion.long);
    expect(_offAnchor(tester, 1), closeTo(scrolled, .5));

    // After the hold the list comes back to the current line.
    await tester.pump(NotionSyncedTranscript.defaultFollowHold);
    await tester.pumpAndSettle();
    expect(_offAnchor(tester, 1), closeTo(0, 1));
  });

  testWidgets('reduced motion switches lines and jumps without animation', (
    tester,
  ) async {
    final position = ValueNotifier(Duration.zero);
    addTearDown(position.dispose);
    await tester.pumpWidget(
      _app(
        NotionSyncedTranscript(lines: _lines, position: position),
        reduced: true,
      ),
    );
    await tester.pump();
    position.value = const Duration(seconds: 20); // line 6
    await tester.pump();
    // No ticker runs: no glide, no emphasis tween.
    expect(tester.binding.transientCallbackCount, 0);
    expect(_offAnchor(tester, 6), closeTo(0, 1));
  });

  testWidgets('words of the current line light up as they are spoken', (
    tester,
  ) async {
    final position = ValueNotifier(const Duration(milliseconds: 600));
    addTearDown(position.dispose);
    const line = NotionTranscriptLine(
      start: Duration.zero,
      text: 'one two three',
      words: [
        NotionTranscriptWord(start: Duration.zero, textStart: 0, textEnd: 3),
        NotionTranscriptWord(
          start: Duration(milliseconds: 500),
          textStart: 4,
          textEnd: 7,
        ),
        NotionTranscriptWord(
          start: Duration(seconds: 1),
          textStart: 8,
          textEnd: 13,
        ),
      ],
    );
    await tester.pumpWidget(
      _app(NotionSyncedTranscript(lines: const [line], position: position)),
    );
    await tester.pump();
    List<String> spans() {
      final text = tester.widget<RichText>(
        find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText() == 'one two three',
        ),
      );
      return [
        for (final span
            in (text.text as TextSpan).children!.cast<TextSpan>().expand(
              (s) => s.children?.cast<TextSpan>() ?? [s],
            ))
          span.text!,
      ];
    }

    expect(spans(), ['one two', ' three']);
    position.value = const Duration(seconds: 2);
    await tester.pump();
    expect(spans(), ['one two three']);
  });

  testWidgets('synced transcript golden', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 520);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final position = ValueNotifier(const Duration(milliseconds: 9400));
    addTearDown(position.dispose);
    const spoken = 'And then we walked along the river until it got dark';
    final lines = [
      const NotionTranscriptLine(
        start: Duration.zero,
        text: 'Hi Anna, it’s me again.',
      ),
      const NotionTranscriptLine(
        start: Duration(milliseconds: 2100),
        text: 'We went to the market in the morning,',
      ),
      const NotionTranscriptLine(
        start: Duration(milliseconds: 5200),
        text: 'bought bread and cheese,',
      ),
      NotionTranscriptLine(
        start: const Duration(milliseconds: 7400),
        text: spoken,
        words: _words(
          spoken,
          const Duration(milliseconds: 7400),
          const Duration(milliseconds: 400),
        ),
      ),
      const NotionTranscriptLine(
        start: Duration(milliseconds: 12600),
        text: 'so call me when you’re back home.',
      ),
      const NotionTranscriptLine(
        start: Duration(milliseconds: 15000),
        text: 'Talk soon!',
      ),
    ];
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('golden'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: NotionTheme.build(Brightness.dark),
          home: Scaffold(
            backgroundColor: NotionMediaColors.viewer,
            body: SafeArea(
              child: Padding(
                padding: NotionSpace.page,
                child: NotionSyncedTranscript(
                  lines: lines,
                  position: position,
                  onSeek: (_) {},
                  caption: 'Approximate timing',
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(const Key('golden')),
      matchesGoldenFile('goldens/primitives/synced-transcript-dark.png'),
    );
  });

  group('NotionLayoutFlip', () {
    Widget flip({required bool low, required Object? trigger}) => Align(
      alignment: low ? Alignment.bottomCenter : Alignment.topCenter,
      child: NotionLayoutFlip(
        trigger: trigger,
        child: const SizedBox.square(key: Key('box'), dimension: 40),
      ),
    );

    testWidgets('glides from the old place to the new one on its trigger', (
      tester,
    ) async {
      await tester.pumpWidget(_app(flip(low: false, trigger: false)));
      final top = tester.getTopLeft(find.byKey(const Key('box'))).dy;
      await tester.pumpWidget(_app(flip(low: true, trigger: true)));
      // Laid out below, still drawn (and hit) where it was.
      expect(
        tester.getTopLeft(find.byKey(const Key('box'))).dy,
        closeTo(top, .5),
      );
      await tester.pump(NotionMotion.medium ~/ 2);
      final middle = tester.getTopLeft(find.byKey(const Key('box'))).dy;
      expect(middle, greaterThan(top + 1));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const Key('box'))).dy,
        closeTo(_height - 40, .5),
      );
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('moves without its trigger, and under reduced motion, jump', (
      tester,
    ) async {
      await tester.pumpWidget(_app(flip(low: false, trigger: 1)));
      await tester.pumpWidget(_app(flip(low: true, trigger: 1)));
      expect(
        tester.getTopLeft(find.byKey(const Key('box'))).dy,
        closeTo(_height - 40, .5),
      );
      await tester.pumpWidget(
        _app(flip(low: false, trigger: 1), reduced: true),
      );
      await tester.pumpWidget(_app(flip(low: true, trigger: 2), reduced: true));
      expect(
        tester.getTopLeft(find.byKey(const Key('box'))).dy,
        closeTo(_height - 40, .5),
      );
    });
  });
}

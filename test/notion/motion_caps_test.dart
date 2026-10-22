// SPDX-License-Identifier: AGPL-3.0-or-later
// No endless animation (DESIGN.md "Motion", PF-02): spinners and content
// loops rest on a static frame after their cap, so a wait that never ends
// stops scheduling frames.
import 'package:chatloom/personal/transcript_panel.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _app(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: NotionTheme.build(Brightness.dark),
  home: Scaffold(body: Center(child: child)),
);

/// Pumps past [cap] in steps a loop sees (a single huge pump is one frame).
Future<void> _pumpPast(WidgetTester tester, Duration cap) async {
  final steps = (cap.inMilliseconds / 500).ceil() + 4;
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

void main() {
  test('loop counts fit the cap', () {
    expect(
      NotionMotion.loopCount(const Duration(seconds: 1)),
      NotionMotion.loopCap.inSeconds,
    );
    expect(NotionMotion.loopCount(Duration.zero), 1);
  });

  testWidgets('a spinner spins, then rests after its cap', (tester) async {
    await tester.pumpWidget(_app(const NotionDelayedSpinner()));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isTrue);
    await _pumpPast(tester, NotionMotion.loopCap);
    expect(tester.binding.hasScheduledFrame, isFalse);
    // The ring is still there, frozen.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('typing dots rest after the loop cap', (tester) async {
    await tester.pumpWidget(_app(const NotionTypingDots()));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.binding.hasScheduledFrame, isTrue);
    await _pumpPast(tester, NotionMotion.loopCap);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('a pulse rests after its cap and restarts when re-enabled', (
    tester,
  ) async {
    Widget pulse(bool enabled) => _app(
      NotionPulse(
        enabled: enabled,
        maxDuration: const Duration(seconds: 4),
        child: const SizedBox.square(dimension: 40),
      ),
    );
    await tester.pumpWidget(pulse(true));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.binding.hasScheduledFrame, isTrue);
    await _pumpPast(tester, const Duration(seconds: 4));
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(pulse(false));
    await tester.pumpWidget(pulse(true));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.binding.hasScheduledFrame, isTrue);
  });

  testWidgets('shimmer rests on static bars and reports it', (tester) async {
    var rested = 0;
    await tester.pumpWidget(
      _app(
        NotionShimmerLines(
          maxDuration: const Duration(seconds: 5),
          onRest: () => rested++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.binding.hasScheduledFrame, isTrue);
    await _pumpPast(tester, const Duration(seconds: 5));
    expect(rested, 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('a long transcript wait turns calm and static', (tester) async {
    await tester.pumpWidget(
      _app(
        TranscriptBusyLines(color: const Color(0xFFFFFFFF), caption: Text.new),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(TranscriptBusyLines.longWaitText), findsNothing);
    await _pumpPast(tester, NotionMotion.loopCap);
    expect(find.text(TranscriptBusyLines.longWaitText), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
// NotionShimmerLines: the transcript placeholder (DESIGN.md "Motion").
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _app(
  Widget child, {
  bool reduced = false,
  double scale = 1,
  TextDirection direction = TextDirection.ltr,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: NotionTheme.build(Brightness.dark),
  builder: (context, app) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: reduced,
      textScaler: TextScaler.linear(scale),
    ),
    child: Directionality(textDirection: direction, child: app!),
  ),
  home: Scaffold(body: Center(child: child)),
);

Future<void> _fresh(WidgetTester tester, Widget app) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(app);
  await tester.pump();
}

void main() {
  testWidgets('shimmers, and stops under TickerMode off and reduced motion', (
    tester,
  ) async {
    const lines = NotionShimmerLines();
    await tester.pumpWidget(_app(lines));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isTrue);
    await _fresh(tester, _app(const TickerMode(enabled: false, child: lines)));
    expect(tester.binding.hasScheduledFrame, isFalse);
    await _fresh(tester, _app(lines, reduced: true));
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(find.byType(NotionShimmerLines), findsOneWidget);
  });

  testWidgets('is as tall as the text it stands in for and fits its parent', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const NotionShimmerLines()));
    final height = NotionShimmerLines.heightFor(
      TextScaler.noScaling,
      NotionType.callout,
      2,
    );
    expect(height, closeTo(2 * 15 * 1.4, .001));
    expect(
      tester.getSize(find.byType(NotionShimmerLines)),
      Size(NotionShimmerLines.defaultWidth, height),
    );
    await tester.pumpWidget(
      _app(
        const SizedBox(
          width: 120,
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: NotionShimmerLines(lines: 3),
          ),
        ),
        scale: 2,
      ),
    );
    final size = tester.getSize(find.byType(NotionShimmerLines));
    expect(size.width, 120);
    expect(
      size.height,
      closeTo(
        NotionShimmerLines.heightFor(
          const TextScaler.linear(2),
          NotionType.callout,
          3,
        ),
        .001,
      ),
    );
  });

  testWidgets('paints right to left without errors', (tester) async {
    await tester.pumpWidget(
      _app(
        const NotionShimmerLines(color: Colors.white),
        direction: TextDirection.rtl,
      ),
    );
    await tester.pump(const Duration(milliseconds: 700));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(_app(const SizedBox()));
  });
}

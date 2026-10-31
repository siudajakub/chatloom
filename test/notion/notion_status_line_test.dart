// SPDX-License-Identifier: AGPL-3.0-or-later
// NotionStatusLine: the quiet header status (busy spinner, tap to retry,
// reveal) and a golden of its resting states (DESIGN.md primitives). Run
// goldens through scripts/verify-notion-ui.py so fonts match.
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _app(Widget child, {bool reduced = false}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: NotionTheme.build(Brightness.dark),
  builder: (context, app) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
    child: app!,
  ),
  home: Scaffold(
    body: Padding(padding: NotionSpace.page, child: child),
  ),
);

void main() {
  setUpAll(() async {
    final loader = FontLoader('Roboto');
    for (final name in ['Regular', 'Medium', 'Bold']) {
      loader.addFont(rootBundle.load('assets/notion/fonts/Roboto-$name.ttf'));
    }
    await loader.load();
  });

  testWidgets('busy shows a small spinner; a tappable line retries', (
    tester,
  ) async {
    var taps = 0;
    Widget line(String? status, {bool busy = false, bool tap = false}) => _app(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Chats'),
          NotionStatusLine(
            status: status,
            busy: busy,
            onTap: tap ? () => taps++ : null,
            tapHint: 'Retry',
          ),
        ],
      ),
    );

    await tester.pumpWidget(line(null));
    expect(find.byType(NotionDelayedSpinner), findsNothing);

    await tester.pumpWidget(line('Connecting…', busy: true, tap: true));
    await tester.pump(NotionMotion.medium);
    expect(find.text('Connecting…'), findsOneWidget);
    final spinner = tester.getSize(find.byType(NotionDelayedSpinner));
    expect(spinner.width, NotionStatusLine.spinnerSize);
    // The whole width takes the tap, not only the glyphs.
    final row = tester.getRect(find.byType(NotionStatusLine));
    await tester.tapAt(Offset(row.right - 4, row.center.dy));
    expect(taps, 1);
    final semantics = find.descendant(
      of: find.byType(NotionStatusLine),
      matching: find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.liveRegion == true,
      ),
    );
    expect(
      tester.getSemantics(semantics.first),
      isSemantics(
        label: 'Connecting…',
        isButton: true,
        hasTapAction: true,
        isLiveRegion: true,
      ),
    );

    // A problem without a spinner, and one that is not a button.
    await tester.pumpWidget(line('Waiting for network…', tap: true));
    await tester.pump(NotionMotion.medium);
    expect(find.byType(NotionDelayedSpinner), findsNothing);
    await tester.pumpWidget(line('Updating…', busy: true));
    await tester.pump(NotionMotion.medium);
    await tester.tap(find.text('Updating…'));
    expect(taps, 1);

    // Clearing shrinks it away; when settled nothing (no spinner) is built.
    await tester.pumpWidget(line(null));
    await tester.pumpAndSettle();
    expect(find.text('Updating…'), findsNothing);
    expect(find.byType(NotionDelayedSpinner), findsNothing);
  });

  testWidgets('reduced motion: the text alone, no spinner', (tester) async {
    await tester.pumpWidget(
      _app(
        const NotionStatusLine(status: 'Connecting…', busy: true),
        reduced: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.byType(NotionDelayedSpinner), findsNothing);
  });

  testWidgets('the spinner rests after the loop cap', (tester) async {
    await tester.pumpWidget(
      _app(const NotionStatusLine(status: 'Connecting…', busy: true)),
    );
    // A loop that never ends would make this time out.
    await tester.pumpAndSettle(
      const Duration(seconds: 1),
      EnginePhase.sendSemanticsUpdate,
      const Duration(minutes: 2),
    );
    expect(find.byType(NotionDelayedSpinner), findsOneWidget);
  });

  testWidgets('golden: quiet states', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('golden'),
        child: _app(
          const Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: NotionSpace.md,
            children: [
              _Header('Updating…', busy: true),
              _Header('Connecting…', busy: true),
              _Header('Waiting for network…'),
            ],
          ),
        ),
      ),
    );
    // Fixed frames instead of pumpAndSettle: the spinners loop.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(
      find.byKey(const Key('golden')),
      matchesGoldenFile('goldens/primitives/status-line-dark.png'),
    );
  });
}

class _Header extends StatelessWidget {
  const _Header(this.status, {this.busy = false});

  final String status;
  final bool busy;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Chats', style: context.notion.typography.headline),
      NotionStatusLine(status: status, busy: busy),
    ],
  );
}

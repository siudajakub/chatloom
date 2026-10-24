// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _entries = <NotionMenuEntry<String>>[
  NotionMenuEntry(value: 'search', label: 'Search', icon: Icons.search),
  NotionMenuEntry(
    value: 'later',
    label: 'Send later',
    icon: Icons.schedule,
    enabled: false,
  ),
  NotionMenuEntry.divider(),
  NotionMenuEntry(
    value: 'pl',
    label: 'Polish',
    subtitle: 'Polski',
    selected: true,
  ),
  NotionMenuEntry(
    value: 'leave',
    label: 'Leave',
    icon: Icons.logout,
    destructive: true,
  ),
];

Widget _host({
  required Alignment alignment,
  required ValueChanged<String?> on,
}) => MaterialApp(
  theme: NotionTheme.build(Brightness.dark),
  home: Scaffold(
    body: Align(
      alignment: alignment,
      child: Builder(
        builder: (context) => TextButton(
          key: const ValueKey('anchor'),
          onPressed: () async =>
              on(await showNotionMenu<String>(context, entries: _entries)),
          child: const Text('Open'),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('a top anchor opens a glass menu below it; rows pop values', (
    tester,
  ) async {
    final results = <String?>[];
    await tester.pumpWidget(
      _host(alignment: Alignment.topRight, on: results.add),
    );
    await tester.tap(find.byKey(const ValueKey('anchor')));
    await tester.pumpAndSettle();
    expect(find.byType(NotionGlassPanel), findsOneWidget);
    expect(find.byType(PopupMenuItem<String>), findsNothing);
    expect(find.byType(NotionGlassMenuRow), findsNWidgets(4));
    expect(find.byType(NotionGlassDivider), findsOneWidget);
    // Below the anchor, end-aligned with it (it sits on the right).
    final anchor = tester.getRect(find.byKey(const ValueKey('anchor')));
    final panel = tester.getRect(find.byType(NotionGlassPanel));
    expect(panel.top, greaterThanOrEqualTo(anchor.bottom));
    // End-aligned, kept a gutter away from the screen edge.
    final edge = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(
      panel.right,
      closeTo(
        anchor.right < edge - NotionSpace.md
            ? anchor.right
            : edge - NotionSpace.md,
        0.5,
      ),
    );
    // The subtitle and the check of the selected row.
    expect(find.text('Polski'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    // A destructive row uses the danger colour.
    final leave = tester.widget<Text>(find.text('Leave'));
    final colors = tester.element(find.text('Leave')).notion.colors;
    expect(leave.style?.color, colors.danger);
    // A disabled row stays and does nothing.
    await tester.tap(find.text('Send later'));
    await tester.pumpAndSettle();
    expect(results, isEmpty);
    await tester.tap(find.byKey(const ValueKey('menu-Search')));
    await tester.pumpAndSettle();
    expect(results, ['search']);
    expect(find.byType(NotionGlassPanel), findsNothing);
  });

  testWidgets('a bottom anchor opens above it; Escape dismisses with null', (
    tester,
  ) async {
    final results = <String?>[];
    await tester.pumpWidget(
      _host(alignment: Alignment.bottomLeft, on: results.add),
    );
    await tester.tap(find.byKey(const ValueKey('anchor')));
    await tester.pumpAndSettle();
    final anchor = tester.getRect(find.byKey(const ValueKey('anchor')));
    final panel = tester.getRect(find.byType(NotionGlassPanel));
    expect(panel.bottom, lessThanOrEqualTo(anchor.top));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(NotionGlassPanel), findsNothing);
    expect(results, [null]);
  });

  testWidgets('NotionMenuButton shows its open state and reports a choice', (
    tester,
  ) async {
    final chosen = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: Scaffold(
          appBar: AppBar(
            actions: [
              NotionMenuButton<String>(
                icon: Icons.more_horiz,
                label: 'Options',
                entries: () => _entries,
                onSelected: chosen.add,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Options'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<NotionIconButton>(find.byType(NotionIconButton)).selected,
      isTrue,
    );
    await tester.tap(find.text('Leave'));
    await tester.pumpAndSettle();
    expect(chosen, ['leave']);
    expect(
      tester.widget<NotionIconButton>(find.byType(NotionIconButton)).selected,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline widget tests of the lazy row motion (PF-13); fictional rows only.
import 'package:chatloom/personal/ui/notion_inbox_row.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _app(Widget child, {bool reduced = false}) => MaterialApp(
  theme: NotionTheme.build(Brightness.dark),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: Scaffold(body: child),
  ),
);

NotionInboxRow _row(
  int i, {
  String preview = 'Fictional preview',
  bool selected = false,
  int unread = 0,
  bool mentioned = false,
  bool muted = false,
  bool failed = false,
}) => NotionInboxRow(
  key: ValueKey('row-$i'),
  avatar: const SizedBox.shrink(),
  name: 'Fictional chat $i',
  preview: preview,
  time: '12:00',
  unreadCount: unread,
  mentioned: mentioned,
  muted: muted,
  failed: failed,
  selected: selected,
  onTap: () {},
);

void main() {
  testWidgets('rows create no switcher controllers until something changes', (
    tester,
  ) async {
    final before = NotionLazySwitcher.debugControllers;
    await tester.pumpWidget(
      _app(
        ListView(
          children: [for (var i = 0; i < 12; i++) _row(i, unread: i % 3)],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(NotionLazySwitcher.debugControllers, before);
    // A new preview cross-fades: two controllers for that row only.
    await tester.pumpWidget(
      _app(
        ListView(
          children: [
            for (var i = 0; i < 12; i++)
              _row(
                i,
                unread: i % 3,
                preview: i == 0 ? 'Newer fictional line' : 'Fictional preview',
              ),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(NotionLazySwitcher.debugControllers, before + 2);
    // Both lines are painted while they cross-fade, then only the new one.
    expect(find.text('Newer fictional line'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Newer fictional line'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('row-0')),
        matching: find.text('Fictional preview'),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a swap under reduced motion is instant', (tester) async {
    final before = NotionLazySwitcher.debugControllers;
    await tester.pumpWidget(
      _app(const NotionLazySwitcher(child: Text('One', key: ValueKey(1)))),
    );
    await tester.pumpWidget(
      _app(
        const NotionLazySwitcher(child: Text('Two', key: ValueKey(2))),
        reduced: true,
      ),
    );
    await tester.pump();
    expect(find.text('One'), findsNothing);
    expect(find.text('Two'), findsOneWidget);
    expect(NotionLazySwitcher.debugControllers, before);
  });

  testWidgets('mention stays accent in a muted chat; a failed send is marked', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(_row(1, unread: 2, mentioned: true, muted: true, failed: true)),
    );
    await tester.pumpAndSettle();
    final badge = tester.widget<Container>(
      find.byKey(const ValueKey('notion_inbox_mention')),
    );
    final context = tester.element(find.byType(NotionInboxRow));
    expect(
      (badge.decoration! as BoxDecoration).color,
      context.notion.palette.accentFill,
    );
    expect(find.byKey(const ValueKey('notion_inbox_failed')), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        RegExp('Last message not sent, You were mentioned, 2 unread messages'),
      ),
      findsOneWidget,
    );
    // A mention alone (no count) shows the "@" badge by itself.
    await tester.pumpWidget(_app(_row(1, mentioned: true)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('notion_inbox_mention')), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('selection tweens lazily and settles on the selected colour', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_row(1)));
    await tester.pumpWidget(_app(_row(1, selected: true)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(_app(_row(1)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

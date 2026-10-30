// SPDX-License-Identifier: AGPL-3.0-or-later
// Pinned chats as an even grid of avatar bubbles (wave 13) and their drag
// reorder. Fictional offline fixtures.
import 'package:chatloom/personal/ui/notion_inbox_pins.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _names = ['Anna', 'Team', 'Mia', 'Jan', 'Ola', 'Piotr'];

NotionPinnedShortcut _pin(
  String name,
  int order, {
  VoidCallback? menu,
  VoidCallback? tap,
  int unreadCount = 0,
  bool muted = false,
}) => NotionPinnedShortcut(
  name: name,
  id: 'entity-$name',
  avatar: NotionInitialAvatar(name: name, size: notionPinnedAvatarSize),
  onTap: tap ?? () {},
  onLongPress: menu,
  order: order,
  unreadCount: unreadCount,
  muted: muted,
);

/// The pins over a scrolling inbox, as `NotionInboxPage` mounts them
/// (20 dp gutters, rows below, the chat list's unfocus tap detector).
Widget _inbox(
  Widget pins, {
  ScrollController? scroll,
  bool reduced = false,
  double width = 412,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: NotionTheme.build(Brightness.dark),
  home: MediaQuery(
    data: MediaQueryData(size: Size(width, 800), disableAnimations: reduced),
    child: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: GestureDetector(
            onTap: () {},
            behavior: HitTestBehavior.translucent,
            child: CustomScrollView(
              controller: scroll,
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    child: pins,
                  ),
                ),
                SliverList.builder(
                  itemCount: 40,
                  itemBuilder: (context, i) =>
                      SizedBox(height: 56, child: Text('Row $i')),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  ),
);

Offset _at(WidgetTester tester, String name) =>
    tester.getCenter(find.text(name));

void main() {
  setUp(() => NotionHaptics.enabled = false);
  tearDown(() => NotionHaptics.enabled = true);

  test('columns: five on a 412 dp phone, four on 360, at least four', () {
    expect(notionPinnedColumns(412 - 40), 5);
    expect(notionPinnedColumns(360 - 40), 4);
    expect(notionPinnedColumns(320 - 40), 4);
    expect(notionPinnedColumns(900), 12);
    expect(notionPinnedColumns(150), 2);
  });

  testWidgets('an even grid of equal bubbles that wraps', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _inbox(
        NotionPinnedShortcuts(
          pins: [
            for (final (i, name) in _names.indexed)
              _pin(name, i, unreadCount: i == 1 ? 3 : 0, muted: i == 2),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final avatars = find.byType(NotionInitialAvatar);
    expect(avatars, findsNWidgets(6));
    final sizes = {for (var i = 0; i < 6; i++) tester.getSize(avatars.at(i))};
    expect(sizes, {const Size.square(notionPinnedAvatarSize)});
    // Five across, the sixth starts the second row under the first.
    final first = _at(tester, 'Anna');
    for (final name in _names.take(5)) {
      expect(_at(tester, name).dy, first.dy);
    }
    expect(_at(tester, 'Piotr').dx, first.dx);
    expect(_at(tester, 'Piotr').dy, greaterThan(first.dy));
    final gaps = [
      for (var i = 1; i < 5; i++)
        _at(tester, _names[i]).dx - _at(tester, _names[i - 1]).dx,
    ];
    for (final gap in gaps) {
      expect(gap, moreOrLessEquals(gaps.first));
    }
    // The unread count is on Team's bubble.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('notion_pinned_badge')),
        matching: find.text('3'),
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Pinned chat, Team, 3 unread messages'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Pinned chat, Mia, Notifications limited'),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('a long press without moving opens the menu, a tap the chat', (
    tester,
  ) async {
    var menus = 0;
    var taps = 0;
    final orders = <List<String>>[];
    await tester.pumpWidget(
      _inbox(
        NotionPinnedShortcuts(
          pins: [
            for (final (i, name) in _names.take(3).indexed)
              _pin(name, i, menu: () => menus++, tap: () => taps++),
          ],
          onReorder: (keys) async => orders.add(keys),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anna'));
    await tester.pumpAndSettle();
    expect((taps, menus), (1, 0));

    final still = await tester.startGesture(_at(tester, 'Anna'));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    // Lifted: scaled up under the finger.
    final lifted = tester.widget<AnimatedScale>(
      find
          .descendant(
            of: find.byKey(const ValueKey('entity-Anna')),
            matching: find.byType(AnimatedScale),
          )
          .first,
    );
    expect(lifted.scale, greaterThan(1));
    await still.up();
    await tester.pumpAndSettle();
    expect((taps, menus), (1, 1));
    expect(orders, isEmpty);
  });

  testWidgets('long press and drag reorders; neighbours slide; inbox stays', (
    tester,
  ) async {
    var menus = 0;
    var taps = 0;
    final orders = <List<String>>[];
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    // The inbox rebuilds with new pin objects while the finger is down.
    var generation = 0;
    Widget build() => _inbox(
      NotionPinnedShortcuts(
        key: const ValueKey('pins'),
        pins: [
          for (final (i, name) in _names.take(4).indexed)
            _pin(
              name,
              i,
              menu: () => menus++,
              tap: () => taps++,
              unreadCount: generation,
            ),
        ],
        onReorder: (keys) async => orders.add(keys),
      ),
      scroll: scroll,
    );
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    final anna = _at(tester, 'Anna');
    final team = _at(tester, 'Team');
    final mia = _at(tester, 'Mia');
    final jan = _at(tester, 'Jan');
    State<StatefulWidget> teamState() => tester.state(
      find.descendant(
        of: find.byKey(const ValueKey('entity-Team')),
        matching: find.byType(NotionPressable),
      ),
    );
    final teamBefore = teamState();

    final drag = await tester.startGesture(anna);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    // Diagonal on the way, as a real finger: the inbox must not scroll.
    await drag.moveBy(const Offset(10, 30));
    await tester.pump();
    for (var i = 1; i <= 6; i++) {
      await drag.moveTo(Offset.lerp(anna, mia, i / 6)!);
      generation++;
      await tester.pumpWidget(build());
    }
    // Over Mia's slot: Team and Mia glide one place to the start.
    await tester.pump(NotionMotion.medium ~/ 3);
    final teamMid = _at(tester, 'Team').dx;
    expect(teamMid, lessThan(team.dx));
    expect(teamMid, greaterThan(anna.dx));
    await tester.pumpAndSettle();
    expect(_at(tester, 'Team').dx, moreOrLessEquals(anna.dx));
    expect(_at(tester, 'Mia').dx, moreOrLessEquals(team.dx));
    // The lifted bubble follows the finger.
    expect(_at(tester, 'Anna').dx, moreOrLessEquals(mia.dx, epsilon: 1));
    expect(scroll.offset, 0);
    expect(orders, isEmpty);

    await drag.up();
    await tester.pumpAndSettle();
    expect(orders, [
      ['entity-Team', 'entity-Mia', 'entity-Anna', 'entity-Jan'],
    ]);
    expect((taps, menus), (0, 0));
    // The new order is shown at once and Anna settles into Mia's old slot.
    expect(_at(tester, 'Anna').dx, moreOrLessEquals(mia.dx));
    expect(_at(tester, 'Jan').dx, moreOrLessEquals(jan.dx));
    expect(scroll.offset, 0);
    // Moved bubbles keep their elements (no avatar reload, focus kept).
    expect(identical(teamState(), teamBefore), isTrue);
  });

  testWidgets('a plain vertical drag over the grid scrolls the inbox', (
    tester,
  ) async {
    final orders = <List<String>>[];
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      _inbox(
        NotionPinnedShortcuts(
          pins: [for (final (i, n) in _names.indexed) _pin(n, i)],
          onReorder: (keys) async => orders.add(keys),
        ),
        scroll: scroll,
      ),
    );
    await tester.pumpAndSettle();
    await tester.dragFrom(_at(tester, 'Team'), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(100));
    expect(orders, isEmpty);
  });

  testWidgets('a mouse drags directly; a click still opens the chat', (
    tester,
  ) async {
    var taps = 0;
    final orders = <List<String>>[];
    await tester.pumpWidget(
      _inbox(
        NotionPinnedShortcuts(
          pins: [
            for (final (i, n) in _names.take(3).indexed)
              _pin(n, i, tap: () => taps++),
          ],
          onReorder: (keys) async => orders.add(keys),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final anna = _at(tester, 'Anna');
    final mia = _at(tester, 'Mia');
    final mouse = await tester.startGesture(
      anna,
      kind: PointerDeviceKind.mouse,
    );
    for (var i = 1; i <= 8; i++) {
      await mouse.moveTo(Offset.lerp(anna, mia, i / 8)!);
      await tester.pump();
    }
    await mouse.up();
    await tester.pumpAndSettle();
    expect(orders, [
      ['entity-Team', 'entity-Mia', 'entity-Anna'],
    ]);
    expect(taps, 0);
    await tester.tap(find.text('Mia'), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('Alt+arrow moves a focused bubble; failures roll back', (
    tester,
  ) async {
    final orders = <List<String>>[];
    var fail = false;
    await tester.pumpWidget(
      _inbox(
        NotionPinnedShortcuts(
          pins: [for (final (i, n) in _names.take(3).indexed) _pin(n, i)],
          onReorder: (keys) {
            orders.add(keys);
            return fail
                ? Future<void>.error(StateError('offline'))
                : Future<void>.value();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final anna = _at(tester, 'Anna');
    final team = _at(tester, 'Team');
    Focus.of(tester.element(find.text('Anna'))).requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(orders.last, ['entity-Team', 'entity-Anna', 'entity-Mia']);
    expect(_at(tester, 'Anna').dx, moreOrLessEquals(team.dx));
    // Still focused after the move (keyed slot, same element).
    expect(Focus.of(tester.element(find.text('Anna'))).hasPrimaryFocus, isTrue);

    // The store refuses: the stored order comes back.
    fail = true;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(orders.last, ['entity-Team', 'entity-Mia', 'entity-Anna']);
    expect(_at(tester, 'Anna').dx, moreOrLessEquals(anna.dx));
  });

  testWidgets('reduced motion: neighbours jump to their slots', (tester) async {
    await tester.pumpWidget(
      _inbox(
        NotionPinnedShortcuts(
          pins: [for (final (i, n) in _names.take(3).indexed) _pin(n, i)],
          onReorder: (_) async {},
        ),
        reduced: true,
      ),
    );
    await tester.pumpAndSettle();
    final anna = _at(tester, 'Anna');
    final mia = _at(tester, 'Mia');
    final drag = await tester.startGesture(anna);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    for (var i = 1; i <= 4; i++) {
      await drag.moveTo(Offset.lerp(anna, mia, i / 4)!);
      await tester.pump();
    }
    // No glide: Team is already in Anna's slot on the next frame.
    expect(_at(tester, 'Team').dx, moreOrLessEquals(anna.dx));
    await drag.up();
    await tester.pump();
    expect(_at(tester, 'Anna').dx, moreOrLessEquals(mia.dx));
  });

  testWidgets('a pin removed under the finger ends the drag', (tester) async {
    final orders = <List<String>>[];
    Widget build(int count) => _inbox(
      NotionPinnedShortcuts(
        key: const ValueKey('pins'),
        pins: [for (final (i, n) in _names.take(count).indexed) _pin(n, i)],
        onReorder: (keys) async => orders.add(keys),
      ),
    );
    await tester.pumpWidget(build(3));
    await tester.pumpAndSettle();
    final anna = _at(tester, 'Anna');
    final drag = await tester.startGesture(anna);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await drag.moveTo(_at(tester, 'Team'));
    await tester.pump();
    await tester.pumpWidget(build(2));
    await drag.moveTo(_at(tester, 'Team'));
    await drag.up();
    await tester.pumpAndSettle();
    expect(orders, isEmpty);
    expect(_at(tester, 'Anna').dx, moreOrLessEquals(anna.dx));
  });
}

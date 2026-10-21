// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _app(Widget child, {bool reduced = false}) => MaterialApp(
  theme: NotionTheme.build(Brightness.dark),
  home: MediaQuery(
    data: MediaQueryData(
      size: const Size(400, 800),
      disableAnimations: reduced,
    ),
    child: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  test('tokens: entrance covers every staggered emoji; keys normalize', () {
    final total = NotionReactions.barEntrance(7);
    expect(
      total,
      greaterThanOrEqualTo(
        NotionReactions.emojiStart(6) + NotionReactions.bouncyCurve.duration,
      ),
    );
    // Stagger never runs past the cap.
    expect(
      NotionReactions.emojiStart(40),
      NotionReactions.emojiStart(NotionMotion.staggerCap),
    );
    expect(NotionReactions.normalize('❤️'), NotionReactions.normalize('❤'));
    expect(NotionReactions.defaults.first, '❤️');
    expect(NotionReactionBar.slotAt(const Offset(4 + 44.0 * 2 + 3, 20), 7), 2);
    expect(NotionReactionBar.slotAt(const Offset(2, 20), 7), isNull);
    expect(NotionReactionBar.slotAt(const Offset(60, -30), 7), isNull);
    expect(NotionReactionBar.slotAt(const Offset(60, -30), 7, slop: 40), 1);
  });

  testWidgets('chip is a pill, own chips are marked, taps reach the callback', (
    tester,
  ) async {
    var taps = 0;
    var holds = 0;
    await tester.pumpWidget(
      _app(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            NotionReactionChip(
              key: const ValueKey('own'),
              emoji: const Text('❤️'),
              semanticLabel: '❤️, 2 reactions',
              count: 2,
              own: true,
              ring: Colors.transparent,
              onTap: () => taps++,
              onLongPress: () => holds++,
            ),
            const NotionReactionChip(
              key: ValueKey('other'),
              emoji: Text('😂'),
              semanticLabel: '😂, 1 reactions',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final own = tester.widget<Material>(
      find
          .descendant(
            of: find.byKey(const ValueKey('own')),
            matching: find.byType(Material),
          )
          .first,
    );
    final other = tester.widget<Material>(
      find
          .descendant(
            of: find.byKey(const ValueKey('other')),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(own.shape, isA<StadiumBorder>());
    expect((own.shape! as StadiumBorder).side, isNot(BorderSide.none));
    expect((other.shape! as StadiumBorder).side, BorderSide.none);
    expect(own.color, isNot(other.color));
    // Count only from two reactions on.
    expect(find.text('2'), findsOneWidget);
    expect(find.text('1'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('own')));
    await tester.longPress(find.byKey(const ValueKey('own')));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(holds, 1);
    expect(
      tester.getSize(find.byKey(const ValueKey('own'))).height,
      NotionReactions.chipHeight,
    );
  });

  testWidgets(
    'bar entrance springs and settles to identity; reduced is static',
    (tester) async {
      final selected = <String>[];
      for (final reduced in [false, true]) {
        final controller = AnimationController(
          vsync: tester,
          duration: reduced
              ? Duration.zero
              : NotionReactions.barEntrance(
                  NotionReactions.defaults.length + 1,
                ),
        );
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          _app(
            NotionReactionBar(
              reactions: NotionReactions.defaults,
              selected: const {'❤'},
              entrance: controller,
              onSelected: selected.add,
              onMore: () => selected.add('more'),
            ),
            reduced: reduced,
          ),
        );
        controller.forward();
        await tester.pump();
        if (!reduced) {
          await tester.pump(const Duration(milliseconds: 60));
          // Mid-entrance something is scaled.
          expect(
            tester
                .widgetList<Transform>(find.byType(Transform))
                .any((t) => t.transform.storage[0] < .99),
            isTrue,
          );
        }
        await tester.pumpAndSettle();
        // At rest no scale is left behind on the bar or its emoji.
        expect(
          tester
              .widgetList<Transform>(
                find.descendant(
                  of: find.byType(NotionReactionBar),
                  matching: find.byType(Transform),
                ),
              )
              .every((t) => (t.transform.storage[0] - 1).abs() < 1e-6),
          isTrue,
        );
        expect(find.byType(NotionGlassPanel), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('reaction-😮')));
        await tester.tap(find.byKey(const ValueKey('reaction-more')));
        await tester.pumpAndSettle();
      }
      expect(selected, ['😮', 'more', '😮', 'more']);
    },
  );

  testWidgets('hovered emoji grows above the bar and returns', (tester) async {
    Widget bar(int? hovered) => _app(
      NotionReactionBar(
        reactions: NotionReactions.defaults,
        hovered: hovered,
        onSelected: (_) {},
      ),
    );
    await tester.pumpWidget(bar(null));
    final rest = tester.getRect(find.text('😂'));
    await tester.pumpWidget(bar(1));
    await tester.pumpAndSettle();
    final hovered = tester.getRect(find.text('😂'));
    expect(hovered.height, greaterThan(rest.height * 1.3));
    expect(hovered.center.dy, lessThan(rest.center.dy));
    await tester.pumpWidget(bar(null));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('😂')), rest);
  });

  testWidgets('overlap lifts chips over the edge above and keeps their taps', (
    tester,
  ) async {
    var bubbleTaps = 0;
    var chipTaps = 0;
    await tester.pumpWidget(
      _app(
        SizedBox(
          width: 200,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: () => bubbleTaps++,
                child: const SizedBox(
                  key: ValueKey('bubble'),
                  width: 200,
                  height: 60,
                  child: ColoredBox(color: Color(0xFF414141)),
                ),
              ),
              NotionReactionOverlap(
                child: NotionReactionChip(
                  key: const ValueKey('chip'),
                  emoji: const Text('👍'),
                  semanticLabel: '👍, 1 reactions',
                  onTap: () => chipTaps++,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final bubble = tester.getRect(find.byKey(const ValueKey('bubble')));
    final chip = tester.getRect(find.byKey(const ValueKey('chip')));
    expect(chip.top, closeTo(bubble.bottom - NotionReactions.overlap, .01));
    // The upper part of the chip, painted over the bubble, is the chip's.
    await tester.tapAt(Offset(chip.center.dx, chip.top + 2));
    await tester.pumpAndSettle();
    expect(chipTaps, 1);
    expect(bubbleTaps, 0);
    // Beside the chip the bubble still takes taps.
    await tester.tapAt(Offset(bubble.right - 10, bubble.bottom - 3));
    await tester.pumpAndSettle();
    expect(bubbleTaps, 1);
    final column = tester.getSize(find.byType(Column).last);
    expect(
      column.height,
      closeTo(60 + chip.height - NotionReactions.overlap, .01),
    );
  });

  testWidgets('burst pops, rises and ends invisible', (tester) async {
    final controller = AnimationController(
      vsync: tester,
      duration: NotionReactions.burst,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(NotionReactionBurst(animation: controller, child: const Text('❤️'))),
    );
    final start = tester.getRect(find.text('❤️'));
    controller.forward();
    await tester.pump();
    await tester.pump(NotionReactions.burst * .5);
    final middle = tester.getRect(find.text('❤️'));
    expect(middle.center.dy, lessThan(start.center.dy));
    await tester.pumpAndSettle();
    final opacity = tester.widget<Opacity>(
      find.descendant(
        of: find.byType(NotionReactionBurst),
        matching: find.byType(Opacity),
      ),
    );
    expect(opacity.opacity, 0);
  });

  testWidgets('narrow screens shrink the cells instead of overflowing', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        NotionReactionBar(
          reactions: NotionReactions.defaults,
          slot: 40,
          onSelected: (_) {},
          onMore: () {},
        ),
      ),
    );
    expect(
      tester.getSize(find.byType(NotionReactionBar)).width,
      7 * 40 + 2 * NotionReactions.barPadding,
    );
    expect(tester.takeException(), isNull);
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
//
// NotionListMotion (DESIGN.md "Motion"): a row whose position changed glides
// from its old place without a jump, new rows fade in, scrolling and
// epoch/reduced-motion changes never animate, everything settles exactly
// and the list goes idle.
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _rowHeight = 60.0;

// One theme instance: a rebuilt ThemeData would start AnimatedTheme.
final _theme = NotionTheme.build(Brightness.dark);

Widget _list(
  List<String> ids, {
  Object? epoch,
  bool reduced = false,
  ScrollController? controller,
  ValueChanged<String>? onTap,
  Color? background,
}) {
  final positions = {for (final (i, id) in ids.indexed) id: i};
  return MaterialApp(
    theme: _theme,
    builder: (context, app) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: app!,
    ),
    home: Scaffold(
      body: NotionListMotion(
        order: ids,
        epoch: epoch,
        background: background,
        child: CustomScrollView(
          controller: controller,
          slivers: [
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => NotionListMotionItem(
                  key: ValueKey(ids[index]),
                  index: index,
                  child: GestureDetector(
                    onTap: () => onTap?.call(ids[index]),
                    child: SizedBox(
                      height: _rowHeight,
                      child: Text(ids[index]),
                    ),
                  ),
                ),
                childCount: ids.length,
                addRepaintBoundaries: false,
                addSemanticIndexes: false,
                findChildIndexCallback: (key) =>
                    key is ValueKey<String> ? positions[key.value] : null,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

double _y(WidgetTester tester, String id) =>
    tester.getTopLeft(find.text(id)).dy;

Iterable<OpacityLayer> _fades(WidgetTester tester) => tester.layers
    .whereType<OpacityLayer>()
    .where((l) => (l.alpha ?? 255) < 255);

void main() {
  testWidgets('a moved row glides from its old place and settles', (
    tester,
  ) async {
    await tester.pumpWidget(_list(['a', 'b', 'c', 'd']));
    expect(_y(tester, 'd'), 3 * _rowHeight);

    await tester.pumpWidget(_list(['d', 'a', 'b', 'c']));
    // The frame of the change still shows every row where it was.
    expect(_y(tester, 'd'), 3 * _rowHeight);
    expect(_y(tester, 'a'), 0);
    expect(_y(tester, 'c'), 2 * _rowHeight);

    await tester.pump(const Duration(milliseconds: 60));
    final d = _y(tester, 'd');
    final a = _y(tester, 'a');
    expect(d, inExclusiveRange(0, 3 * _rowHeight));
    expect(a, inExclusiveRange(0, _rowHeight));

    await tester.pumpAndSettle();
    expect(_y(tester, 'd'), 0);
    expect(_y(tester, 'a'), _rowHeight);
    expect(_y(tester, 'c'), 3 * _rowHeight);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('positions move monotonically, never past the target', (
    tester,
  ) async {
    await tester.pumpWidget(_list(['a', 'b', 'c', 'd']));
    await tester.pumpWidget(_list(['d', 'a', 'b', 'c']));
    var last = _y(tester, 'd');
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 8));
      final y = _y(tester, 'd');
      expect(y, lessThanOrEqualTo(last));
      expect(y, greaterThanOrEqualTo(0));
      last = y;
    }
    await tester.pumpAndSettle();
  });

  testWidgets('a change mid-flight continues from where the row is', (
    tester,
  ) async {
    await tester.pumpWidget(_list(['a', 'b', 'c', 'd']));
    await tester.pumpWidget(_list(['d', 'a', 'b', 'c']));
    await tester.pump(const Duration(milliseconds: 50));
    final before = _y(tester, 'a');
    // Another chat jumps to the top: 'a' moves once more, from where it is.
    await tester.pumpWidget(_list(['c', 'd', 'a', 'b']));
    expect(_y(tester, 'a'), moreOrLessEquals(before, epsilon: .01));
    await tester.pumpAndSettle();
    expect(_y(tester, 'a'), 2 * _rowHeight);
    expect(_y(tester, 'c'), 0);
  });

  testWidgets('removed rows close the gap smoothly', (tester) async {
    await tester.pumpWidget(_list(['a', 'b', 'c', 'd']));
    await tester.pumpWidget(_list(['a', 'c', 'd']));
    expect(_y(tester, 'c'), 2 * _rowHeight);
    await tester.pump(const Duration(milliseconds: 60));
    expect(_y(tester, 'c'), inExclusiveRange(_rowHeight, 2 * _rowHeight));
    await tester.pumpAndSettle();
    expect(_y(tester, 'c'), _rowHeight);
    expect(_y(tester, 'd'), 2 * _rowHeight);
  });

  testWidgets('a new row fades in, the rest slide down', (tester) async {
    await tester.pumpWidget(_list(['a', 'b']));
    expect(_fades(tester), isEmpty);
    await tester.pumpWidget(_list(['n', 'a', 'b']));
    expect(_fades(tester), isNotEmpty);
    expect(_y(tester, 'a'), 0);
    await tester.pumpAndSettle();
    expect(_fades(tester), isEmpty);
    expect(_y(tester, 'n'), 0);
    expect(_y(tester, 'a'), _rowHeight);
  });

  testWidgets('a new epoch swaps the list without motion', (tester) async {
    await tester.pumpWidget(_list(['a', 'b', 'c', 'd'], epoch: 1));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_list(['d', 'x', 'a', 'b'], epoch: 2));
    expect(_y(tester, 'd'), 0);
    expect(_y(tester, 'a'), 2 * _rowHeight);
    expect(_fades(tester), isEmpty);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('reduced motion reorders instantly', (tester) async {
    await tester.pumpWidget(_list(['a', 'b', 'c', 'd'], reduced: true));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_list(['d', 'a', 'b', 'c', 'n'], reduced: true));
    expect(_y(tester, 'd'), 0);
    expect(_y(tester, 'a'), _rowHeight);
    expect(_fades(tester), isEmpty);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('scrolling never animates rows', (tester) async {
    final ids = [for (var i = 0; i < 60; i++) 'r$i'];
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_list(ids, controller: controller));
    controller.jumpTo(20 * _rowHeight);
    await tester.pump();
    expect(_y(tester, 'r20'), 0);
    expect(_fades(tester), isEmpty);
    await tester.fling(find.text('r22'), const Offset(0, 400), 2000);
    await tester.pumpAndSettle();
    for (final id in ['r10', 'r12']) {
      final finder = find.text(id);
      if (finder.evaluate().isEmpty) continue;
      // Painted exactly at its layout position.
      expect(
        _y(tester, id),
        moreOrLessEquals(
          ids.indexOf(id) * _rowHeight - controller.offset,
          epsilon: .01,
        ),
      );
    }
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('a row off screen during a change scrolls in at rest', (
    tester,
  ) async {
    final ids = [for (var i = 0; i < 30; i++) 'r$i'];
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_list(ids, controller: controller));
    // r10 is painted, then scrolled into the cache extent below the screen.
    controller.jumpTo(2 * _rowHeight);
    await tester.pump();
    expect(find.text('r10'), findsOneWidget);
    controller.jumpTo(0);
    await tester.pump();
    await tester.pumpWidget(_list(['n', ...ids], controller: controller));
    await tester.pumpAndSettle();
    // Brought back by scrolling: drawn exactly at its new place.
    controller.jumpTo(3 * _rowHeight);
    await tester.pump();
    expect(_y(tester, 'r10'), 8 * _rowHeight);
    await tester.pump(const Duration(milliseconds: 50));
    expect(_y(tester, 'r10'), 8 * _rowHeight);
  });

  testWidgets('taps reach the row where it is drawn', (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(_list(['a', 'b', 'c', 'd'], onTap: tapped.add));
    await tester.pumpWidget(_list(['d', 'a', 'b', 'c'], onTap: tapped.add));
    // 'd' is still drawn in the last slot on the frame of the change.
    await tester.tapAt(const Offset(10, 3 * _rowHeight + 10));
    await tester.pumpAndSettle();
    expect(tapped, ['d']);
  });

  testWidgets('a moving row covers what it passes with the background', (
    tester,
  ) async {
    const page = Color(0xFF101010);
    await tester.pumpWidget(_list(['a', 'b', 'c'], background: page));
    await tester.pumpWidget(_list(['c', 'a', 'b'], background: page));
    final slot = tester.renderObject(
      find.ancestor(
        of: find.text('a'),
        matching: find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_ListMotionSlot',
        ),
      ),
    );
    expect(slot, paints..rect(color: page));
    await tester.pumpAndSettle();
    expect(slot, isNot(paints..rect(color: page)));
  });

  testWidgets('rows only move while they glide: no rebuild, no relayout', (
    tester,
  ) async {
    await tester.pumpWidget(_list(['a', 'b', 'c', 'd']));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_list(['d', 'a', 'b', 'c']));
    final rebuilt = <Type>[];
    var layouts = 0;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (builtOnce) rebuilt.add(element.widget.runtimeType);
    };
    final text = tester.renderObject<RenderBox>(find.text('a'));
    final size = text.size;
    try {
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 8));
        if (text.debugNeedsLayout) layouts++;
      }
    } finally {
      debugOnRebuildDirtyWidget = null;
    }
    expect(rebuilt, isEmpty);
    expect(layouts, 0);
    expect(text.size, size);
    await tester.pumpAndSettle();
  });

  testWidgets('outside a NotionListMotion an item is a plain boundary', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: NotionListMotionItem(index: 0, child: Text('alone')),
      ),
    );
    expect(find.text('alone'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
  });
}

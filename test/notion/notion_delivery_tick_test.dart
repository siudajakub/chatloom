// SPDX-License-Identifier: AGPL-3.0-or-later
// NotionDeliveryTick: glyph and colour per state, semantics, a quiet
// in-place change and a golden of the resting states (DESIGN.md
// primitives). Run goldens through scripts/verify-notion-ui.py so fonts
// match.
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _app(Widget child, {Brightness brightness = Brightness.dark}) =>
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: NotionTheme.build(brightness),
      home: Scaffold(body: Center(child: child)),
    );

Icon _icon(WidgetTester tester) => tester.widget<Icon>(
  find.descendant(
    of: find.byType(NotionDeliveryTick),
    matching: find.byType(Icon),
  ),
);

void main() {
  testWidgets('glyph and colour per state; only "read" takes the accent', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    for (final (state, glyph) in [
      (NotionDeliveryState.sending, Icons.schedule),
      (NotionDeliveryState.sent, Icons.done),
      (NotionDeliveryState.delivered, Icons.done_all),
      (NotionDeliveryState.read, Icons.done_all),
    ]) {
      await tester.pumpWidget(
        _app(NotionDeliveryTick(key: ValueKey(state), state: state)),
      );
      final context = tester.element(find.byType(NotionDeliveryTick));
      final colors = context.notion.colors;
      final icon = _icon(tester);
      expect(icon.icon, glyph, reason: '$state');
      expect(
        icon.color,
        state == NotionDeliveryState.read
            ? colors.accent
            : colors.textSecondary,
        reason: '$state',
      );
      expect(
        find.bySemanticsLabel(NotionDeliveryTick.labelOf(state)),
        findsOneWidget,
      );
    }
    semantics.dispose();
  });

  testWidgets('custom colours win; size is fixed for every state', (
    tester,
  ) async {
    const muted = Color(0xFF808080);
    const accent = Color(0xFF3366FF);
    await tester.pumpWidget(
      _app(
        const NotionDeliveryTick(
          state: NotionDeliveryState.read,
          color: muted,
          readColor: accent,
        ),
      ),
    );
    expect(_icon(tester).color, accent);
    expect(
      tester.getSize(find.byType(NotionDeliveryTick)),
      const Size.square(NotionDeliveryTick.defaultSize),
    );
    await tester.pumpWidget(
      _app(
        const NotionDeliveryTick(
          state: NotionDeliveryState.sent,
          color: muted,
          readColor: accent,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_icon(tester).color, muted);
    expect(
      tester.getSize(find.byType(NotionDeliveryTick)),
      const Size.square(NotionDeliveryTick.defaultSize),
    );
  });

  testWidgets('first build costs no controller; a change fades once', (
    tester,
  ) async {
    final before = NotionLazySwitcher.debugControllers;
    await tester.pumpWidget(
      _app(const NotionDeliveryTick(state: NotionDeliveryState.sent)),
    );
    expect(NotionLazySwitcher.debugControllers, before);
    await tester.pumpWidget(
      _app(const NotionDeliveryTick(state: NotionDeliveryState.delivered)),
    );
    expect(NotionLazySwitcher.debugControllers, greaterThan(before));
    await tester.pumpAndSettle();
    expect(_icon(tester).icon, Icons.done_all);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('resting states golden', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 120);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('golden'),
        child: _app(
          Builder(
            builder: (context) => Wrap(
              spacing: NotionSpace.md,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final state in NotionDeliveryState.values)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: NotionSpace.xxs,
                    children: [
                      Text('12:30', style: context.notion.typography.caption),
                      NotionDeliveryTick(state: state),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const Key('golden')),
      matchesGoldenFile('goldens/primitives/delivery-ticks-dark.png'),
    );
  });
}

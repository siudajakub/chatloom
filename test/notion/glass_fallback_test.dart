// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Fill colours of the glass decorations below [finder].
List<Color> _fills(WidgetTester tester, Finder finder) => tester
    .widgetList<DecoratedBox>(
      find.descendant(of: finder, matching: find.byType(DecoratedBox)),
    )
    .map((box) => box.decoration)
    .whereType<BoxDecoration>()
    .map((d) => d.color)
    .whereType<Color>()
    .toList();

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('fallback paints the glass tone over the page ($brightness)', (
      tester,
    ) async {
      late NotionTokens tokens;
      await tester.pumpWidget(
        MaterialApp(
          theme: NotionTheme.build(brightness),
          home: NotionGlassScope(
            mode: NotionGlassMode.off,
            child: Builder(
              builder: (context) {
                tokens = context.notion;
                return Column(
                  children: [
                    NotionGlassSurface(
                      key: const ValueKey('dock'),
                      dock: true,
                      borderRadius: NotionGlass.dockRadius,
                      child: const SizedBox(width: 100, height: 40),
                    ),
                    const NotionGlassBar(
                      key: ValueKey('bar'),
                      child: SizedBox(width: 100, height: 40),
                    ),
                    const NotionGlassPill(
                      key: ValueKey('pill'),
                      icon: Icons.search,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
      final page = tokens.colors.background;
      final glass = tokens.glass;
      expect(
        _fills(tester, find.byKey(const ValueKey('dock'))).first,
        Color.alphaBlend(glass.dockTint, page),
      );
      expect(
        _fills(tester, find.byKey(const ValueKey('pill'))).first,
        Color.alphaBlend(glass.dockTint, page),
      );
      // The bar tint is the page colour itself: invisible until content
      // scrolls under it.
      expect(
        _fills(tester, find.byKey(const ValueKey('bar'))).first,
        Color.alphaBlend(glass.tint, page),
      );
      for (final fill in _fills(tester, find.byType(Column))) {
        expect(fill.a, 1, reason: 'fallbacks are opaque');
      }
    });
  }

  testWidgets('a popover keeps one glass tone from its first to last frame', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: NotionTheme.build(Brightness.dark),
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    final context = navigator.currentContext!;
    final tokens = context.notion;
    showNotionPopover<void>(
      context: context,
      builder: (_) => const NotionGlassScope(
        mode: NotionGlassMode.on,
        child: Center(
          child: NotionGlassPanel(
            key: ValueKey('panel'),
            child: SizedBox(width: 160, height: 120),
          ),
        ),
      ),
    );
    final panel = find.byKey(const ValueKey('panel'));
    BackdropFilter blur() => tester.widget<BackdropFilter>(
      find.descendant(of: panel, matching: find.byType(BackdropFilter)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    // The glass grows out of its anchor with its blur on (no opaque
    // stand-in that turns translucent when the popover settles).
    expect(blur().enabled, isTrue);
    expect(_fills(tester, panel).first, tokens.glass.overlayTint);
    await tester.pumpAndSettle();
    expect(blur().enabled, isTrue);
    expect(_fills(tester, panel).first, tokens.glass.overlayTint);
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(blur().enabled, isTrue);
    expect(_fills(tester, panel).first, tokens.glass.overlayTint);
    await tester.pumpAndSettle();
  });
}

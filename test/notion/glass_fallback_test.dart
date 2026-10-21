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

  testWidgets('an overlay keeps its tone while it settles into the blur', (
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final panel = find.byKey(const ValueKey('panel'));
    expect(find.byType(BackdropFilter), findsNothing);
    final growing = _fills(tester, panel).first;
    expect(
      growing,
      Color.alphaBlend(tokens.glass.overlayTint, tokens.colors.background),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsOneWidget);
    // Settled glass over the same empty page composites to the same tone.
    expect(
      Color.alphaBlend(_fills(tester, panel).first, tokens.colors.background),
      growing,
    );
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.byType(BackdropFilter), findsNothing);
    expect(_fills(tester, panel).first, growing);
    await tester.pumpAndSettle();
  });
}

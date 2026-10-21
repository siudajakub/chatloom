// SPDX-License-Identifier: AGPL-3.0-or-later
// NotionStatusPill: tones, semantics, in-place change and a golden of the
// resting states (DESIGN.md primitives). Run goldens through
// scripts/verify-notion-ui.py so fonts match.
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

Color _dot(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(
    find
        .descendant(
          of: find.byType(NotionStatusPill),
          matching: find.byType(DecoratedBox),
        )
        .last,
  );
  return (box.decoration as BoxDecoration).color!;
}

void main() {
  testWidgets('only the dot carries the status colour', (tester) async {
    for (final (tone, role) in [
      (NotionStatusTone.success, (NotionColors c) => c.success),
      (NotionStatusTone.warning, (NotionColors c) => c.warning),
      (NotionStatusTone.danger, (NotionColors c) => c.danger),
      (NotionStatusTone.neutral, (NotionColors c) => c.textTertiary),
    ]) {
      await tester.pumpWidget(
        _app(NotionStatusPill(label: 'Status', tone: tone)),
      );
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(NotionStatusPill));
      expect(_dot(tester), role(context.notion.colors));
      expect(
        tester.widget<Text>(find.text('Status')).style?.color,
        context.notion.colors.text,
      );
    }
  });

  testWidgets('reads as one label and changes in place', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        const NotionStatusPill(
          label: 'Connected',
          tone: NotionStatusTone.success,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Connected'), findsOneWidget);
    await tester.pumpWidget(
      _app(
        const NotionStatusPill(
          label: 'Disconnected',
          tone: NotionStatusTone.danger,
        ),
      ),
    );
    await tester.pump(NotionMotion.instant);
    await tester.pumpAndSettle();
    expect(find.text('Connected'), findsNothing);
    expect(find.text('Disconnected'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('a long label ellipsizes instead of overflowing', (tester) async {
    await tester.pumpWidget(
      _app(
        const SizedBox(
          width: 90,
          child: NotionStatusPill(
            label: 'Needs attention right now',
            tone: NotionStatusTone.warning,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('status pills golden', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('golden'),
        child: _app(
          const Wrap(
            spacing: NotionSpace.xs,
            runSpacing: NotionSpace.xs,
            children: [
              NotionStatusPill(
                label: 'Connected',
                tone: NotionStatusTone.success,
              ),
              NotionStatusPill(
                label: 'Needs attention',
                tone: NotionStatusTone.warning,
              ),
              NotionStatusPill(
                label: 'Disconnected',
                tone: NotionStatusTone.danger,
              ),
              NotionStatusPill(label: 'Unknown'),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const Key('golden')),
      matchesGoldenFile('goldens/primitives/status-pill-dark.png'),
    );
  });
}

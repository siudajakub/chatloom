// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _tools = [
  NotionEditorTool(id: 'crop', icon: Icons.crop_rounded, label: 'Crop'),
  NotionEditorTool(id: 'draw', icon: Icons.brush_rounded, label: 'Draw'),
  NotionEditorTool(id: 'blur', icon: Icons.blur_on_rounded, label: 'Blur'),
  NotionEditorTool(
    id: 'filter',
    icon: Icons.auto_awesome_rounded,
    label: 'Filters',
  ),
  NotionEditorTool(id: 'tune', icon: Icons.tune_rounded, label: 'Adjust'),
];

Widget _app(
  Widget child, {
  Brightness brightness = Brightness.dark,
  bool reducedMotion = false,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: NotionTheme.build(brightness),
  builder: (context, app) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
    child: app!,
  ),
  home: Scaffold(
    backgroundColor: NotionMediaColors.viewer,
    body: SafeArea(child: child),
  ),
);

/// The editor's chrome at rest: top bar, a crop panel, a draw panel, the
/// dock, a trim badge and the export panel.
Widget _chrome() => ListView(
  children: [
    NotionEditorTopBar(
      title: 'Edit photo',
      onClose: () {},
      onUndo: () {},
      onRedo: () {},
      canUndo: true,
      onDone: () {},
    ),
    NotionEditorPanel(
      children: [
        NotionEditorChoices<double>(
          options: const [
            NotionEditorChoice(value: -1, label: 'Free'),
            NotionEditorChoice(value: 0, label: 'Original'),
            NotionEditorChoice(value: 1, label: 'Square'),
            NotionEditorChoice(value: 16 / 9, label: '16:9'),
          ],
          selected: 1,
          onSelected: (_) {},
        ),
      ],
    ),
    const SizedBox(height: NotionSpace.xs),
    NotionEditorPanel(
      children: [
        NotionEditorSwatches(
          selected: NotionEditorSwatches.drawing[2],
          onSelected: (_) {},
        ),
        NotionEditorSlider(
          label: 'Size',
          value: 6,
          min: 2,
          max: 24,
          valueLabel: '6',
          onChanged: (_) {},
        ),
      ],
    ),
    const SizedBox(height: NotionSpace.xs),
    NotionEditorDock(tools: _tools, selected: 'draw', onSelected: (_) {}),
    const SizedBox(height: NotionSpace.xs),
    const Center(
      child: NotionEditorBadge(icon: Icons.content_cut_rounded, text: '0:07'),
    ),
    const SizedBox(height: NotionSpace.xs),
    const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: NotionSpace.md),
        child: NotionEditorProgress(
          label: 'Preparing video…',
          progress: 0.42,
          onCancel: _noop,
        ),
      ),
    ),
  ],
);

void _noop() {}

void main() {
  setUpAll(() async {
    final loader = FontLoader('Roboto');
    for (final name in ['Regular', 'Medium', 'Bold']) {
      loader.addFont(rootBundle.load('assets/notion/fonts/Roboto-$name.ttf'));
    }
    await loader.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  testWidgets('the dock reports the tapped tool and marks the selected one', (
    tester,
  ) async {
    NotionEditorTool? tapped;
    await tester.pumpWidget(
      _app(
        Center(
          child: NotionEditorDock(
            tools: _tools,
            selected: 'crop',
            onSelected: (tool) => tapped = tool,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Blur'));
    expect(tapped?.id, 'blur');
    expect(
      tester.getSemantics(find.bySemanticsLabel('Crop')),
      matchesSemantics(
        label: 'Crop',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        hasTapAction: true,
      ),
    );
  });

  testWidgets('undo and done follow their state, busy locks the bar', (
    tester,
  ) async {
    var undone = 0, done = 0;
    Widget bar({required bool canUndo, bool busy = false}) => _app(
      NotionEditorTopBar(
        title: 'Crop',
        onClose: () {},
        onUndo: () => undone++,
        onRedo: () {},
        canUndo: canUndo,
        onDone: () => done++,
        busy: busy,
      ),
    );
    await tester.pumpWidget(bar(canUndo: false));
    await tester.tap(find.byTooltip('Undo'));
    expect(undone, 0);
    await tester.pumpWidget(bar(canUndo: true));
    await tester.tap(find.byTooltip('Undo'));
    await tester.tap(find.text('Done'));
    expect((undone, done), (1, 1));
    await tester.pumpWidget(bar(canUndo: true, busy: true));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Undo'), warnIfMissed: false);
    expect(undone, 1);
  });

  testWidgets('choices and swatches report the tapped value', (tester) async {
    double? ratio;
    Color? color;
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            NotionEditorChoices<double>(
              options: const [
                NotionEditorChoice(value: 1, label: 'Square'),
                NotionEditorChoice(value: 16 / 9, label: '16:9'),
              ],
              selected: 1,
              onSelected: (value) => ratio = value,
            ),
            NotionEditorSwatches(selected: null, onSelected: (c) => color = c),
          ],
        ),
      ),
    );
    await tester.tap(find.text('16:9'));
    await tester.tap(find.bySemanticsLabel('Blue'));
    expect(ratio, 16 / 9);
    expect(color, NotionEditorSwatches.drawing[6]);
  });

  testWidgets('the export panel hides Cancel without a handler', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const Center(
          child: NotionEditorProgress(label: 'Saving photo…', progress: null),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Cancel'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('reduced motion leaves the chrome static', (tester) async {
    await tester.pumpWidget(_app(_chrome(), reducedMotion: true));
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('media editor chrome golden ${brightness.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('media-editor-golden'),
          child: _app(_chrome(), brightness: brightness),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byKey(const Key('media-editor-golden')),
        matchesGoldenFile(
          'goldens/primitives/media-editor-${brightness.name}.png',
        ),
      );
    });
  }
}

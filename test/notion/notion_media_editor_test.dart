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

const _drawTools = [
  NotionEditorChoice(
    value: PaintMode.freeStyle,
    label: 'Pen',
    icon: Icons.edit_rounded,
  ),
  NotionEditorChoice(
    value: PaintMode.arrow,
    label: 'Arrow',
    icon: Icons.arrow_outward_rounded,
  ),
  NotionEditorChoice(
    value: PaintMode.rect,
    label: 'Box',
    icon: Icons.crop_square_rounded,
  ),
  NotionEditorChoice(
    value: PaintMode.circle,
    label: 'Circle',
    icon: Icons.circle_outlined,
  ),
  NotionEditorChoice(
    value: PaintMode.eraser,
    label: 'Eraser',
    icon: Icons.auto_fix_normal_rounded,
  ),
];

/// Stand-in for the paint modes, so this primitive test does not import the
/// editor package.
enum PaintMode { freeStyle, arrow, rect, circle, eraser }

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

  testWidgets('the title keeps its distance from the pills', (tester) async {
    Future<void> check(double width, NotionEditorTopBar bar) async {
      tester.view.physicalSize = Size(width, 200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_app(bar));
      await tester.pumpAndSettle();
      final title = tester.getRect(find.text(bar.title));
      final close = tester.getRect(find.byType(NotionGlassPill).first);
      final done = tester.getRect(find.byType(NotionButton));
      final right = find.byIcon(Icons.undo_rounded).evaluate().isEmpty
          ? done.left
          : tester.getRect(find.byTooltip('Undo')).left;
      expect(title.left - close.right, greaterThanOrEqualTo(NotionSpace.sm));
      expect(right - title.right, greaterThanOrEqualTo(NotionSpace.sm));
      expect(tester.takeException(), isNull);
    }

    // Room enough: centred on the bar.
    final filters = NotionEditorTopBar(
      title: 'Filters',
      onClose: () {},
      onDone: () {},
    );
    await check(390, filters);
    expect(tester.getCenter(find.text('Filters')).dx, closeTo(195, 0.5));
    // A 360-dp phone with undo and redo: between the pills.
    for (final title in ['Edit photo', 'Blur']) {
      await check(
        360,
        NotionEditorTopBar(
          title: title,
          onClose: () {},
          onUndo: () {},
          onRedo: () {},
          canUndo: true,
          onDone: () {},
        ),
      );
    }
  });

  testWidgets('tool chips that do not fit become icons, all in view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    PaintMode? picked;
    await tester.pumpWidget(
      _app(
        NotionEditorPanel(
          children: [
            NotionEditorChoices<PaintMode>(
              options: _drawTools,
              selected: PaintMode.freeStyle,
              onSelected: (mode) => picked = mode,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Pen'), findsOneWidget);
    expect(find.text('Eraser'), findsNothing);
    final eraser = find.byTooltip('Eraser');
    expect(tester.getRect(eraser).right, lessThanOrEqualTo(360));
    await tester.tap(eraser);
    expect(picked, PaintMode.eraser);
    expect(tester.takeException(), isNull);
  });

  for (final (width, scale) in [(300.0, 1.0), (390.0, 2.5)]) {
    testWidgets('a dock too narrow for its labels keeps touch-size icons '
        '($width dp, text ×$scale)', (tester) async {
      tester.view.physicalSize = Size(width, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      NotionEditorTool? tapped;
      await tester.pumpWidget(
        MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: Center(
              child: NotionEditorDock(
                tools: _tools,
                selected: 'draw',
                onSelected: (tool) => tapped = tool,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Filters'), findsNothing);
      // Not scaled down: every cell keeps at least the touch target.
      for (final tool in _tools) {
        final cell = tester.getRect(find.byTooltip(tool.label));
        expect(cell.width, greaterThanOrEqualTo(NotionSize.touchTarget));
        expect(cell.right, lessThanOrEqualTo(width));
      }
      expect(
        tester.getSemantics(find.bySemanticsLabel('Adjust')),
        matchesSemantics(
          label: 'Adjust',
          isButton: true,
          hasSelectedState: true,
          hasTapAction: true,
        ),
      );
      await tester.tap(find.byTooltip('Adjust'));
      expect(tapped?.id, 'tune');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the dock takes its own height in a bottom bar', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: Scaffold(
          body: const SizedBox.expand(key: Key('stage')),
          bottomNavigationBar: NotionEditorDock(
            tools: _tools,
            onSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // A plain Center here took the whole height and left the stage 0 px.
    expect(
      tester.getSize(find.byKey(const Key('stage'))).height,
      greaterThan(600),
    );
    expect(tester.getSize(find.byType(NotionEditorDock)).height, lessThan(80));
    expect(tester.takeException(), isNull);
  });

  testWidgets('media editor top bar golden at 360 dp', (tester) async {
    tester.view.physicalSize = const Size(360, 260);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('media-editor-bar-golden'),
        child: _app(
          Column(
            children: [
              NotionEditorTopBar(
                title: 'Edit photo',
                onClose: () {},
                onUndo: () {},
                onRedo: () {},
                canUndo: true,
                onDone: () {},
              ),
              NotionEditorTopBar(
                title: 'Blur',
                closeIcon: Icons.arrow_back_rounded,
                closeLabel: 'Back',
                onClose: () {},
                onUndo: () {},
                onRedo: () {},
                canRedo: true,
                onDone: () {},
              ),
              NotionEditorTopBar(
                title: 'Filters',
                closeIcon: Icons.arrow_back_rounded,
                closeLabel: 'Back',
                onClose: () {},
                onDone: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(const Key('media-editor-bar-golden')),
      matchesGoldenFile('goldens/primitives/media-editor-bar-360.png'),
    );
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

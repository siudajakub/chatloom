// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/personal/media/editor/paint_canvas_overlay.dart';
import 'package:chatloom/personal/media/editor/paint_session.dart';
import 'package:chatloom/personal/media/editor/photo_editor_page.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:pro_image_editor/pro_image_editor.dart';
import 'package:pro_image_editor/shared/services/content_recorder/widgets/content_recorder.dart';

/// The real photo editor (pro_image_editor with the Notion skin) on a small
/// in-memory PNG. The engine's decoders run outside fake time, so every
/// wait alternates real time ([WidgetTester.runAsync]) with frames.
void main() {
  setUpAll(() async {
    final roboto = FontLoader('Roboto');
    for (final name in ['Regular', 'Medium', 'Bold']) {
      roboto.addFont(rootBundle.load('assets/notion/fonts/Roboto-$name.ttf'));
    }
    await roboto.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  Uint8List photo() {
    final image = img.Image(width: 120, height: 90);
    img.fill(image, color: img.ColorRgb8(200, 60, 40));
    return img.encodePng(image);
  }

  Future<void> settle(WidgetTester tester, [int rounds = 8]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<ProImageEditorState> open(
    WidgetTester tester, {
    double width = 411,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: PhotoEditorPage(bytes: photo(), heroTag: 'photo-editor-test'),
      ),
    );
    await settle(tester, 12);
    return tester.state<ProImageEditorState>(find.byType(ProImageEditor));
  }

  Future<PaintEditorState> openTool(
    WidgetTester tester,
    ProImageEditorState editor,
    String label,
  ) async {
    await tester.tap(find.text(label));
    await settle(tester);
    return editor.paintEditor.currentState!;
  }

  Future<void> drag(WidgetTester tester, Offset from, Offset to) async {
    final gesture = await tester.startGesture(from);
    const steps = 8;
    for (var i = 1; i <= steps; i++) {
      await gesture.moveTo(Offset.lerp(from, to, i / steps)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await settle(tester, 3);
  }

  Offset stageCenter(WidgetTester tester) =>
      tester.getCenter(find.byType(PaintCanvasOverlay));

  /// Whether the top bar's Undo or Redo (of the tool on top) can act.
  bool historyEnabled(WidgetTester tester, String label) {
    final icon = label == 'Undo' ? Icons.undo_rounded : Icons.redo_rounded;
    final cell = find.ancestor(
      of: find.byIcon(icon).last,
      matching: find.byType(InkWell),
    );
    return tester.widget<InkWell>(cell.first).onTap != null;
  }

  testWidgets('the photo fills the stage above the dock', (tester) async {
    final editor = await open(tester);
    final body = editor.sizesManager.bodySize;
    // The dock used to take the whole height and leave the stage at 0 px.
    expect(body.height, greaterThan(500));
    expect(editor.sizesManager.decodedImageSize.width, closeTo(411, 0.5));
    final stage = tester.getSize(find.byType(Image).first);
    expect(stage.height, greaterThan(250));
    final dock = tester.getRect(find.byType(NotionEditorDock));
    expect(dock.bottom, greaterThan(760));
    expect(dock.height, lessThan(100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('undo and redo follow Draw and the main editor', (tester) async {
    final editor = await open(tester);
    expect(historyEnabled(tester, 'Undo'), isFalse);
    final paint = await openTool(tester, editor, 'Draw');
    final center = stageCenter(tester);
    await drag(
      tester,
      center - const Offset(40, 20),
      center + const Offset(40, 20),
    );
    expect(paint.activeHistory.layers, hasLength(1));
    expect(historyEnabled(tester, 'Undo'), isTrue);
    await tester.tap(find.byTooltip('Undo').last);
    await settle(tester, 2);
    expect(paint.activeHistory.layers, isEmpty);
    expect(historyEnabled(tester, 'Redo'), isTrue);
    await tester.tap(find.byTooltip('Redo').last);
    await settle(tester, 2);
    expect(paint.activeHistory.layers, hasLength(1));

    await tester.tap(find.text('Done').last);
    await settle(tester, 10);
    expect(editor.activeLayers, hasLength(1));
    expect(historyEnabled(tester, 'Undo'), isTrue);
    await tester.tap(find.byTooltip('Undo').last);
    await settle(tester, 4);
    expect(editor.activeLayers, isEmpty);
    await tester.tap(find.byTooltip('Redo').last);
    await settle(tester, 4);
    expect(editor.activeLayers, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Blur: the eraser removes a whole area by tap, undo restores', (
    tester,
  ) async {
    final editor = await open(tester);
    final paint = await openTool(tester, editor, 'Blur');
    expect(paint.paintMode, PaintMode.blur);
    final center = stageCenter(tester);
    await drag(
      tester,
      center - const Offset(60, 40),
      center + const Offset(60, 40),
    );
    expect(paint.activeHistory.layers, hasLength(1));
    final area = paint.activeHistory.layers.single as PaintLayer;
    expect(area.item.mode, PaintMode.blur);
    expect(area.mask, isNull, reason: 'Box is the default shape');

    await tester.tap(find.text('Eraser'));
    await settle(tester, 2);
    // A tap, without a drag, used to do nothing.
    await tester.tapAt(center + const Offset(30, 10));
    await settle(tester, 2);
    expect(paint.activeHistory.layers, isEmpty);
    expect(paint.activeHistory.removedLayers.single.id, area.id);

    await tester.tap(find.byTooltip('Undo').last);
    await settle(tester, 2);
    expect(paint.activeHistory.layers.single.id, area.id);
    // Nothing partial: the area is untouched.
    expect(area.item.erasedOffsets, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Blur outlines its areas and the dragged one, unrecorded', (
    tester,
  ) async {
    final editor = await open(tester);
    await openTool(tester, editor, 'Blur');
    final overlay = find.byType(PaintCanvasOverlay);
    // Outside the recorded canvas: the outlines never reach the photo.
    expect(
      find.ancestor(of: overlay, matching: find.byType(ContentRecorder)),
      findsNothing,
    );
    final painters = find.descendant(
      of: overlay,
      matching: find.byType(CustomPaint),
    );
    final center = stageCenter(tester);
    final gesture = await tester.startGesture(center - const Offset(50, 30));
    for (var i = 1; i <= 6; i++) {
      await gesture.moveBy(const Offset(15, 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    // While dragging: the area's outline (halo, then line).
    expect(
      tester.renderObject(painters.at(1)),
      paints
        ..path()
        ..path(),
    );
    await gesture.up();
    await settle(tester, 3);
    expect(tester.renderObject(painters.at(1)), isNot(paints..path()));
    expect(
      tester.renderObject(painters.at(0)),
      paints
        ..path()
        ..path(),
    );
  });

  testWidgets('Blur: one eraser drag across two areas is one undo step', (
    tester,
  ) async {
    final editor = await open(tester);
    final paint = await openTool(tester, editor, 'Blur');
    final center = stageCenter(tester);
    await drag(
      tester,
      center - const Offset(150, 40),
      center - const Offset(40, -40),
    );
    await drag(
      tester,
      center + const Offset(40, -40),
      center + const Offset(150, 40),
    );
    expect(paint.activeHistory.layers, hasLength(2));
    final before = paint.historyPointer;

    await tester.tap(find.text('Eraser'));
    await settle(tester, 2);
    await drag(
      tester,
      center - const Offset(120, 0),
      center + const Offset(120, 0),
    );
    expect(paint.activeHistory.layers, isEmpty);
    expect(paint.historyPointer, before + 1);
    await tester.tap(find.byTooltip('Undo').last);
    await settle(tester, 2);
    expect(paint.activeHistory.layers, hasLength(2));
  });

  testWidgets('Blur: Oval areas get an ellipse, Box areas stay boxes', (
    tester,
  ) async {
    final editor = await open(tester);
    final paint = await openTool(tester, editor, 'Blur');
    final center = stageCenter(tester);
    await tester.tap(find.text('Oval'));
    await settle(tester, 2);
    await drag(
      tester,
      center - const Offset(80, 60),
      center + const Offset(80, 60),
    );
    final oval = paint.activeHistory.layers.last as PaintLayer;
    expect(isOvalCensorArea(oval), isTrue);

    await tester.tap(find.text('Box'));
    await settle(tester, 2);
    await drag(
      tester,
      center + const Offset(100, 100),
      center + const Offset(180, 180),
    );
    final box = paint.activeHistory.layers.last as PaintLayer;
    expect(isOvalCensorArea(box), isFalse);
    expect(isOvalCensorArea(oval), isTrue, reason: 'shape is per area');

    // The oval's box corner is outside the oval: the eraser misses it.
    await tester.tap(find.text('Eraser'));
    await settle(tester, 2);
    await tester.tapAt(center - const Offset(76, 56));
    await settle(tester, 2);
    expect(paint.activeHistory.layers, hasLength(2));
    await tester.tapAt(center);
    await settle(tester, 2);
    expect(paint.activeHistory.layers.single.id, box.id);

    // The shape survives the trip back to the main editor.
    await tester.tap(find.byTooltip('Undo').last);
    await settle(tester, 2);
    await tester.tap(find.text('Done').last);
    await settle(tester, 10);
    final kept = editor.activeLayers.whereType<PaintLayer>().toList();
    expect(kept.where(isOvalCensorArea), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Blur: Strength sets new areas and the one just drawn', (
    tester,
  ) async {
    final editor = await open(tester);
    final paint = await openTool(tester, editor, 'Blur');
    expect(
      paint.paintCtrl.censorStrength,
      CensorStrength.blurSigma(CensorStrength.initial),
    );
    final center = stageCenter(tester);
    await drag(
      tester,
      center - const Offset(60, 40),
      center + const Offset(60, 40),
    );
    final area = paint.activeHistory.layers.single as PaintLayer;
    expect(area.item.censorStrength, CensorStrength.blurSigma(0.5));

    final slider = find.descendant(
      of: find.widgetWithText(NotionEditorSlider, 'Strength'),
      matching: find.byType(Slider),
    );
    final pointer = paint.historyPointer;
    await tester.drag(slider, const Offset(400, 0));
    await settle(tester, 2);
    expect(paint.paintCtrl.censorStrength, CensorStrength.blurSigma(1));
    expect(find.text('100'), findsOneWidget);
    // On release the area takes it as one undoable step (same area id).
    final strong = paint.activeHistory.layers.single as PaintLayer;
    expect(strong.id, area.id);
    expect(strong.item.censorStrength, CensorStrength.blurSigma(1));
    expect(paint.historyPointer, pointer + 1);
    await tester.tap(find.byTooltip('Undo').last);
    await settle(tester, 2);
    final back = paint.activeHistory.layers.single as PaintLayer;
    expect(back.item.censorStrength, CensorStrength.blurSigma(0.5));
  });

  testWidgets('Blur: another tool chosen mid-erase never leaves the eraser '
      'stuck or erasing', (tester) async {
    final editor = await open(tester);
    final paint = await openTool(tester, editor, 'Blur');
    final center = stageCenter(tester);
    await drag(
      tester,
      center - const Offset(150, 40),
      center - const Offset(40, -40),
    );
    await drag(
      tester,
      center + const Offset(40, -40),
      center + const Offset(150, 40),
    );
    expect(paint.activeHistory.layers, hasLength(2));
    await tester.tap(find.text('Eraser'));
    await settle(tester, 2);

    // One finger rests on the photo, away from both areas…
    final resting = await tester.startGesture(center + const Offset(0, 150));
    await tester.pump();
    // …while another picks Blur on the panel and then the eraser again.
    await tester.tap(
      find.descendant(
        of: find.byType(NotionEditorChoices<PaintMode>),
        matching: find.text('Blur'),
      ),
    );
    await settle(tester, 2);
    expect(paint.paintMode, PaintMode.blur);
    // The resting finger moving across an area no longer erases.
    await resting.moveTo(center - const Offset(95, 0));
    await tester.pump();
    expect(paint.activeHistory.layers, hasLength(2));
    await tester.tap(find.text('Eraser'));
    await settle(tester, 2);
    // A new tap still erases although the first finger never lifted.
    await tester.tapAt(center + const Offset(95, 0));
    await settle(tester, 2);
    expect(paint.activeHistory.layers, hasLength(1));
    await resting.up();
    await settle(tester, 2);
  });

  testWidgets('Draw: one fast swipe erases a thin line it jumps across', (
    tester,
  ) async {
    final editor = await open(tester);
    final paint = await openTool(tester, editor, 'Draw');
    final center = stageCenter(tester);
    await drag(
      tester,
      center - const Offset(100, 0),
      center + const Offset(100, 0),
    );
    expect(paint.activeHistory.layers, hasLength(1));
    await tester.tap(find.byTooltip('Eraser'));
    await settle(tester, 2);
    // Down well above, a single move event well below the line.
    final swipe = await tester.startGesture(center - const Offset(0, 80));
    await swipe.moveTo(center + const Offset(0, 80));
    await tester.pump();
    await swipe.up();
    await settle(tester, 2);
    expect(paint.activeHistory.layers, isEmpty);
  });

  testWidgets('Draw: the eraser removes whole drawings, never censor areas', (
    tester,
  ) async {
    final editor = await open(tester);
    var paint = await openTool(tester, editor, 'Blur');
    final center = stageCenter(tester);
    await drag(
      tester,
      center - const Offset(60, 40),
      center + const Offset(60, 40),
    );
    await tester.tap(find.text('Done').last);
    await settle(tester, 10);

    paint = await openTool(tester, editor, 'Draw');
    expect(paint.paintMode, PaintMode.freeStyle);
    await drag(
      tester,
      center - const Offset(100, 0),
      center + const Offset(100, 0),
    );
    expect(paint.activeHistory.layers, hasLength(2));

    // Five tools do not fit labelled on a phone: the unselected ones are
    // icons with a tooltip, all in view.
    expect(find.byTooltip('Eraser'), findsOneWidget);
    await tester.tap(find.byTooltip('Eraser'));
    await settle(tester, 2);
    expect(paint.paintMode, PaintMode.eraser);
    // Through the middle of the line and of the blur area.
    await drag(
      tester,
      center - const Offset(0, 30),
      center + const Offset(0, 30),
    );
    final left = paint.activeHistory.layers.whereType<PaintLayer>().toList();
    expect(left.single.item.mode, PaintMode.blur);
    expect(left.single.item.erasedOffsets, isEmpty);
  });

  testWidgets('Crop and Adjust undo their own changes', (tester) async {
    final editor = await open(tester);
    await tester.tap(find.text('Crop'));
    await settle(tester, 10);
    final crop = editor.cropRotateEditor.currentState!;
    await tester.tap(find.text('Rotate'));
    await settle(tester, 10);
    expect(crop.canUndo, isTrue);
    expect(historyEnabled(tester, 'Undo'), isTrue);
    await tester.tap(find.byTooltip('Undo').last);
    await settle(tester, 10);
    expect(crop.canUndo, isFalse);
    expect(crop.canRedo, isTrue);
    await tester.tap(find.byTooltip('Back').last);
    await settle(tester, 12);

    await tester.tap(find.text('Adjust'));
    await settle(tester, 10);
    final tune = editor.tuneEditor.currentState!;
    await tester.drag(find.byType(Slider).last, const Offset(80, 0));
    await settle(tester, 2);
    expect(tune.canUndo, isTrue);
    final changed = tune.tuneAdjustmentMatrix.first.value;
    expect(changed, isNot(0));
    await tester.tap(find.byTooltip('Undo').last);
    await settle(tester, 2);
    expect(tune.tuneAdjustmentMatrix.first.value, 0);
    expect(tune.canRedo, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Back leaves every tool without its changes', (tester) async {
    final editor = await open(tester);
    for (final tool in ['Draw', 'Blur', 'Crop', 'Filters', 'Adjust']) {
      await tester.tap(find.text(tool));
      await settle(tester, 10);
      expect(editor.isSubEditorOpen, isTrue, reason: tool);
      await tester.tap(find.byTooltip('Back').last);
      await settle(tester, 12);
      expect(editor.isSubEditorOpen, isFalse, reason: '$tool stayed open');
    }
    expect(editor.canUndo, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Done returns a fresh JPEG of the edited photo', (tester) async {
    tester.view.physicalSize = const Size(411, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    PaintingBinding.instance.imageCache.clear();
    EditedPhoto? result;
    var returned = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                result = await showPhotoEditor(
                  context,
                  bytes: photo(),
                  heroTag: 'photo-editor-done',
                );
                returned = true;
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await settle(tester, 12);
    final editor = tester.state<ProImageEditorState>(
      find.byType(ProImageEditor),
    );
    final paint = await openTool(tester, editor, 'Blur');
    final center = stageCenter(tester);
    await drag(
      tester,
      center - const Offset(60, 40),
      center + const Offset(60, 40),
    );
    expect(paint.activeHistory.layers, hasLength(1));
    await tester.tap(find.text('Done').last);
    await settle(tester, 10);
    await tester.tap(find.text('Done').last);
    for (var i = 0; i < 60 && !returned; i++) {
      await settle(tester, 1);
    }
    expect(returned, isTrue);
    final bytes = result!.bytes;
    expect(result!.format.mimeType, 'image/jpeg');
    expect(bytes.sublist(0, 3), [0xFF, 0xD8, 0xFF]);
    final decoded = img.decodeJpg(bytes)!;
    // The 120 × 90 photo, not the 0-px stage of the collapsed layout.
    expect(decoded.width / decoded.height, closeTo(120 / 90, 0.05));
    // The precached source left the app's image cache with the editor.
    await settle(tester, 4);
    expect(PaintingBinding.instance.imageCache.currentSize, 0);
    expect(tester.takeException(), isNull);
  });

  for (final textScale in [1.0, 1.6]) {
    testWidgets('Crop fits a 360-dp phone at text scale $textScale', (
      tester,
    ) async {
      final editor = await open(tester, width: 360, textScale: textScale);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Crop'));
      await settle(tester, 10);
      expect(tester.takeException(), isNull, reason: 'no overflow');
      final crop = editor.cropRotateEditor.currentState!;
      // Labelled when they fit, icons with a tooltip when they do not.
      final rotate = textScale == 1
          ? find.text('Rotate')
          : find.byTooltip('Rotate');
      expect(rotate, findsOneWidget);
      expect(tester.getRect(rotate).right, lessThanOrEqualTo(360));
      final reset = textScale == 1
          ? find.text('Reset')
          : find.byTooltip('Reset');
      expect(tester.getRect(reset).right, lessThanOrEqualTo(360));
      await tester.tap(rotate);
      // The package turns the photo on timers of its own: let them end.
      await settle(tester, 20);
      expect(crop.canUndo, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a large photo opens at once on a spinner, then scaled', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(411, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Earlier editors in this file left the package's small filter
    // thumbnails (keys of its own) in the shared cache.
    PaintingBinding.instance.imageCache.clear();
    final large = img.Image(width: 5000, height: 100);
    img.fill(large, color: img.ColorRgb8(20, 90, 160));
    final bytes = img.encodePng(large);
    var returned = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                await showPhotoEditor(
                  context,
                  bytes: bytes,
                  heroTag: 'photo-editor-large',
                );
                returned = true;
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump();
    // Pushed without waiting for the scaling: the editor's stage with a
    // spinner and a way out.
    expect(find.byType(ProImageEditor), findsNothing);
    expect(find.byType(NotionDelayedSpinner), findsOneWidget);
    expect(find.byTooltip('Cancel'), findsOneWidget);
    for (
      var i = 0;
      i < 40 && find.byType(ProImageEditor).evaluate().isEmpty;
      i++
    ) {
      await settle(tester, 1);
    }
    await settle(tester, 8);
    final editor = tester.state<ProImageEditorState>(
      find.byType(ProImageEditor),
    );
    expect(editor.sizesManager.originalImageSize, const Size(4096, 82));
    await tester.tap(find.byTooltip('Cancel'));
    await settle(tester, 10);
    expect(returned, isTrue);
    // The editor's decode left the app's image cache with it.
    expect(PaintingBinding.instance.imageCache.currentSize, 0);
  });
}

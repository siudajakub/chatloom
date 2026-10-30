// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pro_image_editor/core/models/transform_helper.dart';
import 'package:pro_image_editor/features/paint_editor/controllers/paint_controller.dart';
import 'package:pro_image_editor/features/paint_editor/models/paint_editor_response_model.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'paint_layer_geometry.dart';
import 'paint_session.dart';

/// Drawn over the paint editor's canvas (its `bodyItems`, which are not
/// recorded, so nothing here reaches the exported photo):
///
/// - the outline of every blur and pixelate area in the Blur tool, and of
///   the area being dragged, in the shape it will get;
/// - a frame around the box, circle or arrow being drawn in the Draw tool,
///   and around every drawing while the eraser is on;
/// - the eraser itself: a tap or a drag removes every whole shape it
///   touches (only censor areas in Blur, only drawings in Draw), one undo
///   step per gesture. The package's eraser only reacts to a drag and, by
///   default, cuts holes into strokes that censor areas never draw.
///
/// Relies on the paint editor's zoom being off (`enableZoom: false`): the
/// canvas and this overlay then share one coordinate space.
class PaintCanvasOverlay extends StatefulWidget {
  final PaintEditorState paint;
  final PhotoPaintSession session;

  const PaintCanvasOverlay({
    super.key,
    required this.paint,
    required this.session,
  });

  /// How far from a stroke a fingertip still counts, in logical pixels.
  static const double touchRadius = NotionSpace.sm;

  @override
  State<PaintCanvasOverlay> createState() => _PaintCanvasOverlayState();
}

class _PaintCanvasOverlayState extends State<PaintCanvasOverlay> {
  PaintEditorState get _paint => widget.paint;
  PhotoPaintSession get _session => widget.session;

  int? _pointer;
  Offset? _last;

  /// The history step this eraser gesture added, grown while it goes on.
  PaintEditorResponse? _step;

  bool get _erasing => _paint.paintMode == PaintMode.eraser;

  /// The scale of the paint editor's layer stack (`_layerStackTransformHelper`
  /// in the package).
  double _stackScale(Size canvas) {
    Size valid(Size? size) => size == null || size.isEmpty
        ? (canvas.isEmpty ? const Size(1, 1) : canvas)
        : size;
    return TransformHelper(
      mainBodySize: valid(_paint.mainBodySize),
      mainImageSize: valid(_paint.mainImageSize),
      editorBodySize: canvas,
      transformConfigs: _paint.initialTransformConfigs,
    ).scale;
  }

  /// The layers the active tool works on: censor areas in Blur, drawings in
  /// Draw.
  Iterable<(PaintLayer, PaintLayerPlacement)> _placements(Size canvas) sync* {
    final scale = _stackScale(canvas);
    for (final layer in _paint.activeHistory.layers) {
      if (layer is! PaintLayer || layer.item.isCensorArea != _session.censor) {
        continue;
      }
      yield (
        layer,
        PaintLayerPlacement.of(layer, canvasSize: canvas, stackScale: scale),
      );
    }
  }

  /// The dashed outline of each layer, by id, for its box size and shape:
  /// rebuilt only when a layer appears or changes size.
  final _outlineCache = <String, ({Size size, bool oval, Path path})>{};

  @override
  void didUpdateWidget(PaintCanvasOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The eraser's Listener leaves the tree when another tool is chosen
    // mid-gesture (a second finger on the panel); its pointer may then
    // never report its end, which would leave the eraser ignoring every new
    // touch once it is back.
    if (!_erasing) _endGesture();
  }

  void _endGesture() {
    _pointer = null;
    _last = null;
    _step = null;
  }

  void _down(PointerDownEvent event) {
    if (!_erasing || _pointer != null) return;
    _pointer = event.pointer;
    _last = event.localPosition;
    _step = null;
    _erase(event.localPosition, null);
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    if (!_erasing) return _endGesture();
    final from = _last ?? event.localPosition;
    _last = event.localPosition;
    _erase(from, event.localPosition);
  }

  void _end(PointerEvent event) {
    if (event.pointer == _pointer) _endGesture();
  }

  /// Removes what the finger touched between [from] and [to] (a tap when
  /// [to] is null): one segment test per layer, after a box check.
  void _erase(Offset from, Offset? to) {
    final canvas = context.size;
    if (canvas == null || canvas.isEmpty) return;
    final hits = <String>{
      for (final (layer, placement) in _placements(canvas))
        if (paintLayerHit(
          layer,
          placement,
          from,
          to: to,
          touchRadius: PaintCanvasOverlay.touchRadius,
        ))
          layer.id,
    };
    if (hits.isEmpty) return;
    NotionHaptics.selection();
    _remove(hits);
  }

  /// Removes [ids] as one history step per gesture: the first removal adds
  /// a step, later ones in the same gesture replace it.
  void _remove(Set<String> ids) {
    final paint = _paint;
    final current = paint.activeHistory;
    final next = PaintEditorResponse(
      layers: [
        for (final layer in current.layers)
          if (!ids.contains(layer.id)) layer,
      ],
      removedLayers: [
        ...current.removedLayers,
        for (final layer in current.layers)
          if (ids.contains(layer.id)) layer,
      ],
    );
    if (_step != null && identical(current, _step)) {
      replacePaintStep(paint, next);
    } else {
      pushPaintStep(paint, next);
    }
    _step = next;
  }

  /// The outlines to draw on a canvas of [size]: every censor area in Blur,
  /// every drawing in Draw while erasing.
  List<_OutlineSpec> _outlines(Size size) {
    if (!_session.censor && !_erasing) {
      _outlineCache.clear();
      return const [];
    }
    final seen = <String>{};
    final specs = <_OutlineSpec>[];
    for (final (layer, placement) in _placements(size)) {
      final censor = layer.item.isCensorArea;
      final box = censor
          ? placement.rect.size
          : placement.rect.inflate(_Outline.halo).size;
      final oval = isOvalCensorArea(layer);
      var cached = _outlineCache[layer.id];
      if (cached == null || cached.size != box || cached.oval != oval) {
        cached = (
          size: box,
          oval: oval,
          path: _Outline.dashed(
            Rect.fromCenter(
              center: Offset.zero,
              width: box.width,
              height: box.height,
            ),
            oval: oval,
          ),
        );
        _outlineCache[layer.id] = cached;
      }
      seen.add(layer.id);
      specs.add((
        center: placement.center,
        rotation: placement.rotation,
        path: cached.path,
      ));
    }
    _outlineCache.removeWhere((id, _) => !seen.contains(id));
    return specs;
  }

  @override
  Widget build(BuildContext context) {
    final layers = IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Repainted when the history or the tool changes the outlines
          // (this widget is rebuilt by the editor's stream then)…
          LayoutBuilder(
            builder: (context, constraints) => RepaintBoundary(
              child: CustomPaint(
                painter: _LayersPainter(_outlines(constraints.biggest)),
              ),
            ),
          ),
          // …and on every pointer move while a shape is being dragged.
          RepaintBoundary(
            child: CustomPaint(
              painter: _DragPainter(
                ctrl: _paint.paintCtrl,
                session: _session,
                repaint: Listenable.merge([_paint.paintCtrl, _session]),
              ),
            ),
          ),
        ],
      ),
    );
    if (!_erasing) return layers;
    return Stack(
      fit: StackFit.expand,
      children: [
        layers,
        // Opaque: the package's own eraser below never sees the gesture.
        Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: _end,
          onPointerCancel: _end,
        ),
      ],
    );
  }
}

/// One outline on the canvas: a dashed path around the origin, placed at
/// [center] and turned by [rotation].
typedef _OutlineSpec = ({Offset center, double rotation, Path path});

/// A dark halo under a light line, so an outline reads on any photo.
abstract final class _Outline {
  static const double line = 1.5;
  static const double halo = 3.5;
  static const double dash = 6, gap = 4;

  static final _haloPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = halo
    ..color = NotionMediaColors.scrim;

  static final _linePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = line
    ..color = NotionMediaColors.onScrim;

  static void draw(
    Canvas canvas,
    Rect rect, {
    required bool oval,
    required bool dashed,
  }) {
    if (rect.width <= 0 && rect.height <= 0) return;
    stroke(
      canvas,
      dashed ? _Outline.dashed(rect, oval: oval) : _shape(rect, oval: oval),
    );
  }

  static void stroke(Canvas canvas, Path path) => canvas
    ..drawPath(path, _haloPaint)
    ..drawPath(path, _linePaint);

  static Path _shape(Rect rect, {required bool oval}) =>
      oval ? (Path()..addOval(rect)) : (Path()..addRect(rect));

  static Path dashed(Rect rect, {required bool oval}) {
    final out = Path();
    for (final metric in _shape(rect, oval: oval).computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += dash + gap) {
        out.addPath(
          metric.extractPath(d, math.min(d + dash, metric.length)),
          Offset.zero,
        );
      }
    }
    return out;
  }
}

/// Every censor area in Blur; every drawing in Draw while erasing.
class _LayersPainter extends CustomPainter {
  final List<_OutlineSpec> outlines;

  _LayersPainter(this.outlines);

  @override
  void paint(Canvas canvas, Size size) {
    for (final outline in outlines) {
      canvas
        ..save()
        ..translate(outline.center.dx, outline.center.dy)
        ..rotate(outline.rotation);
      _Outline.stroke(canvas, outline.path);
      canvas.restore();
    }
  }

  /// Paths are cached per layer, so unchanged outlines compare equal.
  @override
  bool shouldRepaint(_LayersPainter oldDelegate) =>
      !listEquals(oldDelegate.outlines, outlines);
}

/// The area or shape being dragged: a censor area in the shape it will
/// get, a frame around a box, circle or arrow.
class _DragPainter extends CustomPainter {
  final PaintController ctrl;
  final PhotoPaintSession session;

  _DragPainter({
    required this.ctrl,
    required this.session,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final start = ctrl.start, end = ctrl.end;
    if (!ctrl.busy || start == null || end == null) return;
    final mode = ctrl.mode;
    final dragged = Rect.fromPoints(start, end);
    if (mode.isCensorMode) {
      _Outline.draw(
        canvas,
        dragged,
        oval: session.shape == CensorShape.oval,
        dashed: false,
      );
    } else if (mode == PaintMode.rect ||
        mode == PaintMode.circle ||
        mode == PaintMode.arrow ||
        mode == PaintMode.line) {
      _Outline.draw(
        canvas,
        dragged.inflate(ctrl.strokeWidth / 2 + _Outline.halo),
        oval: false,
        dashed: true,
      );
    }
  }

  @override
  bool shouldRepaint(_DragPainter oldDelegate) =>
      oldDelegate.ctrl != ctrl || oldDelegate.session != session;
}

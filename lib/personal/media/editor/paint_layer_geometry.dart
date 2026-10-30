// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'paint_session.dart';

/// Where a paint layer sits on the paint editor's canvas: the same maths the
/// package's eraser uses (`paint_canvas.dart`, `_processEraserInputAt`), plus
/// the layer's turn and flips, which the package draws around its centre.
@immutable
class PaintLayerPlacement {
  /// The centre on the canvas.
  final Offset center;

  /// The layer's own box (its `rawSize`), before [scale].
  final Size rawSize;

  /// Canvas pixels per unit of the layer's own coordinates: the layer
  /// stack's scale times the layer's.
  final double scale;

  final double rotation;
  final bool flipX, flipY;

  const PaintLayerPlacement({
    required this.center,
    required this.rawSize,
    required this.scale,
    this.rotation = 0,
    this.flipX = false,
    this.flipY = false,
  });

  /// The placement of [layer] on a canvas of [canvasSize] whose layer stack
  /// is scaled by [stackScale].
  factory PaintLayerPlacement.of(
    PaintLayer layer, {
    required Size canvasSize,
    required double stackScale,
  }) => PaintLayerPlacement(
    center: canvasSize.center(Offset.zero) + layer.offset * stackScale,
    rawSize: layer.rawSize,
    scale: stackScale * layer.scale,
    rotation: layer.rotation,
    flipX: layer.flipX,
    flipY: layer.flipY,
  );

  /// The layer's box on the canvas before its turn.
  Rect get rect => Rect.fromCenter(
    center: center,
    width: rawSize.width * scale,
    height: rawSize.height * scale,
  );

  /// The canvas box that holds the layer whatever its turn: a cheap first
  /// test before the per-stroke one.
  Rect get bounds {
    final half = Offset(rawSize.width, rawSize.height) * (scale / 2);
    if (rotation == 0) {
      return Rect.fromCenter(
        center: center,
        width: half.dx * 2,
        height: half.dy * 2,
      );
    }
    final cos = math.cos(rotation).abs(), sin = math.sin(rotation).abs();
    return Rect.fromCenter(
      center: center,
      width: 2 * (half.dx * cos + half.dy * sin),
      height: 2 * (half.dx * sin + half.dy * cos),
    );
  }

  /// [point] on the canvas in the layer's own coordinates (where its
  /// strokes' offsets live).
  Offset toLayer(Offset point) {
    if (scale <= 0) return Offset.infinite;
    var v = (point - center) / scale;
    if (flipX) v = Offset(-v.dx, v.dy);
    if (flipY) v = Offset(v.dx, -v.dy);
    if (rotation != 0) {
      final cos = math.cos(-rotation), sin = math.sin(-rotation);
      v = Offset(v.dx * cos - v.dy * sin, v.dx * sin + v.dy * cos);
    }
    return v + Offset(rawSize.width / 2, rawSize.height / 2);
  }
}

/// Whether a fingertip of [touchRadius] canvas pixels moving from [from] to
/// [to] (canvas coordinates; a tap when [to] is null) touches [layer]: a
/// stroke within half its width, a filled shape, or a censor area in its own
/// shape. The layer's turned box is checked first, so layers away from the
/// finger cost a few comparisons; the move is tested as a segment, so a
/// quick swipe cannot jump over a thin stroke.
bool paintLayerHit(
  PaintLayer layer,
  PaintLayerPlacement placement,
  Offset from, {
  Offset? to,
  double touchRadius = 0,
}) {
  if (placement.scale <= 0) return false;
  final end = to ?? from;
  final swept = Rect.fromPoints(from, end).inflate(touchRadius);
  if (!placement.bounds.overlaps(swept)) return false;
  // The canvas-to-layer map is affine: the move stays a segment.
  final a = placement.toLayer(from), b = placement.toLayer(end);
  final slop = touchRadius / placement.scale;
  final oval = isOvalCensorArea(layer);
  for (final item in layer.items) {
    if (paintedModelHit(item, a, to: b, slop: slop, ovalCensor: oval)) {
      return true;
    }
  }
  return false;
}

/// Whether the segment [point]–[to] (or [point] alone), in the stroke's own
/// coordinates, comes within [slop] of [item]. Censor areas are their box,
/// or the ellipse in it when [ovalCensor]. Allocates nothing.
@visibleForTesting
bool paintedModelHit(
  PaintedModel item,
  Offset point, {
  Offset? to,
  double slop = 0,
  bool ovalCensor = false,
}) {
  final b = to ?? point;
  final reach = item.strokeWidth / 2 + slop;
  final offsets = item.offsets;
  if (item.mode.isFreeStyleMode) {
    return _nearPolyline(offsets, point, b, reach);
  }
  final (first, second) = _ends(offsets);
  if (first == null) return false;
  switch (item.mode) {
    case PaintMode.blur || PaintMode.pixelate:
      if (second == null) return false;
      final box = Rect.fromPoints(first, second).inflate(slop);
      return ovalCensor
          ? _segmentInEllipse(point, b, box)
          : _segmentRectDistance(point, b, box) == 0;
    case PaintMode.line ||
        PaintMode.arrow ||
        PaintMode.dashLine ||
        PaintMode.dashDotLine:
      return _segmentsDistance(point, b, first, second ?? first) <= reach;
    case PaintMode.rect:
      if (second == null) return false;
      final box = Rect.fromPoints(first, second);
      if (item.fill && _segmentRectDistance(point, b, box) <= slop) {
        return true;
      }
      return _rectOutlineDistance(point, b, box) <= reach;
    case PaintMode.circle:
      if (second == null) return false;
      final box = Rect.fromPoints(first, second);
      if (item.fill && _segmentInEllipse(point, b, box.inflate(slop))) {
        return true;
      }
      return _ellipseOutlineDistance(point, b, box) <= reach;
    default:
      return _segmentRectDistance(point, b, item.bounds.inflate(slop)) == 0;
  }
}

/// The first two recorded points of a shape (its start and end).
(Offset?, Offset?) _ends(List<Offset?> offsets) {
  Offset? first;
  for (final offset in offsets) {
    if (offset == null) continue;
    if (first == null) {
      first = offset;
    } else {
      return (first, offset);
    }
  }
  return (first, null);
}

/// A freehand stroke: its points, with null breaking the line.
bool _nearPolyline(List<Offset?> offsets, Offset a, Offset b, double reach) {
  Offset? previous;
  for (final offset in offsets) {
    if (offset == null) {
      previous = null;
      continue;
    }
    if (_segmentsDistance(a, b, previous ?? offset, offset) <= reach) {
      return true;
    }
    previous = offset;
  }
  return false;
}

double _pointSegmentDistance(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final length2 = ab.distanceSquared;
  if (length2 == 0) return (p - a).distance;
  final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / length2).clamp(
    0.0,
    1.0,
  );
  return (p - (a + ab * t)).distance;
}

double _cross(Offset o, Offset a, Offset b) =>
    (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);

bool _segmentsCross(Offset a, Offset b, Offset c, Offset d) {
  final d1 = _cross(c, d, a), d2 = _cross(c, d, b);
  final d3 = _cross(a, b, c), d4 = _cross(a, b, d);
  return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
      ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
}

/// The distance between segments a–b and c–d (either may be a point).
double _segmentsDistance(Offset a, Offset b, Offset c, Offset d) {
  if (_segmentsCross(a, b, c, d)) return 0;
  return math.min(
    math.min(_pointSegmentDistance(a, c, d), _pointSegmentDistance(b, c, d)),
    math.min(_pointSegmentDistance(c, a, b), _pointSegmentDistance(d, a, b)),
  );
}

/// 0 when the segment a–b touches [box] (inside included).
double _segmentRectDistance(Offset a, Offset b, Rect box) {
  if (box.contains(a) || box.contains(b)) return 0;
  return math.min(
    math.min(
      _segmentsDistance(a, b, box.topLeft, box.topRight),
      _segmentsDistance(a, b, box.topRight, box.bottomRight),
    ),
    math.min(
      _segmentsDistance(a, b, box.bottomRight, box.bottomLeft),
      _segmentsDistance(a, b, box.bottomLeft, box.topLeft),
    ),
  );
}

/// The distance from the segment a–b to the outline of [box].
double _rectOutlineDistance(Offset a, Offset b, Rect box) => math.min(
  math.min(
    _segmentsDistance(a, b, box.topLeft, box.topRight),
    _segmentsDistance(a, b, box.topRight, box.bottomRight),
  ),
  math.min(
    _segmentsDistance(a, b, box.bottomRight, box.bottomLeft),
    _segmentsDistance(a, b, box.bottomLeft, box.topLeft),
  ),
);

/// Whether the segment a–b touches the ellipse filling [box]: in the
/// ellipse's own units it is the unit circle.
bool _segmentInEllipse(Offset a, Offset b, Rect box) {
  final rx = box.width / 2, ry = box.height / 2;
  if (rx <= 0 || ry <= 0) return false;
  Offset unit(Offset p) =>
      Offset((p.dx - box.center.dx) / rx, (p.dy - box.center.dy) / ry);
  return _pointSegmentDistance(Offset.zero, unit(a), unit(b)) <= 1;
}

/// The ellipse outline as this many chords: under half a pixel from the
/// curve for a 100-px radius.
const int _ellipseChords = 32;

/// The distance from the segment a–b to the outline of the ellipse in [box].
double _ellipseOutlineDistance(Offset a, Offset b, Rect box) {
  final rx = box.width / 2, ry = box.height / 2;
  final c = box.center;
  var best = double.infinity;
  var previous = Offset(c.dx + rx, c.dy);
  for (var i = 1; i <= _ellipseChords; i++) {
    final t = 2 * math.pi * i / _ellipseChords;
    final next = Offset(c.dx + rx * math.cos(t), c.dy + ry * math.sin(t));
    best = math.min(best, _segmentsDistance(a, b, previous, next));
    if (best == 0) break;
    previous = next;
  }
  return best;
}

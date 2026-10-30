// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:ui' show Size, lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:pro_image_editor/features/main_editor/services/layer_copy_manager.dart';
import 'package:pro_image_editor/features/paint_editor/models/paint_editor_response_model.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

/// The outline of a blur or pixelate area.
enum CensorShape { box, oval }

/// How strongly a censor area hides what is beneath it, from a slider value
/// `t` in 0…1 to the units `PaintedModel.censorStrength` takes for each
/// mode. The weakest setting still hides a face at arm's length.
abstract final class CensorStrength {
  /// The slider's starting point: about the blur the editor shipped with.
  static const double initial = 0.5;

  /// Blur sigma in the area's logical pixels (it scales with the export).
  static const double minBlurSigma = 6;
  static const double maxBlurSigma = 40;

  /// Pixel block edge in logical pixels on screen.
  static const double minBlockDp = 6;
  static const double maxBlockDp = 30;

  static double blurSigma(double t) =>
      lerpDouble(minBlurSigma, maxBlurSigma, t.clamp(0.0, 1.0))!;

  /// The value the package's screen-space pixelate filter takes: it divides
  /// the block size by the device pixel ratio once and draws it in physical
  /// pixels (`pixelate_area_item.dart`, `pixelate.frag`), so a block of `n`
  /// logical pixels is `n · dpr²`.
  static double pixelBlockSize(double t, double devicePixelRatio) {
    final dp = lerpDouble(minBlockDp, maxBlockDp, t.clamp(0.0, 1.0))!;
    return dp * devicePixelRatio * devicePixelRatio;
  }

  /// The censor strength of [mode] at [t]; null for the other modes.
  static double? of(PaintMode mode, double t, double devicePixelRatio) =>
      switch (mode) {
        PaintMode.blur => blurSigma(t),
        PaintMode.pixelate => pixelBlockSize(t, devicePixelRatio),
        _ => null,
      };
}

/// The mask that turns a rectangular censor area into an ellipse filling
/// its box. Censor areas are drawn as rectangles (`enableRoundArea` is
/// global in the package); an oval one carries this mask, which the layer
/// keeps through copies, undo and the export.
const LayerMask censorOvalMask = LayerMask(
  shape: LayerMaskShape.ellipse,
  size: Size(1, 1),
);

/// Whether [layer] is a censor area drawn as an oval.
bool isOvalCensorArea(Layer layer) =>
    layer is PaintLayer &&
    layer.item.isCensorArea &&
    layer.mask?.shape == LayerMaskShape.ellipse;

/// The choices of the Draw and Blur tools while the photo editor is open:
/// which tool the paint editor was opened as, and the shape and strength of
/// the next censor area. Shared by the panel, the canvas overlay and the
/// editor callbacks; it outlives a single opening of the tool.
class PhotoPaintSession extends ChangeNotifier {
  bool _censor = false;
  CensorShape _shape = CensorShape.box;
  double _strength = CensorStrength.initial;

  /// The paint editor was opened as Blur (censor tools), not Draw.
  bool get censor => _censor;
  set censor(bool value) {
    if (value == _censor) return;
    _censor = value;
    notifyListeners();
  }

  CensorShape get shape => _shape;
  set shape(CensorShape value) {
    if (value == _shape) return;
    _shape = value;
    notifyListeners();
  }

  /// The slider value, 0…1 (see [CensorStrength]).
  double get strength => _strength;
  set strength(double value) {
    final clamped = value.clamp(0.0, 1.0);
    if (clamped == _strength) return;
    _strength = clamped;
    notifyListeners();
  }

  /// Gives the censor area [paint] just created the chosen [shape].
  ///
  /// Called right after the stroke is added (the package reports the
  /// drawing before it adds the layer). Only an area drawn in this opening
  /// of the tool and still without a mask is touched; one that somehow
  /// misses its mask stays a rectangle, which hides more, never less.
  void shapeNewArea(PaintEditorState paint) {
    if (_shape != CensorShape.oval || !paint.mounted) return;
    final last = paint.activeHistory.layers.lastOrNull;
    if (last is! PaintLayer || !last.item.isCensorArea || last.mask != null) {
      return;
    }
    if (paint.stateHistory.first.layers.any((layer) => layer.id == last.id)) {
      return;
    }
    last.mask = censorOvalMask;
  }
}

/// Adds [next] to [paint]'s history as a new step (dropping the steps that
/// could be redone) and shows it. The paint editor has no public "add a
/// step": this is what its own eraser does with `stateHistory` and
/// `historyPointer`, with its public redo moving the pointer and rebuilding.
void pushPaintStep(PaintEditorState paint, PaintEditorResponse next) {
  while (paint.canRedo) {
    paint.stateHistory.removeLast();
  }
  paint.stateHistory.add(next);
  paint.redoAction();
}

/// Replaces the step [paint] shows with [next], in one rebuild.
void replacePaintStep(PaintEditorState paint, PaintEditorResponse next) {
  paint.stateHistory[paint.historyPointer] = next;
  // No public refresh either: the same stroke width rebuilds the editor
  // (its body and bars) once and changes nothing else.
  paint.setStrokeWidth(paint.strokeWidth);
}

/// Gives the censor area just drawn in [paint]'s current mode the strength
/// [value], as an undoable step: the area is replaced by a copy (same id)
/// with the new strength, so Undo brings the old one back. Only an area
/// drawn in this opening of the tool and still the newest layer qualifies,
/// as with the package's own `setCensorStrength`, which changes it in place
/// without a step. Returns whether a step was added.
bool setLastAreaStrength(PaintEditorState paint, double? value) {
  final current = paint.activeHistory;
  final last = current.layers.lastOrNull;
  if (last is! PaintLayer ||
      !last.item.isCensorArea ||
      last.item.mode != paint.paintMode ||
      last.item.censorStrength == value ||
      paint.stateHistory.first.layers.any((layer) => layer.id == last.id)) {
    return false;
  }
  final copy = LayerCopyManager().createCopyPaintLayer(last);
  for (final item in copy.items) {
    item.censorStrength = value;
  }
  pushPaintStep(
    paint,
    PaintEditorResponse(
      layers: [...current.layers.take(current.layers.length - 1), copy],
      removedLayers: [...current.removedLayers],
    ),
  );
  return true;
}

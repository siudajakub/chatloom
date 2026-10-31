// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'notion_motion.dart';

/// Glides [child] from where it was drawn to its new place when [trigger]
/// changes (FLIP): the layout switches at once, and the child is painted
/// from its old rectangle (position and size) back to its new one, with a
/// translation and scale only, settling to identity. For a slot that moves
/// when a panel opens beside it (the media stage making room for a
/// transcript).
///
/// Nothing happens while [trigger] stays the same, so moves caused by
/// anything else (a route transition, a resize) are not animated. Taps
/// reach the child where it is drawn. Instant under reduced motion and
/// with tickers off. Non-visual at rest (no golden).
///
/// ```dart
/// NotionLayoutFlip(trigger: transcriptVisible, child: transport)
/// ```
class NotionLayoutFlip extends StatefulWidget {
  const NotionLayoutFlip({
    super.key,
    required this.trigger,
    required this.child,
    this.duration = NotionMotion.medium,
    this.curve = NotionMotion.standard,
  });

  final Object? trigger;
  final Widget child;
  final Duration duration;
  final Curve curve;

  @override
  State<NotionLayoutFlip> createState() => _NotionLayoutFlipState();
}

class _NotionLayoutFlipState extends State<NotionLayoutFlip>
    with SingleTickerProviderStateMixin {
  @override
  Widget build(BuildContext context) => _FlipSlot(
    trigger: widget.trigger,
    vsync: this,
    enabled:
        !NotionMotion.reduced(context) && TickerMode.valuesOf(context).enabled,
    duration: widget.duration,
    curve: widget.curve,
    child: widget.child,
  );
}

class _FlipSlot extends SingleChildRenderObjectWidget {
  const _FlipSlot({
    required this.trigger,
    required this.vsync,
    required this.enabled,
    required this.duration,
    required this.curve,
    required super.child,
  });

  final Object? trigger;
  final TickerProvider vsync;
  final bool enabled;
  final Duration duration;
  final Curve curve;

  @override
  _RenderFlip createRenderObject(BuildContext context) => _RenderFlip(
    trigger: trigger,
    vsync: vsync,
    enabled: enabled,
    duration: duration,
    curve: curve,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderFlip renderObject) =>
      renderObject
        ..vsync = vsync
        ..enabled = enabled
        ..duration = duration
        ..curve = curve
        ..trigger = trigger;
}

class _RenderFlip extends RenderProxyBox {
  _RenderFlip({
    required Object? trigger,
    required this.vsync,
    required this.enabled,
    required this.duration,
    required this.curve,
  }) : _trigger = trigger;

  TickerProvider vsync;
  bool enabled;
  Duration duration;
  Curve curve;

  Object? _trigger;

  /// Where the child was drawn when [trigger] changed (global), waiting for
  /// the new layout.
  Rect? _armed;

  /// The glide in flight: from [_from] to the laid-out rectangle [_to].
  Rect? _from, _to;
  Ticker? _ticker;
  Duration _elapsed = Duration.zero;
  final _layer = LayerHandle<TransformLayer>();

  set trigger(Object? value) {
    if (value == _trigger) return;
    _trigger = value;
    // Read the old place now, before the new layout replaces it.
    if (enabled && attached && hasSize) {
      final current = _visualRect();
      if (current != null) {
        _armed = current;
        markNeedsPaint();
      }
    }
  }

  double get _t {
    if (_from == null) return 1;
    final total = duration.inMicroseconds;
    if (total <= 0) return 1;
    return curve.transform((_elapsed.inMicroseconds / total).clamp(0.0, 1.0));
  }

  Rect? _globalRect() {
    if (!attached || !hasSize) return null;
    final rect = MatrixUtils.transformRect(
      getTransformTo(null),
      Offset.zero & size,
    );
    return rect.isFinite ? rect : null;
  }

  /// Where the child is drawn now (global), including a glide in flight.
  Rect? _visualRect() {
    final laid = _globalRect();
    final from = _from, to = _to;
    if (laid == null || from == null || to == null) return laid;
    final drawn = Rect.lerp(from, to, _t)!;
    // The layout may have moved since; keep the same visual offset.
    return drawn.shift(laid.topLeft - to.topLeft);
  }

  /// The paint transform from the laid-out box to the drawn rectangle, or
  /// null at rest.
  Matrix4? _transform() {
    final from = _from, to = _to;
    if (from == null || to == null || !hasSize || to.isEmpty) return null;
    final t = _t;
    if (t >= 1) return null;
    final drawn = Rect.lerp(from, to, t)!;
    final origin = globalToLocal(drawn.topLeft);
    return Matrix4.translationValues(origin.dx, origin.dy, 0)
      ..scaleByDouble(drawn.width / to.width, drawn.height / to.height, 1, 1);
  }

  void _tick(Duration elapsed) {
    _elapsed = elapsed;
    if (elapsed >= duration) {
      _ticker?.stop();
      _from = null;
      _to = null;
    }
    markNeedsPaint();
  }

  void _start(Rect from, Rect to) {
    if ((from.topLeft - to.topLeft).distance < .5 &&
        (from.width - to.width).abs() < .5 &&
        (from.height - to.height).abs() < .5) {
      _from = _to = null;
      _ticker?.stop();
      return;
    }
    _from = from;
    _to = to;
    _elapsed = Duration.zero;
    final ticker = _ticker ??= vsync.createTicker(_tick);
    if (ticker.isActive) ticker.stop();
    ticker.start();
  }

  @override
  void detach() {
    _ticker?.stop();
    _from = _to = _armed = null;
    super.detach();
  }

  @override
  void dispose() {
    _layer.layer = null;
    _ticker?.dispose();
    _ticker = null;
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final armed = _armed;
    if (armed != null) {
      _armed = null;
      final laid = _globalRect();
      if (laid != null && enabled) {
        _start(armed, laid);
      } else {
        _from = _to = null;
        _ticker?.stop();
      }
    } else if (_from != null) {
      // Keep the target in step with the layout (it may still be settling).
      final laid = _globalRect();
      if (laid != null) _to = laid;
    }
    final transform = _transform();
    if (transform == null || child == null) {
      _layer.layer = null;
      super.paint(context, offset);
      return;
    }
    _layer.layer = context.pushTransform(
      needsCompositing,
      offset,
      transform,
      super.paint,
      oldLayer: _layer.layer,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final transform = _transform();
    if (transform == null) {
      return super.hitTestChildren(result, position: position);
    }
    return result.addWithPaintTransform(
      transform: transform,
      position: position,
      hitTest: (result, position) =>
          super.hitTestChildren(result, position: position),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final flip = _transform();
    if (flip != null) transform.multiply(flip);
    super.applyPaintTransform(child, transform);
  }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import 'notion_motion.dart';

/// Telegram-style entrance of an anchored glass overlay (popover, menu):
/// the panel's glass grows out of the anchor point and its content fades in
/// inside it; on exit the glass collapses back into the anchor.
///
/// The blur is never faded, scaled or toggled: the glass surface keeps one
/// `BackdropFilter` from the first to the last frame, and only its clip (an
/// animated rounded rect, a paint-time property) and the opacity of the
/// content above the blur change. A `BackdropFilter` inside an animating
/// `Opacity` reads an empty layer, and a scaled one changes its blur radius;
/// both showed as a flash (DESIGN.md "Glass").
///
/// [NotionPopoverRoute] (`showNotionPopover`) provides the scope; the first
/// overlay `NotionGlassSurface` below it (every `NotionGlassPanel`) consumes
/// it. Content that is not a glass panel appears without motion.
class NotionGlassReveal extends InheritedWidget {
  const NotionGlassReveal({
    super.key,
    required this.animation,
    required this.origin,
    this.animate = true,
    required super.child,
  }) : _consumed = false;

  const NotionGlassReveal._consumed({required super.child})
    : animation = kAlwaysCompleteAnimation,
      origin = Offset.zero,
      animate = false,
      _consumed = true;

  /// The route animation (linear 0 → 1 on enter, 1 → 0 on exit).
  final Animation<double> animation;

  /// The anchor in global (overlay) coordinates; the glass grows from the
  /// nearest point of the panel to it.
  final Offset origin;

  /// False under reduced motion: the panel shows at once, with its blur.
  final bool animate;

  final bool _consumed;

  /// The reveal for the overlay surface at [context], if one is pending.
  static NotionGlassReveal? maybeOf(BuildContext context) {
    final reveal = context
        .dependOnInheritedWidgetOfExactType<NotionGlassReveal>();
    return reveal == null || reveal._consumed ? null : reveal;
  }

  /// Marks the reveal as used, so nested overlay surfaces do not animate a
  /// second time.
  static Widget consumed({required Widget child}) =>
      NotionGlassReveal._consumed(child: child);

  @override
  bool updateShouldNotify(NotionGlassReveal oldWidget) =>
      !identical(oldWidget.animation, animation) ||
      oldWidget.origin != origin ||
      oldWidget.animate != animate ||
      oldWidget._consumed != _consumed;
}

/// Consumes a [NotionGlassReveal] for one overlay surface: clips the
/// surface to the growing rect and hands [builder] the opacity for the
/// content above the blur. Owns its curves (created once per route
/// animation, disposed with the surface).
class NotionGlassRevealHost extends StatefulWidget {
  const NotionGlassRevealHost({
    super.key,
    required this.reveal,
    required this.borderRadius,
    this.borderColor,
    required this.builder,
  });

  final NotionGlassReveal reveal;
  final BorderRadius borderRadius;
  final Color? borderColor;
  final Widget Function(BuildContext context, Animation<double> content)
  builder;

  @override
  State<NotionGlassRevealHost> createState() => _NotionGlassRevealHostState();
}

class _NotionGlassRevealHostState extends State<NotionGlassRevealHost> {
  CurvedAnimation? _clip;
  CurvedAnimation? _content;

  @override
  void initState() {
    super.initState();
    _curves();
  }

  @override
  void didUpdateWidget(NotionGlassRevealHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.reveal.animation, widget.reveal.animation) ||
        oldWidget.reveal.animate != widget.reveal.animate) {
      _dispose();
      _curves();
    }
  }

  void _curves() {
    if (!widget.reveal.animate) return;
    final parent = widget.reveal.animation;
    // The glass grows out of the anchor on a critically damped spring and
    // accelerates back into it on exit.
    _clip = CurvedAnimation(
      parent: parent,
      curve: NotionMotion.smoothCurve,
      reverseCurve: NotionMotion.standard,
    );
    // Content fades in once the glass has started to grow, and is gone
    // during the first half of the exit.
    _content = CurvedAnimation(
      parent: parent,
      curve: const Interval(.1, .6, curve: NotionMotion.standard),
      reverseCurve: const Interval(.5, 1, curve: NotionMotion.standard),
    );
  }

  void _dispose() {
    _clip?.dispose();
    _content?.dispose();
    _clip = _content = null;
  }

  @override
  void dispose() {
    _dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => NotionGlassReveal.consumed(
    child: NotionRevealClip(
      progress: _clip ?? kAlwaysCompleteAnimation,
      origin: widget.reveal.origin,
      borderRadius: widget.borderRadius,
      borderColor: widget.borderColor,
      child: widget.builder(context, _content ?? kAlwaysCompleteAnimation),
    ),
  );
}

/// Clips [child] to a rounded rect that grows from [origin] to the full
/// box as [progress] goes 0 → 1, and strokes the hairline along that rect
/// while it grows. At 1 it paints [child] untouched, so the resting state is
/// pixel-identical to the unanimated surface. Repaints only; never lays out
/// or rebuilds per frame.
class NotionRevealClip extends SingleChildRenderObjectWidget {
  const NotionRevealClip({
    super.key,
    required this.progress,
    required this.origin,
    required this.borderRadius,
    this.borderColor,
    super.child,
  });

  final Animation<double> progress;

  /// Global (overlay) coordinates; clamped into the box.
  final Offset origin;
  final BorderRadius borderRadius;

  /// Hairline drawn on the moving edge; null draws none.
  final Color? borderColor;

  @override
  RenderNotionRevealClip createRenderObject(BuildContext context) =>
      RenderNotionRevealClip(progress, origin, borderRadius, borderColor);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderNotionRevealClip renderObject,
  ) {
    renderObject
      ..progress = progress
      ..origin = origin
      ..borderRadius = borderRadius
      ..borderColor = borderColor;
  }
}

class RenderNotionRevealClip extends RenderProxyBox {
  RenderNotionRevealClip(
    this._progress,
    this._origin,
    this._borderRadius,
    this._borderColor,
  );

  Animation<double> _progress;
  set progress(Animation<double> value) {
    if (identical(value, _progress)) return;
    if (attached) _progress.removeListener(markNeedsPaint);
    _progress = value;
    if (attached) _progress.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  Offset _origin;
  set origin(Offset value) {
    if (value == _origin) return;
    _origin = value;
    markNeedsPaint();
  }

  BorderRadius _borderRadius;
  set borderRadius(BorderRadius value) {
    if (value == _borderRadius) return;
    _borderRadius = value;
    markNeedsPaint();
  }

  Color? _borderColor;
  set borderColor(Color? value) {
    if (value == _borderColor) return;
    _borderColor = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _progress.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _progress.removeListener(markNeedsPaint);
    super.detach();
  }

  /// Whether the clip is still growing or collapsing.
  bool get revealing => _progress.value < 1;

  /// The current clip in local coordinates (the full box at rest).
  @visibleForTesting
  RRect get currentClip => _clip(_localOrigin());

  Offset _localOrigin() {
    if (!attached || !hasSize) return Offset.zero;
    final full = Offset.zero & size;
    final transform = getTransformTo(null);
    final inverse = Matrix4.tryInvert(transform);
    final local = inverse == null
        ? size.center(Offset.zero)
        : MatrixUtils.transformPoint(inverse, _origin);
    return Offset(
      local.dx.clamp(full.left, full.right),
      local.dy.clamp(full.top, full.bottom),
    );
  }

  RRect _clip(Offset origin) {
    final t = _progress.value.clamp(0.0, 1.0);
    final full = Offset.zero & size;
    final rect = Rect.fromLTRB(
      origin.dx + (full.left - origin.dx) * t,
      origin.dy + (full.top - origin.dy) * t,
      origin.dx + (full.right - origin.dx) * t,
      origin.dy + (full.bottom - origin.dy) * t,
    );
    final max = rect.shortestSide / 2;
    Radius corner(Radius r) =>
        Radius.elliptical(r.x.clamp(0.0, max), r.y.clamp(0.0, max));
    return RRect.fromRectAndCorners(
      rect,
      topLeft: corner(_borderRadius.topLeft),
      topRight: corner(_borderRadius.topRight),
      bottomLeft: corner(_borderRadius.bottomLeft),
      bottomRight: corner(_borderRadius.bottomRight),
    );
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (revealing && !_clip(_localOrigin()).contains(position)) return false;
    return super.hitTest(result, position: position);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    if (!revealing) {
      layer = null;
      context.paintChild(child, offset);
      return;
    }
    final clip = _clip(_localOrigin());
    if (clip.isEmpty) {
      layer = null;
      return;
    }
    layer = context.pushClipRRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      clip,
      (context, offset) => context.paintChild(child, offset),
      oldLayer: layer is ClipRRectLayer ? layer as ClipRRectLayer : null,
    );
    final color = _borderColor;
    if (color != null) {
      context.canvas.drawRRect(
        clip.shift(offset).deflate(.5),
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }
}

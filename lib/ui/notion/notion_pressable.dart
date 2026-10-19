// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import 'notion_motion.dart';

/// Scales [child] down while a pointer is pressed on it and springs it back
/// on release. Purely visual: it listens to raw pointers, so it never joins
/// the gesture arena and works around `InkWell`, `IconButton` or any other
/// tappable. Pass [onTap]/[onLongPress] only for a widget without its own
/// tap handling.
///
/// ```dart
/// NotionPressable(child: InkWell(onTap: open, child: row))
/// NotionPressable(scale: NotionMotion.pressIcon, bounce: true, child: sendButton)
/// ```
///
/// Transform only; no rebuilds per tick. Disabled under reduced motion.
class NotionPressable extends StatefulWidget {
  const NotionPressable({
    super.key,
    required this.child,
    this.scale = NotionMotion.pressButton,
    this.enabled = true,
    this.bounce = false,
    this.onTap,
    this.onLongPress,
    this.hapticOnTap = false,
    this.alignment = Alignment.center,
  });

  final Widget child;

  /// Pressed scale: [NotionMotion.pressButton], `pressIcon` or `pressRow`.
  final double scale;

  /// False keeps the child still (disabled buttons).
  final bool enabled;

  /// Release with [NotionMotion.bouncy]. Only for the send button and other
  /// reward elements; everything else releases critically damped.
  final bool bounce;

  /// Optional tap handler for widgets without their own (wrapped in a
  /// [GestureDetector]).
  final VoidCallback? onTap;

  /// Optional long-press handler; always fires [NotionHaptics.longPress].
  final VoidCallback? onLongPress;

  /// Fire [NotionHaptics.light] on [onTap] (send buttons only).
  final bool hapticOnTap;

  final Alignment alignment;

  @override
  State<NotionPressable> createState() => _NotionPressableState();
}

class _NotionPressableState extends State<NotionPressable>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scale = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );
  bool _down = false;
  Offset _origin = Offset.zero;

  bool get _active =>
      widget.enabled && widget.scale != 1 && !NotionMotion.reduced(context);

  void _press(PointerDownEvent event) {
    if (!_active) return;
    _down = true;
    _origin = event.position;
    _scale.animateTo(
      widget.scale,
      duration: NotionMotion.instant,
      curve: Curves.easeOut,
    );
  }

  /// A drag (list scroll, swipe) is not a press: let go past the touch slop.
  void _move(PointerMoveEvent event) {
    if (_down && (event.position - _origin).distance > kTouchSlop) _release();
  }

  void _release([PointerEvent? event]) {
    if (!_down) return;
    _down = false;
    if (!mounted) return;
    // A quick tap still shows a visible dip before springing back.
    final travelled = (1 - _scale.value) / (1 - widget.scale);
    if (_scale.isAnimating && travelled < .6) {
      _scale
          .animateTo(
            widget.scale,
            duration: NotionMotion.instant * (1 - travelled),
            curve: Curves.easeOut,
          )
          .orCancel
          .then((_) => _springBack(), onError: (_) {});
      return;
    }
    _springBack();
  }

  void _springBack() {
    if (!mounted || _down) return;
    _scale.animateWith(
      NotionMotion.springTo(
        widget.bounce ? NotionMotion.bouncy : NotionMotion.snappy,
        _scale.value,
        1,
        velocity: _scale.velocity,
      ),
    );
  }

  @override
  void didUpdateWidget(NotionPressable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _scale.value != 1) {
      _down = false;
      _scale.value = 1;
    }
  }

  @override
  void dispose() {
    _scale.dispose();
    super.dispose();
  }

  void _tap() {
    if (widget.hapticOnTap) NotionHaptics.light();
    widget.onTap?.call();
  }

  void _longPress() {
    NotionHaptics.longPress();
    widget.onLongPress?.call();
  }

  @override
  Widget build(BuildContext context) {
    var child = widget.child;
    if (widget.onTap != null || widget.onLongPress != null) {
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap == null ? null : _tap,
        onLongPress: widget.onLongPress == null ? null : _longPress,
        child: child,
      );
    }
    return Listener(
      onPointerDown: _press,
      onPointerMove: _move,
      onPointerUp: _release,
      onPointerCancel: _release,
      child: _ScaleTransform(
        scale: _scale,
        alignment: widget.alignment,
        child: child,
      ),
    );
  }
}

/// `Transform.scale` driven by a listenable, without the filter-quality
/// offscreen layer of `ScaleTransition`.
class _ScaleTransform extends AnimatedWidget {
  const _ScaleTransform({
    required Animation<double> scale,
    required this.alignment,
    required this.child,
  }) : super(listenable: scale);

  final Alignment alignment;
  final Widget child;

  @override
  Widget build(BuildContext context) => Transform.scale(
    scale: (listenable as Animation<double>).value,
    alignment: alignment,
    child: child,
  );
}

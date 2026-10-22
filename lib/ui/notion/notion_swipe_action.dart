// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:material_ui/material_ui.dart';

import 'notion_motion.dart';
import 'notion_tokens.dart';

/// One side of a [NotionSwipeAction]: what a swipe in that direction does.
@immutable
class NotionSwipeActionSide {
  const NotionSwipeActionSide({
    required this.icon,
    required this.label,
    required this.onCommit,
  });

  final IconData icon;

  /// Shown next to the icon behind the row and announced as a custom
  /// semantics action.
  final String label;
  final VoidCallback onCommit;
}

/// A list row that follows a horizontal finger swipe and runs an action when
/// released past the arm point (Telegram's dialog swipe, Messenger's swipe
/// actions).
///
/// * [endToStart] (swipe towards the start: left in LTR) and [startToEnd]
///   (towards the end) each reveal an opaque `accentTint` pill behind the row
///   with the action's icon, which scales in as the row moves.
/// * Arms at [armFraction] of the row width, with one
///   `NotionHaptics.selection()` per arming; a release while armed commits,
///   a release before cancels. Either way the row springs back with
///   `NotionMotion.snappy` (instantly under reduced motion).
/// * Touch only, never from the system back-gesture edges (Android
///   predictive back stays the system's), and a mostly vertical drag is left
///   to the list. Off while a screen reader runs: the actions are then
///   custom semantics actions (and the row's long-press menu).
/// * No controller until the first swipe; the row is translated, never
///   rebuilt, while the finger moves.
class NotionSwipeAction extends StatefulWidget {
  const NotionSwipeAction({
    super.key,
    required this.child,
    this.startToEnd,
    this.endToStart,
    this.borderRadius = NotionRadius.rowAll,
    this.armFraction = 0.3,
  });

  final Widget child;
  final NotionSwipeActionSide? startToEnd;
  final NotionSwipeActionSide? endToStart;
  final BorderRadius borderRadius;
  final double armFraction;

  @override
  State<NotionSwipeAction> createState() => _NotionSwipeActionState();
}

class _NotionSwipeActionState extends State<NotionSwipeAction>
    with SingleTickerProviderStateMixin {
  /// Signed offset in logical pixels (positive = towards the right).
  final ValueNotifier<double> _offset = ValueNotifier(0);
  AnimationController? _spring;
  double _width = 0;
  bool _armed = false;

  /// The side the current drag reveals, fixed once the drag has a direction.
  NotionSwipeActionSide? _side;

  bool get _rtl => Directionality.of(context) == TextDirection.rtl;

  /// The side revealed by a drag towards [dx] (screen direction).
  NotionSwipeActionSide? _sideFor(double dx) {
    if (dx == 0) return null;
    final towardsEnd = (dx > 0) != _rtl;
    return towardsEnd ? widget.startToEnd : widget.endToStart;
  }

  AnimationController get _springController =>
      _spring ??= AnimationController.unbounded(vsync: this)
        ..addListener(() => _offset.value = _spring!.value);

  @override
  void dispose() {
    _spring?.dispose();
    _offset.dispose();
    super.dispose();
  }

  bool _pointerAllowed(PointerDownEvent event) {
    if (widget.startToEnd == null && widget.endToStart == null) return false;
    final media = context.getInheritedWidgetOfExactType<MediaQuery>()?.data;
    if (media == null) return true;
    if (media.accessibleNavigation) return false;
    // Leave both platform back edges to the system.
    final left = math.max(16.0, media.systemGestureInsets.left);
    final right = math.max(16.0, media.systemGestureInsets.right);
    return event.position.dx > left &&
        event.position.dx < media.size.width - right;
  }

  void _start(DragStartDetails details) {
    _spring?.stop();
    _armed = false;
    _side = null;
  }

  void _update(DragUpdateDetails details) {
    final next = _offset.value + details.delta.dx;
    final side = _sideFor(next);
    // Only directions with an action move the row.
    if (side == null) {
      _offset.value = 0;
      _setArmed(false);
      return;
    }
    _side = side;
    final limit = _width * 0.75;
    _offset.value = next.clamp(-limit, limit);
    final arm = _width * widget.armFraction;
    // A little hysteresis so the arm point does not flicker.
    if (_offset.value.abs() >= arm) {
      _setArmed(true);
    } else if (_offset.value.abs() < arm * 0.85) {
      _setArmed(false);
    }
  }

  void _setArmed(bool armed) {
    if (armed == _armed) return;
    _armed = armed;
    if (armed) NotionHaptics.selection();
  }

  void _end(DragEndDetails details) {
    final commit = _armed ? _side : null;
    _settle(details.primaryVelocity ?? 0);
    _armed = false;
    if (commit != null) commit.onCommit();
  }

  void _cancel() {
    _armed = false;
    _settle(0);
  }

  void _settle(double velocity) {
    if (_offset.value == 0) return;
    if (NotionMotion.reduced(context)) {
      _spring?.stop();
      _offset.value = 0;
      return;
    }
    final spring = _springController..value = _offset.value;
    spring.animateWith(
      NotionMotion.springTo(
        NotionMotion.snappy,
        _offset.value,
        0,
        velocity: velocity.clamp(-1500.0, 1500.0),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final startToEnd = widget.startToEnd;
    final endToStart = widget.endToStart;
    return Semantics(
      customSemanticsActions: {
        if (endToStart != null)
          CustomSemanticsAction(label: endToStart.label): endToStart.onCommit,
        if (startToEnd != null)
          CustomSemanticsAction(label: startToEnd.label): startToEnd.onCommit,
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          _width = constraints.maxWidth.isFinite ? constraints.maxWidth : 0;
          return RawGestureDetector(
            behavior: HitTestBehavior.translucent,
            gestures: {
              _SwipeDragRecognizer:
                  GestureRecognizerFactoryWithHandlers<_SwipeDragRecognizer>(
                    () => _SwipeDragRecognizer(_pointerAllowed),
                    (recognizer) => recognizer
                      ..onStart = _start
                      ..onUpdate = _update
                      ..onEnd = _end
                      ..onCancel = _cancel,
                  ),
            },
            child: ValueListenableBuilder<double>(
              valueListenable: _offset,
              child: widget.child,
              builder: (context, offset, child) {
                if (offset == 0) return child!;
                final side = _sideFor(offset);
                return Stack(
                  children: [
                    if (side != null)
                      Positioned.fill(
                        child: _SwipeBackground(
                          side: side,
                          offset: offset,
                          width: _width,
                          armFraction: widget.armFraction,
                          borderRadius: widget.borderRadius,
                        ),
                      ),
                    Transform.translate(
                      offset: Offset(offset, 0),
                      child: child,
                    ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// The action pill behind a moving row: icon and label on the side the row
/// leaves uncovered, the icon growing in until the arm point.
class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({
    required this.side,
    required this.offset,
    required this.width,
    required this.armFraction,
    required this.borderRadius,
  });

  final NotionSwipeActionSide side;
  final double offset;
  final double width;
  final double armFraction;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    final arm = width * armFraction;
    final progress = arm <= 0 ? 1.0 : (offset.abs() / arm).clamp(0.0, 1.0);
    final scale = 0.6 + 0.4 * progress;
    // The uncovered side: left when the row moves right.
    final alignment = offset > 0 ? Alignment.centerLeft : Alignment.centerRight;
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.notion.palette.accentTint,
          borderRadius: borderRadius,
        ),
        child: Align(
          alignment: alignment,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: NotionSpace.md),
            child: Opacity(
              opacity: progress,
              child: Transform.scale(
                scale: scale,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      side.icon,
                      size: NotionSize.iconLg,
                      color: colors.text,
                    ),
                    const SizedBox(height: NotionSpace.xxs),
                    Text(
                      side.label,
                      maxLines: 1,
                      style: NotionType.caption.copyWith(color: colors.text),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SwipeDragRecognizer extends HorizontalDragGestureRecognizer {
  _SwipeDragRecognizer(this.allowed)
    : super(
        supportedDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
        },
      );

  final bool Function(PointerDownEvent) allowed;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      event is PointerDownEvent &&
      allowed(event) &&
      super.isPointerAllowed(event);
}

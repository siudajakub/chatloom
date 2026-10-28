// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
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
    this.dismisses = false,
  });

  final IconData icon;

  /// The action removes the row from its list (archive in the inbox):
  /// a committed swipe carries the row off the screen and collapses its slot
  /// before [onCommit] runs, so the rows below glide up instead of jumping
  /// (Telegram). Should the row still be there a moment later (the action
  /// was refused), it grows and slides back.
  final bool dismisses;

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
/// * A side that [NotionSwipeActionSide.dismisses] flies off and collapses
///   its slot before it commits (instantly under reduced motion).
/// * No controller until the first swipe; the row is translated, never
///   rebuilt, while the finger moves, and its element tree has the same
///   shape at rest and in motion, so starting or ending a swipe never
///   remounts the row (images, presses and highlights keep their state).
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
    with TickerProviderStateMixin {
  /// Signed offset in logical pixels (positive = towards the right).
  final ValueNotifier<double> _offset = ValueNotifier(0);
  AnimationController? _spring;

  /// Height factor of the slot: 1 at rest, 0 once a dismissing swipe has
  /// collapsed it.
  final ValueNotifier<double> _extent = ValueNotifier(1);
  AnimationController? _collapse;
  AnimationController? _hold;
  double _width = 0;
  bool _armed = false;

  /// A dismissing swipe is running (fly off, collapse, wait, maybe return):
  /// new drags are ignored until it is over.
  bool _dismissing = false;

  /// How long a collapsed row waits for its list to drop it before it comes
  /// back (the action was refused or did not remove it).
  static const Duration _dismissHold = Duration(milliseconds: 700);

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

  AnimationController get _collapseController => _collapse ??=
      AnimationController(vsync: this, duration: NotionMotion.short, value: 1)
        ..addListener(
          () => _extent.value = NotionMotion.standard.transform(
            _collapse!.value.clamp(0.0, 1.0),
          ),
        );

  @override
  void dispose() {
    _spring?.dispose();
    _collapse?.dispose();
    _hold?.dispose();
    _offset.dispose();
    _extent.dispose();
    super.dispose();
  }

  bool _pointerAllowed(PointerDownEvent event) {
    if (_dismissing) return false;
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
    final velocity = details.primaryVelocity ?? 0;
    _armed = false;
    if (commit != null &&
        commit.dismisses &&
        _width > 0 &&
        !NotionMotion.reduced(context)) {
      unawaited(_dismiss(commit, velocity));
      return;
    }
    _settle(velocity);
    if (commit != null) commit.onCommit();
  }

  /// Fly off in the swipe's direction, collapse the slot, then commit; if the
  /// row is still mounted after [_dismissHold], grow and slide it back.
  /// Controller timelines only (no timers); a disposed controller never
  /// completes its future, so nothing runs after the row left the tree.
  Future<void> _dismiss(NotionSwipeActionSide side, double velocity) async {
    _dismissing = true;
    // Far enough that no part of the row stays in the list's side padding.
    final travel = math.max(_width, MediaQuery.sizeOf(context).width);
    final target = _offset.value.sign * travel;
    final spring = _springController..value = _offset.value;
    // The slot starts closing as soon as the row has left it; the spring's
    // invisible tail off screen is not waited for.
    final gone = Completer<void>();
    void watch() {
      if (_offset.value.abs() >= _width && !gone.isCompleted) gone.complete();
    }

    _offset.addListener(watch);
    unawaited(
      spring
          .animateWith(
            NotionMotion.springTo(
              NotionMotion.snappy,
              _offset.value,
              target,
              velocity: velocity.clamp(-3000.0, 3000.0),
            ),
          )
          .then((_) {
            if (!gone.isCompleted) gone.complete();
          }),
    );
    await gone.future;
    if (!mounted) return;
    _offset.removeListener(watch);
    final collapse = _collapseController;
    await collapse.animateBack(0, curve: Curves.linear);
    if (!mounted) return;
    side.onCommit();
    // The list normally drops the row within a frame or two. The wait is a
    // controller timeline (it draws nothing), never a timer.
    final hold = _hold ??= AnimationController(
      vsync: this,
      duration: _dismissHold,
    );
    await hold.forward(from: 0);
    if (!mounted) return;
    if (NotionMotion.reduced(context)) {
      _spring?.stop();
      _offset.value = 0;
      collapse.value = 1;
      _dismissing = false;
      return;
    }
    await collapse.forward();
    if (!mounted) return;
    _settle(0);
    _dismissing = false;
  }

  void _cancel() {
    if (_dismissing) return;
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
            // One tree shape at rest and in motion: returning the bare row
            // at offset 0 and a Stack otherwise remounted the whole row on
            // every swipe start and end.
            child: ValueListenableBuilder<double>(
              valueListenable: _extent,
              child: ValueListenableBuilder<double>(
                valueListenable: _offset,
                child: widget.child,
                builder: (context, offset, child) {
                  final side = offset == 0 ? null : _sideFor(offset);
                  return Stack(
                    fit: StackFit.passthrough,
                    children: [
                      Positioned.fill(
                        child: side == null
                            ? const SizedBox.shrink()
                            : _SwipeBackground(
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
              builder: (context, extent, child) =>
                  _CollapseBox(factor: extent, child: child),
            ),
          );
        },
      ),
    );
  }
}

/// Lays its child out with the incoming constraints (a tight list width
/// stays tight) and takes [factor] of its height, clipped while below 1:
/// the slot of a dismissed row closes and the rows below glide up.
class _CollapseBox extends SingleChildRenderObjectWidget {
  const _CollapseBox({required this.factor, super.child});

  final double factor;

  @override
  _RenderCollapseBox createRenderObject(BuildContext context) =>
      _RenderCollapseBox(factor);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderCollapseBox renderObject,
  ) => renderObject.factor = factor;
}

class _RenderCollapseBox extends RenderProxyBox {
  _RenderCollapseBox(this._factor);

  double _factor;
  set factor(double value) {
    final next = value.clamp(0.0, 1.0);
    if (next == _factor) return;
    _factor = next;
    markNeedsLayout();
  }

  final LayerHandle<ClipRectLayer> _clip = LayerHandle<ClipRectLayer>();

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(
      Size(child.size.width, child.size.height * _factor),
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      _factor >= 1 && super.hitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || _factor <= 0) {
      _clip.layer = null;
      return;
    }
    if (_factor >= 1) {
      _clip.layer = null;
      super.paint(context, offset);
      return;
    }
    _clip.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      super.paint,
      oldLayer: _clip.layer,
    );
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
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

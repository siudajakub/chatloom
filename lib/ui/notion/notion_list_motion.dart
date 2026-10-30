// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'notion_motion.dart';

/// Moves the rows of a lazily built list when its content changes, instead
/// of cutting: a row whose position changed glides from where it was to
/// where it is now (on [NotionMotion.snappy], keeping its velocity when the
/// list changes again mid-flight), and a row that appears in a changed list
/// fades in ([NotionMotion.short]). Rows below a removed row close the gap
/// the same way. Telegram's inbox: a chat that receives a message moves to
/// the top while the rows above it slide down by one.
///
/// Transform and opacity only (FLIP): the list is laid out once in its new
/// order and every [NotionListMotionItem] paints itself offset from its old
/// place back to rest; nothing relayouts per frame and a row's content (a
/// repaint boundary) is never repainted while it moves. Scrolling never
/// animates: only a change of [order] does. A change of [epoch] (another
/// view, filter or network, the end of the first load) takes the new layout
/// as it is, so a whole list swap never flies around. Nothing moves under
/// reduced motion or while tickers are off (a covered page): such a change
/// is taken as is, too.
///
/// While a row moves it paints [background] behind itself, so a row that
/// travels past others slides under them cleanly instead of overlapping
/// their text (rows are transparent on the page). Pass the colour the list
/// sits on.
///
/// Every item must be a direct child of the list delegate, which must not
/// add its own repaint boundaries or semantic indexes (the item adds both
/// inside itself, so taps and semantics follow the row while it moves):
///
/// ```dart
/// NotionListMotion(
///   order: [for (final room in rooms) room.id],
///   epoch: (view, network),
///   background: Theme.of(context).scaffoldBackgroundColor,
///   child: CustomScrollView(slivers: [
///     SliverList(
///       delegate: SliverChildBuilderDelegate(
///         (context, i) => NotionListMotionItem(key: ValueKey(rooms[i].id),
///             index: i, child: Row(rooms[i])),
///         childCount: rooms.length,
///         addRepaintBoundaries: false,
///         addSemanticIndexes: false,
///         findChildIndexCallback: indexOfKey,
///       ),
///     ),
///   ]),
/// )
/// ```
class NotionListMotion extends StatefulWidget {
  const NotionListMotion({
    super.key,
    required this.order,
    required this.child,
    this.epoch,
    this.background,
  });

  /// The identities of the rows, in order. A change starts the motion.
  final List<Object?> order;

  /// A change resets: the next layout is taken without motion.
  final Object? epoch;

  /// Painted behind a moving row (the colour the list sits on).
  final Color? background;

  final Widget child;

  @override
  State<NotionListMotion> createState() => _NotionListMotionState();
}

/// What the items of one [NotionListMotion] read when they paint.
final class _ListMotionTracker {
  /// Bumped on every change of the order or the epoch.
  int generation = 0;

  /// The last generation that must be taken as is (an epoch change, or a
  /// change while motion was off). Positions recorded before it are stale.
  int resetGeneration = 0;

  /// Motion allowed (not reduced, tickers on).
  bool enabled = false;

  /// The order changed in the frame being drawn: rows built in it are new
  /// to the list and fade in.
  bool changing = false;

  /// The last frame ([_FrameClock]) in which rows of the list were painted,
  /// and its value when the order last changed: only rows painted in that
  /// frame were on screen, so only they glide. A row that was built ahead
  /// in the cache extent (or not painted for a while) takes its new place
  /// as is when it scrolls in, instead of gliding from a stale position.
  int lastPaint = -1;
  int paintBeforeChange = -1;

  Color? background;
}

class _NotionListMotionState extends State<NotionListMotion> {
  final _tracker = _ListMotionTracker();
  late List<Object?> _order = widget.order;
  late Object? _epoch = widget.epoch;

  @override
  Widget build(BuildContext context) {
    final tracker = _tracker
      ..enabled =
          !NotionMotion.reduced(context) && TickerMode.valuesOf(context).enabled
      ..background = widget.background;
    if (widget.epoch != _epoch) {
      tracker.resetGeneration = ++tracker.generation;
    } else if (!identical(widget.order, _order) &&
        !listEquals(widget.order, _order)) {
      tracker.generation++;
      tracker.paintBeforeChange = tracker.lastPaint;
      if (!tracker.enabled) {
        tracker.resetGeneration = tracker.generation;
      } else if (!tracker.changing) {
        tracker.changing = true;
        SchedulerBinding.instance.addPostFrameCallback(
          (_) => tracker.changing = false,
        );
      }
    }
    _order = widget.order;
    _epoch = widget.epoch;
    return _ListMotionScope(tracker: tracker, child: widget.child);
  }
}

class _ListMotionScope extends InheritedWidget {
  const _ListMotionScope({required this.tracker, required super.child});

  final _ListMotionTracker tracker;

  // The tracker is read at paint time; nothing rebuilds on its changes.
  @override
  bool updateShouldNotify(_ListMotionScope oldWidget) =>
      !identical(oldWidget.tracker, tracker);
}

/// One row of a [NotionListMotion] list: glides when its position in the
/// list changed and fades in when it appeared with a change. Wraps [child]
/// in the [IndexedSemantics] (with [index]) and [RepaintBoundary] the list
/// delegate would add. Outside a [NotionListMotion] it is just those. Give
/// it the row's key so the list keeps its element.
class NotionListMotionItem extends StatefulWidget {
  const NotionListMotionItem({
    super.key,
    required this.index,
    required this.child,
  });

  /// The row's semantic index (the delegate's default is the list index).
  final int index;

  final Widget child;

  @override
  State<NotionListMotionItem> createState() => _NotionListMotionItemState();
}

// The state is only the ticker provider; the render object creates its
// ticker on the first motion, so rows that never move cost none.
class _NotionListMotionItemState extends State<NotionListMotionItem>
    with SingleTickerProviderStateMixin {
  @override
  Widget build(BuildContext context) => _ListMotionSlot(
    tracker: context.getInheritedWidgetOfExactType<_ListMotionScope>()?.tracker,
    vsync: this,
    child: IndexedSemantics(
      index: widget.index,
      child: RepaintBoundary(child: widget.child),
    ),
  );
}

class _ListMotionSlot extends SingleChildRenderObjectWidget {
  const _ListMotionSlot({
    required this.tracker,
    required this.vsync,
    required super.child,
  });

  final _ListMotionTracker? tracker;
  final TickerProvider vsync;

  @override
  _RenderListMotionSlot createRenderObject(BuildContext context) =>
      _RenderListMotionSlot(tracker: tracker, vsync: vsync);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderListMotionSlot renderObject,
  ) => renderObject
    ..tracker = tracker
    ..vsync = vsync;
}

/// A moving row is at rest once it is within a quarter pixel and slow.
const _restTolerance = Tolerance(distance: .25, velocity: 20);

/// Numbers frames: the counter moves on after each frame was drawn, so
/// everything painted in one frame reads the same value.
abstract final class _FrameClock {
  static int _frame = 0;
  static bool _started = false;

  static int get frame {
    if (!_started) {
      _started = true;
      SchedulerBinding.instance.addPersistentFrameCallback((_) => _frame++);
    }
    return _frame;
  }
}

class _RenderListMotionSlot extends RenderProxyBox {
  _RenderListMotionSlot({
    required _ListMotionTracker? tracker,
    required this.vsync,
  }) : _tracker = tracker;

  _ListMotionTracker? _tracker;
  set tracker(_ListMotionTracker? value) {
    if (identical(value, _tracker)) return;
    _tracker = value;
    _forget();
  }

  TickerProvider vsync;

  /// Position along the list's main axis at the last paint, and the
  /// generation it belongs to.
  double? _at;
  int _generation = 0;
  int _painted = -1;

  Ticker? _ticker;
  Duration _now = Duration.zero;

  /// Main-axis offset from the laid-out place back to rest (pixels).
  SpringSimulation? _move;
  Duration _moveStart = Duration.zero;

  Duration? _fadeStart;

  /// +1 when scroll offsets grow down/right on screen, -1 when reversed.
  double _sign = 1;
  Axis _axis = Axis.vertical;

  final _opacityLayer = LayerHandle<OpacityLayer>();

  double get _elapsedMove =>
      (_now - _moveStart).inMicroseconds / Duration.microsecondsPerSecond;

  double get _offset {
    final move = _move;
    return move == null ? 0 : move.x(_elapsedMove);
  }

  double get _opacity {
    final start = _fadeStart;
    if (start == null) return 1;
    final t = (_now - start).inMicroseconds / NotionMotion.short.inMicroseconds;
    return NotionMotion.standard.transform(t.clamp(0.0, 1.0));
  }

  Offset get _shift {
    final value = _offset * _sign;
    return _axis == Axis.vertical ? Offset(0, value) : Offset(value, 0);
  }

  /// The layout offset the enclosing sliver list gave this row, or null
  /// when it is not a row of one.
  double? _layoutOffset() {
    RenderObject? node = this;
    for (var depth = 0; node != null && depth < 4; depth++) {
      final data = node.parentData;
      final parent = node.parent;
      if (data is SliverMultiBoxAdaptorParentData) {
        if (parent is RenderSliver) {
          final constraints = parent.constraints;
          _axis = constraints.axis;
          final direction = applyGrowthDirectionToAxisDirection(
            constraints.axisDirection,
            constraints.growthDirection,
          );
          _sign =
              direction == AxisDirection.up || direction == AxisDirection.left
              ? -1
              : 1;
        }
        return data.layoutOffset;
      }
      if (parent is RenderSliver) return null;
      node = parent;
    }
    return null;
  }

  void _observe() {
    final tracker = _tracker;
    if (tracker == null) return;
    final at = _layoutOffset();
    if (at == null) return;
    final generation = tracker.generation;
    final frame = _FrameClock.frame;
    final last = _at;
    if (last == null) {
      if (tracker.enabled && tracker.changing) _startFade();
    } else if (generation != _generation && at != last) {
      if (tracker.enabled &&
          _generation >= tracker.resetGeneration &&
          _painted == tracker.paintBeforeChange) {
        _startMove(last - at);
      } else {
        _stop();
      }
    }
    _at = at;
    _generation = generation;
    _painted = tracker.lastPaint = frame;
  }

  void _startMove(double delta) {
    final move = _move;
    final elapsed = _elapsedMove;
    final from = (move?.x(elapsed) ?? 0) + delta;
    if (from.abs() < .5) return;
    _move = SpringSimulation(
      NotionMotion.snappy,
      from,
      0,
      move?.dx(elapsed) ?? 0,
      tolerance: _restTolerance,
      snapToEnd: true,
    );
    _run(fade: false);
  }

  void _startFade() => _run(fade: true);

  void _run({required bool fade}) {
    final ticker = _ticker ??= vsync.createTicker(_tick);
    // A stopped ticker restarts its clock; nothing else is in flight then.
    if (!ticker.isActive) {
      _now = Duration.zero;
      ticker.start();
    }
    if (fade) {
      _fadeStart = _now;
    } else {
      _moveStart = _now;
    }
  }

  void _tick(Duration elapsed) {
    _now = elapsed;
    final moving = _move != null && !_move!.isDone(_elapsedMove);
    final fading = _fadeStart != null && _opacity < 1;
    if (!moving) _move = null;
    if (!fading) _fadeStart = null;
    if (!moving && !fading) _ticker?.stop();
    markNeedsPaint();
  }

  void _stop() {
    _move = null;
    _fadeStart = null;
    _ticker?.stop();
  }

  void _forget() {
    _stop();
    _at = null;
  }

  @override
  void detach() {
    _forget();
    super.detach();
  }

  @override
  void dispose() {
    _opacityLayer.layer = null;
    _ticker?.dispose();
    _ticker = null;
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _observe();
    final child = this.child;
    if (child == null) return;
    final shift = _shift;
    final opacity = _opacity;
    final origin = offset + shift;
    final background = _tracker?.background;
    if (shift != Offset.zero && background != null) {
      context.canvas.drawRect(origin & size, Paint()..color = background);
    }
    if (opacity >= 1) {
      _opacityLayer.layer = null;
      context.paintChild(child, origin);
      return;
    }
    _opacityLayer.layer = context.pushOpacity(
      origin,
      (opacity * 255).round(),
      (context, offset) => context.paintChild(child, offset),
      oldLayer: _opacityLayer.layer,
    );
  }

  // Taps reach the row where it is drawn: the list asks rows by their
  // laid-out place, so a moving row answers for its visible place instead.
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final shift = _shift;
    if (shift == Offset.zero) return super.hitTest(result, position: position);
    return result.addWithPaintOffset(
      offset: shift,
      position: position,
      hitTest: (result, transformed) =>
          super.hitTest(result, position: transformed),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final shift = _shift;
    if (shift != Offset.zero) {
      transform.translateByDouble(shift.dx, shift.dy, 0, 1);
    }
  }
}

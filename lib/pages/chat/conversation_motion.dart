// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout, kTouchSlop;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Motion policy shared by conversation components. Delegates to the single
/// app-wide check ([NotionMotion.reduced]), which depends only on the
/// `disableAnimations` aspect of the MediaQuery and also honours the platform
/// Reduce Motion flag.
abstract final class ConversationMotion {
  static bool reduced(BuildContext context) => NotionMotion.reduced(context);

  /// Length of a new message's arrival (slot growth, rise, scale and fade).
  static const Duration arrival = NotionMotion.long;

  /// Start scale of an arriving bubble; it grows from its tail corner.
  static const double arrivalFrom = .92;

  /// Length of a deleted message's exit (fade, shrink, slot closing).
  static const Duration departure = NotionMotion.medium;

  /// Length of an edited or deleted bubble's size change.
  static const Duration contentMorph = NotionMotion.medium;

  /// How long the message a jump landed on stays highlighted before it
  /// fades (Telegram holds 1 s; with the rise and fade about 1.5 s).
  static const Duration flashHold = Duration(milliseconds: 1000);

  /// How long the floating date pill stays once the list is idle before it
  /// fades (Telegram 500 ms, Signal 400 ms).
  static const Duration dateHold = Duration(milliseconds: 500);

  /// Duration for an `AnimatedSize`: [duration], or a single microsecond
  /// under reduced motion. A zero-length `AnimatedSize` completes inside its
  /// own layout and throws ("mutated in its own performLayout"); one
  /// microsecond lands on the next frame, so nothing visibly animates.
  static Duration sizeDuration(BuildContext context, Duration duration) =>
      reduced(context) ? const Duration(microseconds: 1) : duration;
}

enum _EntranceMode { rest, arrive, leave }

/// Entrance of one timeline row.
///
/// * [animate] (only the genuinely new message, decided by the timeline):
///   the row's slot grows from zero height, so older messages glide up
///   instead of jumping, while the bubble rises out of the composer, fades in
///   and scales up from its tail corner ([outgoing] decides the side).
/// * Everything else is still: the rows of a freshly opened chat render
///   during the page push (Telegram), and history, paging, decryption,
///   edits, reactions and rows built by scrolling never animate; a rebuild
///   never replays the entrance.
///
/// Transform/opacity plus one size factor; settles to identity (no layers at
/// rest), instant under reduced motion. The widget tree never changes shape,
/// so the row's state (media, gestures) survives the animation.
///
/// [leave] plays the opposite for a message the user deletes: the bubble
/// fades and shrinks into its centre while its slot closes, so the rows
/// around glide together before the list drops the row (Telegram).
class ConversationMessageEntrance extends StatefulWidget {
  const ConversationMessageEntrance({
    super.key,
    required this.child,
    required this.identity,
    this.animate = false,
    this.outgoing = false,
  });

  final Widget child;
  final Object identity;
  final bool animate;
  final bool outgoing;

  /// Mounted rows by [identity] (a message may show in two lists).
  static final Map<Object, Set<_ConversationMessageEntranceState>> _rows = {};

  /// Plays the exit of the rows showing any of [identities] (event and
  /// transaction ID). Null when nothing is on screen to animate or motion is
  /// reduced, so the caller can remove the message synchronously.
  static Future<void>? leave(Iterable<Object?> identities) {
    final exits = [
      for (final state in _statesOf(identities))
        if (state.mounted && !ConversationMotion.reduced(state.context))
          state._leave(),
    ];
    if (exits.isEmpty) return null;
    return Future.wait(exits).then((_) {});
  }

  /// Puts rows that [leave] collapsed back at rest (the deletion failed and
  /// the message stays).
  static void restore(Iterable<Object?> identities) {
    for (final state in _statesOf(identities)) {
      state._restore();
    }
  }

  static Set<_ConversationMessageEntranceState> _statesOf(
    Iterable<Object?> identities,
  ) => {
    for (final id in identities)
      if (id != null) ...?_rows[id],
  };

  @override
  State<ConversationMessageEntrance> createState() =>
      _ConversationMessageEntranceState();
}

class _ConversationMessageEntranceState
    extends State<ConversationMessageEntrance>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _arriveFade = Interval(0, .45, curve: NotionMotion.standard);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: ConversationMotion.arrival,
    value: 1,
  );
  _EntranceMode _mode = _EntranceMode.rest;
  bool _initialized = false;
  Completer<void>? _left;

  static const _leaveFade = Interval(0, .6, curve: NotionMotion.standard);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _register(widget.identity);
  }

  void _register(Object identity) =>
      (ConversationMessageEntrance._rows[identity] ??= {}).add(this);

  void _unregister(Object identity) {
    final states = ConversationMessageEntrance._rows[identity];
    states?.remove(this);
    if (states != null && states.isEmpty) {
      ConversationMessageEntrance._rows.remove(identity);
    }
  }

  Future<void> _leave() {
    final pending = _left;
    if (pending != null) return pending.future;
    final left = _left = Completer<void>();
    setState(() => _mode = _EntranceMode.leave);
    _controller
        .animateBack(0, duration: ConversationMotion.departure)
        .whenCompleteOrCancel(() {
          if (!left.isCompleted) left.complete();
        });
    return left.future;
  }

  void _restore() {
    if (_mode != _EntranceMode.leave) return;
    _finishLeave();
    setState(() => _mode = _EntranceMode.rest);
    _controller.value = 1;
  }

  void _finishLeave() {
    final left = _left;
    _left = null;
    if (left != null && !left.isCompleted) left.complete();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      _start();
    } else if (_mode != _EntranceMode.leave &&
        ConversationMotion.reduced(context)) {
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(ConversationMessageEntrance oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity) {
      _unregister(oldWidget.identity);
      _register(widget.identity);
      _finishLeave();
      _start();
    }
  }

  void _start() {
    if (ConversationMotion.reduced(context) || !widget.animate) {
      _mode = _EntranceMode.rest;
      _controller.value = 1;
      return;
    }
    _mode = _EntranceMode.arrive;
    _controller.forward(from: 0);
  }

  @override
  void didChangeAccessibilityFeatures() {
    if (mounted &&
        _mode != _EntranceMode.leave &&
        ConversationMotion.reduced(context)) {
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unregister(widget.identity);
    _finishLeave();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tail =
        (widget.outgoing
                ? AlignmentDirectional.bottomEnd
                : AlignmentDirectional.bottomStart)
            .resolve(Directionality.maybeOf(context));
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final t = _controller.value;
        var height = 1.0;
        var opacity = 1.0;
        var scale = 1.0;
        if (_mode == _EntranceMode.leave) {
          // Leaving: the bubble fades and shrinks into its centre while
          // the slot closes around it.
          final p = NotionMotion.standard.transform(1 - t);
          return Align(
            heightFactor: (1 - p).clamp(0.0, 1.0),
            widthFactor: 1,
            child: Opacity(
              opacity: (1 - _leaveFade.transform(1 - t)).clamp(0.0, 1.0),
              child: Transform.scale(
                scale: 1 - (1 - ConversationMotion.arrivalFrom) * p,
                child: child,
              ),
            ),
          );
        }
        if (t < 1 && _mode == _EntranceMode.arrive) {
          height = NotionMotion.emphasized.transform(t);
          opacity = _arriveFade.transform(t);
          final spring = NotionMotion.snappyCurve.transform(t);
          scale =
              ConversationMotion.arrivalFrom +
              (1 - ConversationMotion.arrivalFrom) * spring;
        }
        // The slot grows from its bottom edge (the list is reversed), and
        // the bubble sits at the slot's top, so it rises with the slot.
        return Align(
          alignment: Alignment.topCenter,
          heightFactor: height.clamp(0.0, 1.0),
          widthFactor: 1,
          child: Opacity(
            opacity: opacity.clamp(0.0, 1.0),
            child: Transform.scale(scale: scale, alignment: tail, child: child),
          ),
        );
      },
    );
  }
}

/// The one-shot flash of a message the user jumped to (a reply quote, a
/// pinned message, a search hit), Telegram's `startMessageUnselect`: the
/// highlight comes up quickly, holds for [ConversationMotion.flashHold] and
/// fades out, about 1.5 s in all. It plays when [active] turns true (or the
/// row is built while it is true) and always finishes, even if [active]
/// turns false meanwhile; a later jump to the same message plays it again.
/// [builder] receives 0 at rest and 1 at the peak. Under reduced motion the
/// highlight appears and disappears without a fade, after the same hold.
///
/// No controller exists until the first flash, and the subtree is always
/// wrapped by the same [ValueListenableBuilder], so the row keeps its state.
class ConversationFlash extends StatefulWidget {
  const ConversationFlash({
    super.key,
    required this.active,
    required this.builder,
    this.child,
  });

  final bool active;
  final ValueWidgetBuilder<double> builder;
  final Widget? child;

  @override
  State<ConversationFlash> createState() => _ConversationFlashState();
}

class _ConversationFlashState extends State<ConversationFlash>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<double> _value = ValueNotifier(0);
  AnimationController? _controller;
  Animatable<double>? _sequence;

  static Animatable<double> _timeline({required bool reduced}) {
    final hold = ConversationMotion.flashHold.inMilliseconds.toDouble();
    if (reduced) {
      return TweenSequence<double>([
        TweenSequenceItem<double>(
          tween: ConstantTween<double>(1),
          weight: hold,
        ),
        TweenSequenceItem<double>(tween: ConstantTween<double>(0), weight: 1),
      ]);
    }
    return TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0,
          end: 1,
        ).chain(CurveTween(curve: NotionMotion.standard)),
        weight: NotionMotion.quick.inMilliseconds.toDouble(),
      ),
      TweenSequenceItem<double>(tween: ConstantTween<double>(1), weight: hold),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1,
          end: 0,
        ).chain(CurveTween(curve: NotionMotion.standard)),
        weight: NotionMotion.long.inMilliseconds.toDouble(),
      ),
    ]);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller == null && widget.active) _play();
  }

  @override
  void didUpdateWidget(ConversationFlash oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _play();
  }

  void _play() {
    final reduced = ConversationMotion.reduced(context);
    final sequence = _sequence = _timeline(reduced: reduced);
    var controller = _controller;
    if (controller == null) {
      controller = _controller = AnimationController(vsync: this);
      controller.addListener(
        () => _value.value = _sequence!.transform(_controller!.value),
      );
    }
    controller.duration = reduced
        ? ConversationMotion.flashHold
        : NotionMotion.quick + ConversationMotion.flashHold + NotionMotion.long;
    _value.value = sequence.transform(0);
    controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller?.dispose();
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
    valueListenable: _value,
    builder: widget.builder,
    child: widget.child,
  );
}

/// Base for conversation micro-motion that must not cost a controller per
/// timeline row: the controller is created on the first change only, and the
/// subtree is always wrapped by the same [ValueListenableBuilder], so the
/// child's state survives when animation starts.
mixin _LazyMotion<T extends StatefulWidget>
    on State<T>, SingleTickerProviderStateMixin<T> {
  late final ValueNotifier<double> value = ValueNotifier(initialValue);
  AnimationController? _controller;

  double get initialValue;

  AnimationController controller() =>
      _controller ??= AnimationController.unbounded(
        vsync: this,
        value: value.value,
      )..addListener(() => value.value = _controller!.value);

  @override
  void dispose() {
    _controller?.dispose();
    value.dispose();
    super.dispose();
  }
}

/// Scale feedback for a message surface: while a finger rests on the bubble
/// it slowly sinks toward [scale] over the long-press time (nothing visible
/// for a quick tap or a scroll), then springs back on release. Raw pointers
/// only, so it never competes with the bubble's own gestures.
class ConversationPressScale extends StatefulWidget {
  const ConversationPressScale({
    super.key,
    required this.child,
    this.enabled = true,
    this.scale = NotionMotion.pressButton,
    this.alignment = Alignment.center,
  });

  final Widget child;
  final bool enabled;
  final double scale;
  final Alignment alignment;

  @override
  State<ConversationPressScale> createState() => _ConversationPressScaleState();
}

class _ConversationPressScaleState extends State<ConversationPressScale>
    with SingleTickerProviderStateMixin, _LazyMotion {
  // A quick tap (or the start of a scroll) shows nothing; the bubble starts
  // sinking once the touch is clearly a hold.
  static const _sink = Interval(.2, 1, curve: Curves.easeOut);

  Offset? _origin;

  @override
  double get initialValue => 1;

  void _down(PointerDownEvent event) {
    if (!widget.enabled || ConversationMotion.reduced(context)) return;
    _origin = event.position;
    final controller = this.controller();
    controller.animateTo(
      widget.scale,
      duration: kLongPressTimeout,
      curve: _sink,
    );
  }

  void _move(PointerMoveEvent event) {
    final origin = _origin;
    if (origin != null && (event.position - origin).distance > kTouchSlop) {
      _up();
    }
  }

  void _up([PointerEvent? _]) {
    if (_origin == null) return;
    _origin = null;
    final controller = _controller;
    if (controller == null || !mounted) return;
    if (controller.value == 1) {
      controller.stop();
      return;
    }
    controller.animateWith(
      NotionMotion.springTo(
        NotionMotion.snappy,
        controller.value,
        1,
        velocity: controller.velocity,
      ),
    );
  }

  @override
  void didUpdateWidget(ConversationPressScale oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _controller != null && value.value != 1) {
      _origin = null;
      _controller!.value = 1;
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: _down,
    onPointerMove: _move,
    onPointerUp: _up,
    onPointerCancel: _up,
    child: ValueListenableBuilder<double>(
      valueListenable: value,
      child: widget.child,
      builder: (context, scale, child) => Transform.scale(
        scale: scale,
        alignment: widget.alignment,
        child: child,
      ),
    ),
  );
}

/// Pops a slot's new content in when its child is replaced by one with a
/// different key or type (avatar → selection circle, circle → check). The
/// first build and ordinary rebuilds do nothing, so rows built while
/// scrolling never animate; no controller exists until the first swap.
class ConversationSlotMorph extends StatefulWidget {
  const ConversationSlotMorph({
    super.key,
    required this.child,
    this.bounce = false,
  });

  final Widget child;

  /// Overshoot ([NotionMotion.bouncy]); reward elements only.
  final bool bounce;

  @override
  State<ConversationSlotMorph> createState() => _ConversationSlotMorphState();
}

class _ConversationSlotMorphState extends State<ConversationSlotMorph>
    with SingleTickerProviderStateMixin, _LazyMotion {
  @override
  double get initialValue => 1;

  @override
  void didUpdateWidget(ConversationSlotMorph oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (Widget.canUpdate(oldWidget.child, widget.child) ||
        ConversationMotion.reduced(context)) {
      return;
    }
    final controller = this.controller()..value = 0;
    controller.animateWith(
      NotionMotion.springTo(
        widget.bounce ? NotionMotion.bouncy : NotionMotion.snappy,
        0,
        1,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
    valueListenable: value,
    child: widget.child,
    builder: (context, t, child) {
      final scale = NotionMotion.popFrom + (1 - NotionMotion.popFrom) * t;
      return Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.scale(scale: scale, child: child),
      );
    },
  );
}

/// Tweens a 0…1 value (selection, highlight) when [value] changes, without a
/// controller per row until the first change. [builder] receives the
/// current value; at rest it is exactly [value].
class ConversationLazyTween extends StatefulWidget {
  const ConversationLazyTween({
    super.key,
    required this.value,
    required this.builder,
    this.child,
    this.duration = NotionMotion.quick,
  });

  final double value;
  final Duration duration;
  final ValueWidgetBuilder<double> builder;
  final Widget? child;

  @override
  State<ConversationLazyTween> createState() => _ConversationLazyTweenState();
}

class _ConversationLazyTweenState extends State<ConversationLazyTween>
    with SingleTickerProviderStateMixin, _LazyMotion {
  @override
  double get initialValue => widget.value;

  @override
  void didUpdateWidget(ConversationLazyTween oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value == widget.value) return;
    if (ConversationMotion.reduced(context)) {
      _controller?.stop();
      value.value = widget.value;
      return;
    }
    controller().animateTo(
      widget.value,
      duration: widget.duration,
      curve: NotionMotion.standard,
    );
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
    valueListenable: value,
    builder: widget.builder,
    child: widget.child,
  );
}

/// Shows [child] with a size reveal and keeps the last non-null child while
/// it collapses (reply bars, mini players, banners whose data disappears
/// together with them). Pointer input is ignored while hiding.
class ConversationReveal extends StatefulWidget {
  const ConversationReveal({
    super.key,
    required this.child,
    this.alignment = AlignmentDirectional.bottomStart,
    this.duration = NotionMotion.medium,
  });

  /// Null hides.
  final Widget? child;
  final AlignmentGeometry alignment;
  final Duration duration;

  @override
  State<ConversationReveal> createState() => _ConversationRevealState();
}

class _ConversationRevealState extends State<ConversationReveal> {
  Widget? _last;

  @override
  Widget build(BuildContext context) {
    final child = widget.child;
    if (child != null) _last = child;
    return IgnorePointer(
      ignoring: child == null,
      child: NotionSizeReveal(
        visible: child != null,
        alignment: widget.alignment,
        duration: widget.duration,
        child: _last ?? const SizedBox.shrink(),
      ),
    );
  }
}

/// A bubble whose content changes in place (an edit, a deletion that leaves
/// "Message deleted" behind): when [revision] changes after the first
/// build, the box glides from its old size to the new one
/// ([ConversationMotion.contentMorph], clipped while it moves) and the new
/// content fades up, instead of the bubble snapping. The first build,
/// rebuilds with the same [revision] and rows built while scrolling never
/// animate; no controller exists until the first change. Instant under
/// reduced motion.
class ConversationContentMorph extends StatefulWidget {
  const ConversationContentMorph({
    super.key,
    required this.revision,
    required this.child,
  });

  /// What the content shows (deleted, edited text); a change morphs.
  final Object? revision;
  final Widget child;

  @override
  State<ConversationContentMorph> createState() =>
      _ConversationContentMorphState();
}

class _ConversationContentMorphState extends State<ConversationContentMorph>
    with SingleTickerProviderStateMixin {
  static final _fadeIn = Tween<double>(begin: .25, end: 1).chain(
    CurveTween(curve: const Interval(0, .6, curve: NotionMotion.standard)),
  );

  AnimationController? _controller;
  Animation<double>? _fade;
  Size? _from;

  @override
  void didUpdateWidget(ConversationContentMorph oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision == widget.revision) return;
    final box = context.findRenderObject();
    if (ConversationMotion.reduced(context) ||
        box is! RenderBox ||
        !box.hasSize) {
      _controller?.value = 1;
      _from = null;
      return;
    }
    _from = box.size;
    final controller = _controller ??= AnimationController(
      vsync: this,
      duration: ConversationMotion.contentMorph,
    );
    _fade ??= controller.drive(_fadeIn);
    controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ContentMorphBox(
    from: _from,
    animation: _controller ?? kAlwaysCompleteAnimation,
    child: FadeTransition(
      opacity: _fade ?? kAlwaysCompleteAnimation,
      child: widget.child,
    ),
  );
}

class _ContentMorphBox extends SingleChildRenderObjectWidget {
  const _ContentMorphBox({
    required this.from,
    required this.animation,
    super.child,
  });

  final Size? from;
  final Animation<double> animation;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderContentMorph(from: from, animation: animation);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderContentMorph renderObject,
  ) => renderObject
    ..from = from
    ..animation = animation;
}

/// Lays its child out at its own size but reports a size between [from] and
/// that while [animation] runs, clipping the child to it. At rest (or
/// without [from]) a plain proxy.
class _RenderContentMorph extends RenderProxyBox {
  _RenderContentMorph({
    required Size? from,
    required Animation<double> animation,
  }) : _from = from,
       _animation = animation;

  Size? _from;
  set from(Size? value) {
    if (value == _from) return;
    _from = value;
    markNeedsLayout();
  }

  Animation<double> _animation;
  set animation(Animation<double> value) {
    if (identical(value, _animation)) return;
    if (attached) _animation.removeListener(markNeedsLayout);
    _animation = value;
    if (attached) _animation.addListener(markNeedsLayout);
    markNeedsLayout();
  }

  final LayerHandle<ClipRectLayer> _clip = LayerHandle<ClipRectLayer>();

  bool get _morphing => _from != null && _animation.value < 1;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _animation.addListener(markNeedsLayout);
  }

  @override
  void detach() {
    _animation.removeListener(markNeedsLayout);
    super.detach();
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    if (!_morphing) {
      size = child.size;
      return;
    }
    final t = NotionMotion.emphasized.transform(
      _animation.value.clamp(0.0, 1.0),
    );
    size = constraints.constrain(Size.lerp(_from, child.size, t)!);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    if (!_morphing || size == child.size) {
      _clip.layer = null;
      context.paintChild(child, offset);
      return;
    }
    _clip.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      (context, offset) => context.paintChild(child, offset),
      oldLayer: _clip.layer,
    );
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }
}

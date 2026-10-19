import 'package:fluffychat/ui/notion/notion.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout, kTouchSlop;
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

  /// Duration for an `AnimatedSize`: [duration], or a single microsecond
  /// under reduced motion. A zero-length `AnimatedSize` completes inside its
  /// own layout and throws ("mutated in its own performLayout"); one
  /// microsecond lands on the next frame, so nothing visibly animates.
  static Duration sizeDuration(BuildContext context, Duration duration) =>
      reduced(context) ? const Duration(microseconds: 1) : duration;
}

enum _EntranceMode { rest, arrive, stagger }

/// Entrance of one timeline row.
///
/// * [animate] (only the genuinely new message, decided by the timeline):
///   the row's slot grows from zero height, so older messages glide up
///   instead of jumping, while the bubble rises out of the composer, fades in
///   and scales up from its tail corner ([outgoing] decides the side).
/// * Otherwise, inside a [ConversationEntranceScope] that is still open (the
///   first frame of a freshly opened chat), the row fades in with a short
///   rise, staggered bottom-up.
/// * History, paging, decryption, edits, reactions and rows built by
///   scrolling never animate; a rebuild never replays the entrance.
///
/// Transform/opacity plus one size factor; settles to identity (no layers at
/// rest), instant under reduced motion. The widget tree never changes shape,
/// so the row's state (media, gestures) survives the animation.
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

  @override
  State<ConversationMessageEntrance> createState() =>
      _ConversationMessageEntranceState();
}

class _ConversationMessageEntranceState
    extends State<ConversationMessageEntrance>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _arriveFade = Interval(0, .45, curve: NotionMotion.standard);
  static const _staggerFade = Interval(0, .6, curve: NotionMotion.standard);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: ConversationMotion.arrival,
    value: 1,
  );
  _EntranceMode _mode = _EntranceMode.rest;
  double _delay = 0;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      _start(mount: true);
    } else if (ConversationMotion.reduced(context)) {
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(ConversationMessageEntrance oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity) _start(mount: false);
  }

  void _start({required bool mount}) {
    if (ConversationMotion.reduced(context)) {
      _controller.value = 1;
      return;
    }
    if (widget.animate) {
      _mode = _EntranceMode.arrive;
      _controller.duration = ConversationMotion.arrival;
      _controller.forward(from: 0);
      return;
    }
    final index = mount ? ConversationEntranceScope._claim(context) : null;
    if (index != null) {
      final delay = NotionMotion.staggerFor(index);
      final total = delay + NotionMotion.medium;
      _mode = _EntranceMode.stagger;
      _delay = delay.inMicroseconds / total.inMicroseconds;
      _controller.duration = total;
      _controller.forward(from: 0);
      return;
    }
    _controller.value = 1;
  }

  @override
  void didChangeAccessibilityFeatures() {
    if (mounted && ConversationMotion.reduced(context)) _controller.value = 1;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
        var rise = 0.0;
        var scale = 1.0;
        if (t < 1) {
          switch (_mode) {
            case _EntranceMode.arrive:
              height = NotionMotion.emphasized.transform(t);
              opacity = _arriveFade.transform(t);
              final spring = NotionMotion.snappyCurve.transform(t);
              scale =
                  ConversationMotion.arrivalFrom +
                  (1 - ConversationMotion.arrivalFrom) * spring;
            case _EntranceMode.stagger:
              final local = _delay >= 1
                  ? 1.0
                  : ((t - _delay) / (1 - _delay)).clamp(0.0, 1.0);
              opacity = _staggerFade.transform(local);
              rise =
                  NotionMotion.riseList *
                  (1 - NotionMotion.emphasized.transform(local));
            case _EntranceMode.rest:
              break;
          }
        }
        // The slot grows from its bottom edge (the list is reversed), and
        // the bubble sits at the slot's top, so it rises with the slot.
        return Align(
          alignment: Alignment.topCenter,
          heightFactor: height.clamp(0.0, 1.0),
          widthFactor: 1,
          child: Opacity(
            opacity: opacity.clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, rise),
              child: Transform.scale(
                scale: scale,
                alignment: tail,
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Around a conversation list: the rows built in the first frame after the
/// list appears (the first screenful of a freshly opened chat) stagger in
/// bottom-up, once. Rows built later (scrolling, history pages, the
/// wider cache after the route settled) appear without animation.
class ConversationEntranceScope extends StatefulWidget {
  const ConversationEntranceScope({super.key, required this.child});

  final Widget child;

  /// Next stagger index, or null when the scope is closed or absent.
  static int? _claim(BuildContext context) => context
      .getInheritedWidgetOfExactType<_EntranceScopeMarker>()
      ?.state
      ._claim();

  @override
  State<ConversationEntranceScope> createState() =>
      _ConversationEntranceScopeState();
}

class _ConversationEntranceScopeState extends State<ConversationEntranceScope> {
  int _next = 0;
  bool _closed = false;
  bool _closing = false;

  int? _claim() {
    if (_closed) return null;
    if (!_closing) {
      _closing = true;
      // Everything the first layout builds belongs to the first screenful.
      WidgetsBinding.instance.addPostFrameCallback((_) => _closed = true);
    }
    return _next++;
  }

  @override
  Widget build(BuildContext context) =>
      _EntranceScopeMarker(state: this, child: widget.child);
}

class _EntranceScopeMarker extends InheritedWidget {
  const _EntranceScopeMarker({required this.state, required super.child});

  final _ConversationEntranceScopeState state;

  @override
  bool updateShouldNotify(_EntranceScopeMarker oldWidget) => false;
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

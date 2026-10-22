import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'conversation_motion.dart';

/// What a double tap would do right now: react with [emoji]; [adds] is true
/// when that adds a reaction (not removes one), so the burst plays at once.
typedef ConversationQuickLike = ({String emoji, bool adds});

/// The finger that opened a message menu, while it stays down: the menu
/// follows it to choose an emoji (Messenger's slide to react).
class ConversationMenuPointer extends ChangeNotifier {
  Offset? _position;
  bool _released = false;

  /// Global position, or null once the pointer was cancelled.
  Offset? get position => _position;

  /// The finger lifted (or was cancelled; then [position] is null).
  bool get released => _released;

  void move(Offset position) {
    if (_released) return;
    _position = position;
    notifyListeners();
  }

  void release(Offset position) {
    if (_released) return;
    _position = position;
    _released = true;
    notifyListeners();
  }

  void cancel() {
    if (_released) return;
    _position = null;
    _released = true;
    notifyListeners();
  }
}

/// A recognised long-press (or secondary click, or the accessibility action)
/// on a message surface: everything the message menu needs to lift a copy of
/// the bubble from where it is drawn.
@immutable
class ConversationMessagePress {
  const ConversationMessagePress({
    required this.position,
    required this.rect,
    required this.visualRect,
    this.snapshot,
    this.pointer,
    this.reactionsOnly = false,
  });

  /// Global touch point.
  final Offset position;

  /// Global rect of the surface at its natural size.
  final Rect rect;

  /// Global rect as drawn at the press (sunk by the press feedback).
  final Rect visualRect;

  /// The surface rendered at natural size, owned by whoever shows the menu.
  final ui.Image? snapshot;

  /// The finger, while it is still down.
  final ConversationMenuPointer? pointer;

  /// Opened from the hover toolbar's react button: the menu shows only the
  /// reaction bar (Messenger desktop's reaction popover), no action card.
  final bool reactionsOnly;
}

/// Chrome that opens on a single tap while leaving double taps to the message.
/// Unlike playback buttons, its tap may wait for the reaction gesture to fail.
class ConversationMessageChromeTap extends SingleChildRenderObjectWidget {
  const ConversationMessageChromeTap({super.key, required super.child});

  @override
  RenderProxyBox createRenderObject(BuildContext context) =>
      _MessageChromeTapRegion();
}

class _MessageChromeTapRegion extends RenderProxyBox {}

/// Touch gestures of one message surface, the single owner of how a bubble
/// reacts to a finger (Telegram/Messenger):
///
/// * horizontal swipe → [onReply] on every message kind. Controls inside
///   the bubble that drag horizontally themselves (an active voice note's
///   waveform, a code block) win the gesture arena where they are touched;
/// * double tap → [onLike] (the network's first quick reaction). Only on the
///   bubble's chrome and plain text: a double tap that lands on a button,
///   link, slider or media tap target is left to it, so single taps there
///   are never delayed;
/// * long-press (also a secondary click and the "Message actions"
///   accessibility action) → [onLongPress] with a [ConversationMessagePress];
///   while held, the bubble sinks slightly.
///
/// The controller owns authorization and reaction deduplication. A true result
/// from [onLike] means a new intention was accepted, not delivery confirmation.
/// Set [enabled] false during text selection: swipe and double tap pause, the
/// long-press stays.
class ConversationMessageGestures extends StatefulWidget {
  const ConversationMessageGestures({
    super.key,
    required this.child,
    required this.identity,
    this.onReply,
    this.onLike,
    this.likePreview,
    this.onLongPress,
    this.enabled = true,
    this.swipeRightToLeft = false,
    this.quickLikeEnabled = true,
    this.pressAlignment = Alignment.center,
    this.likeLabel = 'Like message',
    this.likeEmoji = '👍',
    this.replyLabel = 'Reply',
    this.menuLabel = 'Message actions',
    this.hoverActions = false,
    this.hoverReact,
    this.outgoing = false,
  });

  final Widget child;
  final Object identity;
  final VoidCallback? onReply;
  final Future<bool> Function()? onLike;

  /// Resolves the double tap before [onLike] runs; when it [adds], the burst
  /// and haptic play immediately instead of after the network accepted.
  final ConversationQuickLike Function()? likePreview;
  final void Function(ConversationMessagePress press)? onLongPress;
  final bool enabled;
  final bool swipeRightToLeft;
  final bool quickLikeEnabled;

  /// Fixed point of the press sink (the bubble's sender-side edge).
  final Alignment pressAlignment;
  final String likeLabel;

  /// Burst glyph when no [likePreview] names one.
  final String likeEmoji;
  final String replyLabel;
  final String menuLabel;

  /// A mouse or trackpad hovering the surface shows a small toolbar beside
  /// it (Messenger desktop): react (when [hoverReact]), reply (when
  /// [onReply]) and more (the menu, when [onLongPress]). Pass true only on
  /// pointer platforms; touches never show it.
  final bool hoverActions;

  /// Whether the hover toolbar offers react (the menu with only the bar).
  /// Asked only when the toolbar shows, never per build.
  final bool Function()? hoverReact;

  /// Own message (drawn on the trailing side): the toolbar sits on the
  /// bubble's leading side, otherwise on its trailing side.
  final bool outgoing;

  /// Scale a held bubble sinks to before the menu opens.
  static const double pressScale = NotionMotion.pressButton;

  @override
  State<ConversationMessageGestures> createState() =>
      _ConversationMessageGesturesState();
}

class _ConversationMessageGesturesState
    extends State<ConversationMessageGestures>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const _armDistance = 64.0;
  static const _disarmDistance = 48.0;
  static const _spring = SpringDescription(
    mass: 1,
    stiffness: 420,
    damping: 34,
  );

  // A quick tap (or the start of a scroll) shows nothing; the bubble starts
  // sinking once the touch is clearly a hold.
  static const _sinkCurve = Interval(.2, 1, curve: Curves.easeOut);

  // Controllers exist only once a row is touched, never per built row.
  AnimationController? _return;
  AnimationController? _sinkController;
  AnimationController? _burst;
  final ValueNotifier<double> _sink = ValueNotifier(1);
  final _boundary = _BoundaryHandle();
  final Set<int> _pointers = {};
  Offset? _downPosition;
  Offset? _sinkOrigin;
  Offset? _tapPosition;
  double _offset = 0;
  double _rawDistance = 0;
  double _dragBase = 0;
  bool _blocked = false;
  bool _armed = false;
  bool _hapticSent = false;
  bool _likePending = false;
  int _identityGeneration = 0;
  String? _burstEmoji;
  Offset _burstAt = Offset.zero;
  ConversationMenuPointer? _menuPointer;

  // Hover toolbar (pointer platforms only), created on the first hover.
  _HoverToolbarState? _hover;

  bool get _touchEnabled => widget.enabled;
  double get _direction {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return widget.swipeRightToLeft != rtl ? -1 : 1;
  }

  AnimationController get _returnController =>
      _return ??= AnimationController.unbounded(vsync: this)
        ..addListener(_springTick)
        ..addStatusListener(_springStatus);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (ConversationMotion.reduced(context)) _stopMotion();
  }

  @override
  void didUpdateWidget(ConversationMessageGestures oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity) {
      _identityGeneration++;
      _likePending = false;
      _blocked = true;
      _downPosition = null;
      _return?.stop();
      _offset = 0;
      _armed = false;
      _releaseSink(immediate: true);
      _endBurst();
      _menuPointer?.cancel();
      _menuPointer = null;
      _hover?.clear();
    } else if (!_touchEnabled ||
        (oldWidget.onReply != widget.onReply && widget.onReply == null) ||
        oldWidget.swipeRightToLeft != widget.swipeRightToLeft) {
      _cancel();
    }
    if (widget.onLongPress == null) _releaseSink(immediate: true);
  }

  @override
  void didChangeAccessibilityFeatures() {
    if (ConversationMotion.reduced(context)) {
      setState(_stopMotion);
    }
  }

  void _stopMotion() {
    final spring = _return;
    if (spring != null && spring.isAnimating) {
      spring.stop();
      _offset = 0;
    }
    _releaseSink(immediate: true);
    _endBurst();
  }

  bool _pointerAllowed(PointerDownEvent event) {
    if (!_touchEnabled || _pointers.isNotEmpty) return false;
    // Read without a dependency: a touched row must not rebuild on every
    // keyboard-inset frame (or any other MediaQuery change).
    final media = context.getInheritedWidgetOfExactType<MediaQuery>()?.data;
    if (media == null) return true;
    // Leave both platform back edges to the system, even when a test/embedder
    // does not report its gesture inset.
    final left = math.max(16.0, media.systemGestureInsets.left);
    final right = math.max(16.0, media.systemGestureInsets.right);
    return event.position.dx > left &&
        event.position.dx < media.size.width - right;
  }

  bool _doubleTapAllowed(PointerDownEvent event) =>
      _pointerAllowed(event) && !_onInteractiveChild(event.position);

  /// Whether [position] lands on something inside the surface that handles
  /// pointers itself: a gesture detector or button, a link span, a control
  /// with a click cursor (sliders, ink). Plain text, captions and the
  /// bubble's padding are chrome.
  bool _onInteractiveChild(Offset position) {
    final root = _boundary.box;
    if (root == null || !root.attached || !root.hasSize) return false;
    final result = BoxHitTestResult();
    root.hitTest(result, position: root.globalToLocal(position));
    // These regions deliberately share their tap surface with quick reactions.
    if (result.path.any((entry) => entry.target is _MessageChromeTapRegion)) {
      return false;
    }
    for (final entry in result.path) {
      final target = entry.target;
      if (identical(target, root)) break;
      if (target is RenderPointerListener && target.onPointerDown != null) {
        return true;
      }
      if (target is RenderMouseRegion &&
          target.cursor == SystemMouseCursors.click) {
        return true;
      }
      if (target is TextSpan && target.recognizer != null) return true;
    }
    return false;
  }

  void _pointerDown(PointerDownEvent event) {
    if (_pointers.isEmpty) {
      _startSink(event);
      if (event.kind == PointerDeviceKind.touch) {
        _blocked = !_touchEnabled;
        _downPosition = event.position;
        _dragBase = _unresisted(_offset.abs());
        _hapticSent = false;
        _armed = false;
      }
    }
    if (event.kind != PointerDeviceKind.touch) return;
    _pointers.add(event.pointer);
    if (_pointers.length > 1) {
      _cancel();
      _releaseSink();
    }
  }

  void _pointerMove(PointerMoveEvent event) {
    final origin = _sinkOrigin;
    if (origin != null && (event.position - origin).distance > kTouchSlop) {
      _releaseSink();
    }
    final start = _downPosition;
    if (_blocked || start == null) return;
    final delta = event.position - start;
    // A diagonal/vertical scroll must not become a reply after the horizontal
    // recognizer has happened to win the first few pixels of the arena.
    if (delta.dy.abs() > kTouchSlop && delta.dy.abs() >= delta.dx.abs() * .7) {
      _cancel();
    }
  }

  void _pointerUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    _releaseSink();
  }

  void _pointerCancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    _cancel();
    _releaseSink();
    _menuPointer?.cancel();
    _menuPointer = null;
  }

  // ------------------------------------------------------------ press sink

  void _startSink(PointerDownEvent event) {
    if (widget.onLongPress == null || ConversationMotion.reduced(context)) {
      return;
    }
    _sinkOrigin = event.position;
    final controller = _sinkController ??= AnimationController.unbounded(
      vsync: this,
      value: _sink.value,
    )..addListener(() => _sink.value = _sinkController!.value);
    controller.animateTo(
      ConversationMessageGestures.pressScale,
      duration: kLongPressTimeout,
      curve: _sinkCurve,
    );
  }

  void _releaseSink({bool immediate = false}) {
    _sinkOrigin = null;
    final controller = _sinkController;
    if (controller == null) return;
    if (immediate || controller.value == 1 || !mounted) {
      controller.stop();
      controller.value = 1;
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

  // ------------------------------------------------------------ long-press

  void _longPressStart(LongPressStartDetails details) {
    if (widget.onLongPress == null) return;
    _cancel();
    NotionHaptics.longPress();
    final pointer = _menuPointer = ConversationMenuPointer();
    _openMenu(details.globalPosition, pointer);
  }

  void _longPressMove(LongPressMoveUpdateDetails details) =>
      _menuPointer?.move(details.globalPosition);

  void _longPressEnd(LongPressEndDetails details) {
    _menuPointer?.release(details.globalPosition);
    _menuPointer = null;
  }

  void _secondaryTap(TapUpDetails details) =>
      _openMenu(details.globalPosition, null);

  void _semanticsMenu() => _openMenu(null, null);

  void _openMenu(
    Offset? position,
    ConversationMenuPointer? pointer, {
    bool reactionsOnly = false,
  }) {
    final onLongPress = widget.onLongPress;
    final own = context.findRenderObject();
    if (onLongPress == null || own is! RenderBox || !own.hasSize) return;
    final rect = MatrixUtils.transformRect(
      own.getTransformTo(null),
      Offset.zero & own.size,
    );
    final boundary = _boundary.box;
    var visual = rect;
    ui.Image? snapshot;
    if (boundary != null && boundary.attached && boundary.hasSize) {
      visual = MatrixUtils.transformRect(
        boundary.getTransformTo(null),
        Offset.zero & boundary.size,
      );
      try {
        snapshot = boundary.toImageSync(
          pixelRatio: MediaQuery.devicePixelRatioOf(context),
        );
      } catch (_) {
        // Not painted yet: the menu opens without the lifted copy.
        snapshot = null;
      }
    }
    // The lifted copy takes over the press feedback.
    _releaseSink(immediate: true);
    onLongPress(
      ConversationMessagePress(
        position: position ?? rect.center,
        rect: rect,
        visualRect: visual,
        snapshot: snapshot,
        pointer: pointer,
        reactionsOnly: reactionsOnly,
      ),
    );
  }

  // ------------------------------------------------------------ hover

  bool get _hoverEnabled =>
      widget.hoverActions &&
      widget.enabled &&
      (widget.onLongPress != null || widget.onReply != null);

  void _hoverChanged(bool surface, PointerEvent event) {
    if (event.kind == PointerDeviceKind.touch) return;
    if (!_hoverEnabled && surface) return;
    final hover = _hover ??= _HoverToolbarState();
    hover.set(surface: surface);
  }

  List<NotionHoverAction> _hoverItems() {
    void run(VoidCallback action) {
      _hover?.clear();
      action();
    }

    return [
      if (widget.onLongPress != null && (widget.hoverReact?.call() ?? false))
        NotionHoverAction(
          icon: Icons.add_reaction_outlined,
          label: 'React',
          onPressed: () =>
              run(() => _openMenu(null, null, reactionsOnly: true)),
        ),
      if (widget.onReply != null)
        NotionHoverAction(
          icon: Icons.reply_rounded,
          label: widget.replyLabel,
          onPressed: () => run(widget.onReply!),
        ),
      if (widget.onLongPress != null)
        NotionHoverAction(
          icon: Icons.more_horiz_rounded,
          label: widget.menuLabel,
          onPressed: () => run(() => _openMenu(null, null)),
        ),
    ];
  }

  Widget _withHover(Widget surface) {
    if (!widget.hoverActions) return surface;
    final hover = _hover ??= _HoverToolbarState();
    final rtl = Directionality.of(context) == TextDirection.rtl;
    // Own bubbles sit at the trailing edge: the toolbar goes inside the row
    // (their leading side), and vice versa.
    final toolbarOnLeft = widget.outgoing != rtl;
    return OverlayPortal(
      controller: hover.portal,
      overlayChildBuilder: (context) => Align(
        alignment: AlignmentDirectional.topStart,
        child: CompositedTransformFollower(
          link: hover.link,
          showWhenUnlinked: false,
          targetAnchor: toolbarOnLeft
              ? Alignment.centerLeft
              : Alignment.centerRight,
          followerAnchor: toolbarOnLeft
              ? Alignment.centerRight
              : Alignment.centerLeft,
          child: MouseRegion(
            onEnter: (_) => hover.set(bar: true),
            onExit: (_) => hover.set(bar: false),
            // The padding touches the bubble, so the pointer moves from
            // the bubble onto the toolbar without leaving both.
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: NotionSpace.xs),
              child: NotionHoverToolbar(actions: _hoverItems()),
            ),
          ),
        ),
      ),
      child: CompositedTransformTarget(
        link: hover.link,
        child: MouseRegion(
          onEnter: (event) => _hoverChanged(true, event),
          onExit: (event) => _hover?.set(surface: false),
          child: surface,
        ),
      ),
    );
  }

  // ----------------------------------------------------------------- swipe

  static double _resisted(double distance) => distance <= _armDistance
      ? distance
      : _armDistance + 20 * (1 - math.exp(-(distance - _armDistance) / 60));

  static double _unresisted(double distance) => distance <= _armDistance
      ? distance
      : _armDistance -
            60 * math.log(1 - (math.min(distance, 83.99) - _armDistance) / 20);

  void _dragStart(DragStartDetails details) {
    if (_blocked) return;
    _return?.stop();
    _releaseSink();
  }

  void _dragUpdate(DragUpdateDetails details) {
    final start = _downPosition;
    if (_blocked || start == null || widget.onReply == null) return;
    final delta = details.globalPosition - start;
    if (delta.dy.abs() > kTouchSlop && delta.dy.abs() >= delta.dx.abs() * .7) {
      _cancel();
      return;
    }
    _rawDistance = math.max(0, _dragBase + delta.dx * _direction);
    final wasArmed = _armed;
    if (_rawDistance >= _armDistance) {
      _armed = true;
    } else if (_rawDistance < _disarmDistance) {
      _armed = false;
    }
    if (_armed && !wasArmed && !_hapticSent) {
      _hapticSent = true;
      NotionHaptics.selection();
    }
    setState(() => _offset = _resisted(_rawDistance) * _direction);
  }

  void _dragEnd(DragEndDetails details) {
    final commit = !_blocked && _touchEnabled && _armed;
    _armed = false;
    _blocked = true;
    final derivative = _rawDistance <= _armDistance
        ? 1.0
        : math.exp(-(_rawDistance - _armDistance) / 60) / 3;
    _settle((details.primaryVelocity ?? 0) * derivative);
    if (commit) widget.onReply?.call();
  }

  void _cancel() {
    _blocked = true;
    _armed = false;
    _settle(0);
  }

  void _dragCancel() {
    // Losing the drag arena on a stationary tap is normal. In particular, it
    // must not cancel the double-tap recognizer competing for that same tap.
    if (_offset != 0 || _armed) _cancel();
  }

  void _settle(double velocity) {
    _return?.stop();
    if (_offset == 0) return;
    if (ConversationMotion.reduced(context)) {
      setState(() => _offset = 0);
      return;
    }
    final spring = _returnController..value = _offset;
    spring.animateWith(
      SpringSimulation(_spring, _offset, 0, velocity.clamp(-1200.0, 1200.0)),
    );
  }

  void _springTick() {
    if (mounted) setState(() => _offset = _return!.value);
  }

  void _springStatus(AnimationStatus status) {
    // Simulation completion uses a tolerance. Remove its subpixel residual so
    // hit testing and layout inspection return to the exact resting surface.
    if (status == AnimationStatus.completed && mounted && _offset != 0) {
      setState(() => _offset = 0);
    }
  }

  // ------------------------------------------------------------ quick like

  Future<void> _like() async {
    final onLike = widget.onLike;
    if (!widget.enabled ||
        !widget.quickLikeEnabled ||
        _likePending ||
        onLike == null) {
      return;
    }
    _likePending = true;
    final generation = _identityGeneration;
    final at = _tapPosition;
    final preview = widget.likePreview?.call();
    final emoji = preview?.emoji ?? widget.likeEmoji;
    // An add the controller already allows celebrates at once (Instagram);
    // anything else waits for the result.
    final optimistic = preview?.adds ?? false;
    if (optimistic) _celebrate(emoji, at);
    try {
      final accepted = await onLike();
      if (!mounted ||
          generation != _identityGeneration ||
          !accepted ||
          !widget.enabled) {
        return;
      }
      if (!optimistic && preview == null) _celebrate(emoji, at);
    } catch (_) {
      // The shared action handler owns safe error/pending presentation. A
      // failed action must not produce a success badge or an unhandled Future.
    } finally {
      if (mounted && generation == _identityGeneration) _likePending = false;
    }
  }

  void _celebrate(String emoji, Offset? at) {
    NotionHaptics.light();
    if (!mounted || ConversationMotion.reduced(context)) return;
    final box = context.findRenderObject();
    final size = box is RenderBox && box.hasSize ? box.size : Size.zero;
    final burst = _burst ??= AnimationController(
      vsync: this,
      duration: NotionReactions.burst,
    )..addStatusListener(_burstStatus);
    setState(() {
      _burstEmoji = emoji;
      _burstAt = at ?? size.center(Offset.zero);
    });
    burst.forward(from: 0);
  }

  void _burstStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) {
      setState(() => _burstEmoji = null);
    }
  }

  void _endBurst() {
    _burst?.stop();
    _burstEmoji = null;
  }

  void _doubleTapDown(TapDownDetails details) =>
      _tapPosition = details.localPosition;

  void _doubleTap() {
    if (_touchEnabled && !_blocked) _like();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _identityGeneration++;
    _menuPointer?.cancel();
    _return?.dispose();
    _sinkController?.dispose();
    _burst?.dispose();
    _sink.dispose();
    _hover?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reply = widget.enabled ? widget.onReply : null;
    final like =
        widget.enabled && widget.quickLikeEnabled && widget.onLike != null;
    final menu = widget.onLongPress != null;
    final burstEmoji = _burstEmoji;
    final burst = _burst;
    if (!_hoverEnabled) _hover?.clear();
    return _withHover(
      Semantics(
        customSemanticsActions: {
          CustomSemanticsAction(label: widget.replyLabel): ?reply,
          if (like) CustomSemanticsAction(label: widget.likeLabel): _like,
          if (menu)
            CustomSemanticsAction(label: widget.menuLabel): _semanticsMenu,
        },
        child: Listener(
          onPointerDown: _pointerDown,
          onPointerMove: _pointerMove,
          onPointerUp: _pointerUp,
          onPointerCancel: _pointerCancel,
          child: RawGestureDetector(
            key: ValueKey(widget.identity),
            behavior: HitTestBehavior.deferToChild,
            excludeFromSemantics: true,
            gestures: {
              if (_touchEnabled && reply != null)
                _MessageHorizontalDragRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      _MessageHorizontalDragRecognizer
                    >(
                      () => _MessageHorizontalDragRecognizer(_pointerAllowed),
                      (recognizer) => recognizer
                        ..dragStartBehavior = DragStartBehavior.down
                        ..onStart = _dragStart
                        ..onUpdate = _dragUpdate
                        ..onEnd = _dragEnd
                        ..onCancel = _dragCancel,
                    ),
              if (_touchEnabled && like)
                _MessageDoubleTapRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      _MessageDoubleTapRecognizer
                    >(
                      () => _MessageDoubleTapRecognizer(_doubleTapAllowed),
                      (recognizer) => recognizer
                        ..onDoubleTapDown = _doubleTapDown
                        ..onDoubleTap = _doubleTap,
                    ),
              if (menu) ...{
                LongPressGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      LongPressGestureRecognizer
                    >(
                      () => LongPressGestureRecognizer(debugOwner: this),
                      (recognizer) => recognizer
                        ..onLongPressStart = _longPressStart
                        ..onLongPressMoveUpdate = _longPressMove
                        ..onLongPressEnd = _longPressEnd,
                    ),
                TapGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                      () => TapGestureRecognizer(debugOwner: this),
                      (recognizer) =>
                          recognizer..onSecondaryTapUp = _secondaryTap,
                    ),
              },
            },
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                if (_offset.abs() > 16)
                  Positioned(
                    left: _direction > 0 ? 8 : null,
                    right: _direction < 0 ? 8 : null,
                    child: ExcludeSemantics(
                      child: Opacity(
                        opacity: ((_offset.abs() - 16) / 48).clamp(0.0, 1.0),
                        child: Icon(
                          Icons.reply_rounded,
                          size: 22,
                          color: _armed
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                Transform.translate(
                  key: const ValueKey('message-surface'),
                  offset: Offset(_offset, 0),
                  // A held bubble sinks a little until the long-press opens
                  // the menu (no rebuild per tick).
                  child: ValueListenableBuilder<double>(
                    valueListenable: _sink,
                    child: _SurfaceBoundary(
                      handle: _boundary,
                      child: widget.child,
                    ),
                    builder: (context, scale, child) => Transform.scale(
                      scale: scale,
                      alignment: widget.pressAlignment,
                      child: child,
                    ),
                  ),
                ),
                if (burstEmoji != null && burst != null)
                  Positioned(
                    left: _burstAt.dx - NotionReactions.burstEmoji,
                    top: _burstAt.dy - NotionReactions.burstEmoji,
                    width: NotionReactions.burstEmoji * 2,
                    height: NotionReactions.burstEmoji * 2,
                    child: NotionReactionBurst(
                      animation: burst,
                      child: Center(
                        child: burstEmoji.startsWith('mxc://')
                            ? const Icon(
                                Icons.add_reaction_outlined,
                                size: NotionReactions.burstEmoji,
                              )
                            : Text(
                                burstEmoji,
                                maxLines: 1,
                                style: const TextStyle(
                                  fontSize: NotionReactions.burstEmoji,
                                ),
                              ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Whether the pointer is over a message surface or its hover toolbar; the
/// toolbar shows while either holds. Exit and enter of one pointer move
/// land in the same frame, so crossing from the bubble onto the toolbar
/// never hides it.
class _HoverToolbarState {
  final portal = OverlayPortalController();
  final link = LayerLink();
  bool _surface = false;
  bool _bar = false;
  bool _disposed = false;

  void set({bool? surface, bool? bar}) {
    if (_disposed) return;
    _surface = surface ?? _surface;
    _bar = bar ?? _bar;
    _apply();
  }

  void clear() {
    _surface = false;
    _bar = false;
    _apply();
  }

  void _apply() {
    if (_disposed) return;
    final show = _surface || _bar;
    if (show == portal.isShowing) return;
    // Pointer events may arrive while the tree is locked (a layout-driven
    // hover update): toggle after this frame in that case.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _apply());
      return;
    }
    show ? portal.show() : portal.hide();
  }

  void dispose() => _disposed = true;
}

/// The render object the surface is drawn into: probed for interactive
/// children and snapshotted for the menu's lifted copy.
class _BoundaryHandle {
  RenderRepaintBoundary? box;
}

/// A repaint boundary around the surface. It also isolates the surface from
/// row repaints, so swipe and press transforms only recomposite.
class _SurfaceBoundary extends SingleChildRenderObjectWidget {
  const _SurfaceBoundary({required this.handle, super.child});

  final _BoundaryHandle handle;

  @override
  RenderRepaintBoundary createRenderObject(BuildContext context) =>
      handle.box = RenderRepaintBoundary();

  @override
  void updateRenderObject(
    BuildContext context,
    RenderRepaintBoundary renderObject,
  ) => handle.box = renderObject;
}

class _MessageHorizontalDragRecognizer extends HorizontalDragGestureRecognizer {
  _MessageHorizontalDragRecognizer(this.allowed)
    : super(supportedDevices: {PointerDeviceKind.touch});

  final bool Function(PointerDownEvent) allowed;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      event is PointerDownEvent &&
      allowed(event) &&
      super.isPointerAllowed(event);
}

class _MessageDoubleTapRecognizer extends DoubleTapGestureRecognizer {
  _MessageDoubleTapRecognizer(this.allowed)
    : super(supportedDevices: {PointerDeviceKind.touch});

  final bool Function(PointerDownEvent) allowed;

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      allowed(event) && super.isPointerAllowed(event);
}

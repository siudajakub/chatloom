import 'dart:math' as math;

import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'conversation_motion.dart';

/// Touch gestures for an otherwise non-interactive message surface.
///
/// The controller owns authorization and reaction deduplication. A true result
/// from [onLike] means a new intention was accepted, not delivery confirmation.
/// Set [interactiveContent] for links, play/seek, media and form controls, and
/// [enabled] false during text selection. Both retain their existing actions.
class ConversationMessageGestures extends StatefulWidget {
  const ConversationMessageGestures({
    super.key,
    required this.child,
    required this.identity,
    this.onReply,
    this.onLike,
    this.enabled = true,
    this.swipeRightToLeft = false,
    this.quickLikeEnabled = true,
    this.interactiveContent = false,
    this.likeLabel = 'Like message',
    this.likeEmoji = '👍',
    this.replyLabel = 'Reply',
  });

  final Widget child;
  final Object identity;
  final VoidCallback? onReply;
  final Future<bool> Function()? onLike;
  final bool enabled;
  final bool swipeRightToLeft;
  final bool quickLikeEnabled;
  final bool interactiveContent;
  final String likeLabel;
  final String likeEmoji;
  final String replyLabel;

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

  late final AnimationController _return =
      AnimationController.unbounded(vsync: this)
        ..addListener(_springTick)
        ..addStatusListener(_springStatus);
  late final AnimationController _badge = AnimationController(
    vsync: this,
    duration: NotionMotion.short,
    reverseDuration: NotionMotion.quick,
  );
  final Set<int> _pointers = {};
  Offset? _downPosition;
  double _offset = 0;
  double _rawDistance = 0;
  double _dragBase = 0;
  bool _blocked = false;
  bool _armed = false;
  bool _hapticSent = false;
  bool _likePending = false;
  int _identityGeneration = 0;

  bool get _touchEnabled => widget.enabled && !widget.interactiveContent;
  double get _direction {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return widget.swipeRightToLeft != rtl ? -1 : 1;
  }

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
      _return.stop();
      _badge.value = 0;
      _offset = 0;
      _armed = false;
    } else if (!_touchEnabled ||
        (oldWidget.onReply != widget.onReply && widget.onReply == null) ||
        oldWidget.swipeRightToLeft != widget.swipeRightToLeft) {
      _cancel();
    }
  }

  @override
  void didChangeAccessibilityFeatures() {
    if (ConversationMotion.reduced(context)) {
      setState(_stopMotion);
    }
  }

  void _stopMotion() {
    if (_return.isAnimating) {
      _return.stop();
      _offset = 0;
    }
    _badge.value = 0;
  }

  bool _pointerAllowed(PointerDownEvent event) {
    if (!_touchEnabled || _pointers.isNotEmpty) return false;
    final media = MediaQuery.maybeOf(context);
    if (media == null) return true;
    // Leave both platform back edges to the system, even when a test/embedder
    // does not report its gesture inset.
    final left = math.max(16.0, media.systemGestureInsets.left);
    final right = math.max(16.0, media.systemGestureInsets.right);
    return event.position.dx > left &&
        event.position.dx < media.size.width - right;
  }

  void _pointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    if (_pointers.isEmpty) {
      _blocked = !_touchEnabled;
      _downPosition = event.position;
      _dragBase = _unresisted(_offset.abs());
      _hapticSent = false;
      _armed = false;
    }
    _pointers.add(event.pointer);
    if (_pointers.length > 1) _cancel();
  }

  void _pointerMove(PointerMoveEvent event) {
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
  }

  void _pointerCancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    _cancel();
  }

  static double _resisted(double distance) => distance <= _armDistance
      ? distance
      : _armDistance + 20 * (1 - math.exp(-(distance - _armDistance) / 60));

  static double _unresisted(double distance) => distance <= _armDistance
      ? distance
      : _armDistance -
            60 * math.log(1 - (math.min(distance, 83.99) - _armDistance) / 20);

  void _dragStart(DragStartDetails details) {
    if (_blocked) return;
    _return.stop();
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
      HapticFeedback.selectionClick();
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
    _return.stop();
    if (_offset == 0) return;
    if (ConversationMotion.reduced(context)) {
      setState(() => _offset = 0);
      return;
    }
    _return.value = _offset;
    _return.animateWith(
      SpringSimulation(_spring, _offset, 0, velocity.clamp(-1200.0, 1200.0)),
    );
  }

  void _springTick() {
    if (mounted) setState(() => _offset = _return.value);
  }

  void _springStatus(AnimationStatus status) {
    // Simulation completion uses a tolerance. Remove its subpixel residual so
    // hit testing and layout inspection return to the exact resting surface.
    if (status == AnimationStatus.completed && mounted && _offset != 0) {
      setState(() => _offset = 0);
    }
  }

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
    try {
      final accepted = await onLike();
      if (!mounted ||
          generation != _identityGeneration ||
          !accepted ||
          !widget.enabled) {
        return;
      }
      HapticFeedback.lightImpact();
      if (!ConversationMotion.reduced(context)) {
        await _badge.forward(from: 0).orCancel;
        if (mounted && generation == _identityGeneration) _badge.reverse();
      }
    } catch (_) {
      // The shared action handler owns safe error/pending presentation. A
      // failed action must not produce a success badge or an unhandled Future.
    } finally {
      if (mounted && generation == _identityGeneration) _likePending = false;
    }
  }

  void _doubleTap() {
    if (_touchEnabled && !_blocked) _like();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _identityGeneration++;
    _return.dispose();
    _badge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reply = widget.enabled ? widget.onReply : null;
    final like =
        widget.enabled && widget.quickLikeEnabled && widget.onLike != null;
    return Semantics(
      customSemanticsActions: {
        if (reply != null)
          CustomSemanticsAction(label: widget.replyLabel): reply,
        if (like) CustomSemanticsAction(label: widget.likeLabel): _like,
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
                    () => _MessageDoubleTapRecognizer(_pointerAllowed),
                    (recognizer) => recognizer..onDoubleTap = _doubleTap,
                  ),
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
                offset: Offset(_offset, 0),
                child: widget.child,
              ),
              PositionedDirectional(
                end: 8,
                bottom: 2,
                child: IgnorePointer(
                  child: ExcludeSemantics(
                    child: AnimatedBuilder(
                      animation: _badge,
                      builder: (context, child) => Opacity(
                        opacity: _badge.value,
                        child: Transform.scale(
                          scale:
                              .85 +
                              .15 * Curves.easeOut.transform(_badge.value),
                          child: child,
                        ),
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(5),
                          child: widget.likeEmoji.startsWith('mxc://')
                              ? const Icon(
                                  Icons.add_reaction_outlined,
                                  size: 18,
                                )
                              : Text(
                                  widget.likeEmoji,
                                  style: const TextStyle(fontSize: 18),
                                  maxLines: 1,
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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

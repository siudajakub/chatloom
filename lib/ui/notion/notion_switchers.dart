// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion_motion.dart';
import 'notion_tokens.dart';

/// Fade-through between two states of the same slot (a title, a list for a
/// different filter, an empty state replacing content): the old child fades
/// out fast, then the new one fades in while scaling up from 96 %.
///
/// Give each state's child a distinct key (`ValueKey(filter)`). Both
/// children are alive during the swap, so never use it around subtrees with
/// GlobalKeys or around whole pages.
///
/// ```dart
/// NotionFadeThrough(child: Text(title, key: ValueKey(title)))
/// ```
class NotionFadeThrough extends StatelessWidget {
  const NotionFadeThrough({
    super.key,
    required this.child,
    this.duration = NotionMotion.medium,
    this.alignment = AlignmentDirectional.topStart,
  });

  final Widget child;
  final Duration duration;
  final AlignmentGeometry alignment;

  static const _inCurve = Interval(.3, 1, curve: NotionMotion.standard);
  static final _scale = Tween<double>(begin: .96, end: 1).chain(
    CurveTween(curve: const Interval(.3, 1, curve: NotionMotion.emphasized)),
  );

  @override
  Widget build(BuildContext context) {
    final reduced = NotionMotion.reduced(context);
    return AnimatedSwitcher(
      duration: reduced ? Duration.zero : duration,
      reverseDuration: reduced ? Duration.zero : NotionMotion.instant,
      layoutBuilder: (current, previous) =>
          Stack(alignment: alignment, children: [...previous, ?current]),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation.drive(CurveTween(curve: _inCurve)),
        child: ScaleTransition(scale: animation.drive(_scale), child: child),
      ),
      child: child,
    );
  }
}

/// Morph between glyphs or small buttons in one slot (mic → send, play →
/// pause, idle → busy): the new child scales up from 60 % with a slight
/// rotation while the old one shrinks away. Key each state's child.
///
/// ```dart
/// NotionMorphSwitcher(
///   bounce: true, // send button only
///   child: canSend ? Icon(Icons.send, key: const ValueKey('send'))
///                  : Icon(Icons.mic, key: const ValueKey('mic')),
/// )
/// ```
class NotionMorphSwitcher extends StatelessWidget {
  const NotionMorphSwitcher({
    super.key,
    required this.child,
    this.bounce = false,
    this.rotate = true,
  });

  final Widget child;

  /// Overshoot on arrival ([NotionMotion.bouncy]); reward elements only.
  final bool bounce;

  /// Add a −0.08 turn twist.
  final bool rotate;

  static const _fade = Interval(0, .5, curve: NotionMotion.standard);

  @override
  Widget build(BuildContext context) {
    final reduced = NotionMotion.reduced(context);
    final curve = bounce ? NotionMotion.bouncyCurve : NotionMotion.snappyCurve;
    final scale = Tween<double>(
      begin: .6,
      end: 1,
    ).chain(CurveTween(curve: curve));
    final turns = Tween<double>(
      begin: -.08,
      end: 0,
    ).chain(CurveTween(curve: NotionMotion.emphasized));
    return AnimatedSwitcher(
      duration: reduced
          ? Duration.zero
          : (bounce ? NotionMotion.bouncyCurve.duration : NotionMotion.short),
      reverseDuration: reduced ? Duration.zero : NotionMotion.instant,
      transitionBuilder: (child, animation) {
        Widget result = ScaleTransition(
          scale: animation.drive(scale),
          child: child,
        );
        if (rotate) {
          result = RotationTransition(
            turns: animation.drive(turns),
            child: result,
          );
        }
        return FadeTransition(
          opacity: animation.drive(CurveTween(curve: _fade)),
          child: result,
        );
      },
      child: child,
    );
  }
}

/// A number that rolls when it changes: up when it grows, down when it
/// shrinks (unread counts, reaction counts, members).
///
/// ```dart
/// NotionAnimatedCount(count: unread, style: NotionType.micro)
/// ```
class NotionAnimatedCount extends StatefulWidget {
  const NotionAnimatedCount({
    super.key,
    required this.count,
    this.style,
    this.format,
  });

  final int count;
  final TextStyle? style;

  /// Custom label, e.g. `(n) => n > 99 ? '99+' : '$n'`.
  final String Function(int count)? format;

  @override
  State<NotionAnimatedCount> createState() => _NotionAnimatedCountState();
}

class _NotionAnimatedCountState extends State<NotionAnimatedCount> {
  final ValueNotifier<double> _direction = ValueNotifier(1);

  @override
  void didUpdateWidget(NotionAnimatedCount oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.count != widget.count) {
      _direction.value = widget.count > oldWidget.count ? 1 : -1;
    }
  }

  @override
  void dispose() {
    _direction.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.format?.call(widget.count) ?? '${widget.count}';
    final text = Text(
      label,
      key: ValueKey(widget.count),
      style: widget.style,
      maxLines: 1,
      softWrap: false,
    );
    if (NotionMotion.reduced(context)) return text;
    return ClipRect(
      child: AnimatedSwitcher(
        duration: NotionMotion.short,
        reverseDuration: NotionMotion.quick,
        switchInCurve: NotionMotion.emphasized,
        switchOutCurve: NotionMotion.exitFast,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: _Roll(
            animation: animation,
            direction: _direction,
            child: child,
          ),
        ),
        child: text,
      ),
    );
  }
}

class _Roll extends AnimatedWidget {
  _Roll({required this.animation, required this.direction, required this.child})
    : super(listenable: Listenable.merge([animation, direction]));

  final Animation<double> animation;
  final ValueNotifier<double> direction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Incoming text arrives from the side the number moves to; outgoing
    // text leaves the other way.
    final travel = (1 - animation.value) * .7 * direction.value;
    final leaving = animation.status == AnimationStatus.reverse;
    return FractionalTranslation(
      translation: Offset(0, leaving ? -travel : travel),
      child: child,
    );
  }
}

/// Reveals or hides [child] by growing/shrinking its size along [axis] with
/// a fade (callouts, reply previews, typing indicators, conditional
/// settings). Layout animates, so use it for single elements, never for
/// rows in bulk. When hidden and settled the child is not built.
///
/// ```dart
/// NotionSizeReveal(visible: problem != null, child: NotionCallout(...))
/// ```
class NotionSizeReveal extends StatefulWidget {
  const NotionSizeReveal({
    super.key,
    required this.visible,
    required this.child,
    this.axis = Axis.vertical,
    this.alignment = AlignmentDirectional.topStart,
    this.duration = NotionMotion.medium,
    this.revealOnMount = false,
  });

  final bool visible;
  final Widget child;
  final Axis axis;

  /// Which edge stays put while the size changes.
  final AlignmentGeometry alignment;
  final Duration duration;

  /// Animate in on first build when [visible] (otherwise it starts open).
  final bool revealOnMount;

  @override
  State<NotionSizeReveal> createState() => _NotionSizeRevealState();
}

class _NotionSizeRevealState extends State<NotionSizeReveal>
    with SingleTickerProviderStateMixin {
  // Created on the first change of [visible] (or a reveal on mount): rows
  // whose element never changes cost no ticker. Until then the reveal is
  // settled at its initial state.
  AnimationController? _motion;
  CurvedAnimation? _sizeCurve, _fadeCurve;
  late final bool _initiallyVisible = widget.visible && !widget.revealOnMount;

  AnimationController get _controller {
    final existing = _motion;
    if (existing != null) return existing;
    final controller = _motion = AnimationController(
      vsync: this,
      duration: widget.duration,
      reverseDuration: NotionMotion.short,
      value: _initiallyVisible ? 1 : 0,
    )..addStatusListener(_status);
    _sizeCurve = CurvedAnimation(
      parent: controller,
      curve: NotionMotion.emphasized,
      reverseCurve: NotionMotion.exitFast,
    );
    _fadeCurve = CurvedAnimation(
      parent: controller,
      curve: const Interval(.25, 1, curve: NotionMotion.standard),
      reverseCurve: const Interval(.4, 1, curve: NotionMotion.standard),
    );
    return controller;
  }

  Animation<double> get _size =>
      _sizeCurve ??
      (_initiallyVisible
          ? kAlwaysCompleteAnimation
          : kAlwaysDismissedAnimation);
  Animation<double> get _fade =>
      _fadeCurve ??
      (_initiallyVisible
          ? kAlwaysCompleteAnimation
          : kAlwaysDismissedAnimation);
  bool get _dismissed => _motion?.isDismissed ?? !_initiallyVisible;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.visible && _dismissed) _show();
  }

  void _status(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) setState(() {});
  }

  void _show() {
    if (NotionMotion.reduced(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(NotionSizeReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    _motion?.duration = widget.duration;
    if (oldWidget.visible == widget.visible) return;
    if (widget.visible) {
      _show();
    } else if (NotionMotion.reduced(context)) {
      _controller.value = 0;
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _sizeCurve?.dispose();
    _fadeCurve?.dispose();
    _motion?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible && _dismissed) {
      return const SizedBox.shrink();
    }
    final alignment = widget.alignment.resolve(Directionality.maybeOf(context));
    final vertical = widget.axis == Axis.vertical;
    return AnimatedBuilder(
      animation: _size,
      builder: (context, child) {
        final factor = _size.value.clamp(0.0, 1.0);
        return ClipRect(
          clipBehavior: factor >= 1 ? Clip.none : Clip.hardEdge,
          child: Align(
            alignment: alignment,
            heightFactor: vertical ? factor : null,
            widthFactor: vertical ? null : factor,
            child: child,
          ),
        );
      },
      child: FadeTransition(opacity: _fade, child: widget.child),
    );
  }
}

/// Pops [child] in with a spring (badges, reaction chips, presence dots,
/// empty-state icons): scales up from [from] with a slight overshoot and
/// fades in on first build, pulses again when [trigger] changes, and pops
/// out (keeping its layout slot) when [visible] turns false.
///
/// ```dart
/// NotionPop(trigger: unread, child: badge)
/// NotionPop(visible: hasUnreadMark, child: dot)
/// ```
class NotionPop extends StatefulWidget {
  const NotionPop({
    super.key,
    required this.child,
    this.trigger,
    this.visible = true,
    this.from = NotionMotion.popFrom,
    this.playOnMount = true,
    this.bounce = true,
    this.alignment = Alignment.center,
    this.afterRoute = false,
  });

  final Widget child;

  /// Hold the mount pop until the hosting route finished its push.
  final bool afterRoute;

  /// A value whose change replays a smaller pop (a new count).
  final Object? trigger;
  final bool visible;

  /// Start scale on mount and target scale when hiding.
  final double from;
  final bool playOnMount;

  /// [NotionMotion.bouncy] (default, reward elements) or critically damped.
  final bool bounce;
  final Alignment alignment;

  @override
  State<NotionPop> createState() => _NotionPopState();
}

class _NotionPopState extends State<NotionPop> with TickerProviderStateMixin {
  late final AnimationController _scale = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );
  late final AnimationController _opacity = AnimationController(
    vsync: this,
    duration: NotionMotion.quick,
    reverseDuration: NotionMotion.instant,
    value: widget.visible ? 1 : 0,
  );
  bool _mounted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_mounted) return;
    _mounted = true;
    if (!widget.visible) {
      _scale.value = widget.from;
      return;
    }
    if (widget.playOnMount && !NotionMotion.reduced(context)) {
      _scale.value = widget.from;
      _opacity.value = 0;
      if (widget.afterRoute) {
        NotionMotion.whenRouteSettled(context, _play);
      } else {
        _play();
      }
    }
  }

  void _play() {
    if (!mounted || !widget.visible) return;
    _opacity.forward();
    _springTo(1);
  }

  void _springTo(double target) {
    _scale.animateWith(
      NotionMotion.springTo(
        widget.bounce && target == 1
            ? NotionMotion.bouncy
            : NotionMotion.snappy,
        _scale.value,
        target,
        velocity: _scale.velocity,
      ),
    );
  }

  @override
  void didUpdateWidget(NotionPop oldWidget) {
    super.didUpdateWidget(oldWidget);
    final reduced = NotionMotion.reduced(context);
    if (oldWidget.visible != widget.visible) {
      if (reduced) {
        _scale.value = widget.visible ? 1 : widget.from;
        _opacity.value = widget.visible ? 1 : 0;
      } else if (widget.visible) {
        _opacity.forward();
        _springTo(1);
      } else {
        _opacity.reverse();
        _springTo(widget.from);
      }
      return;
    }
    if (widget.visible && oldWidget.trigger != widget.trigger && !reduced) {
      // Kick the spring inwards: a smooth dip to ~92 % and back.
      _scale.animateWith(
        NotionMotion.springTo(
          widget.bounce ? NotionMotion.bouncy : NotionMotion.snappy,
          _scale.value,
          1,
          velocity: -5,
        ),
      );
    }
  }

  @override
  void dispose() {
    _scale.dispose();
    _opacity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !widget.visible,
    child: FadeTransition(
      opacity: _opacity,
      child: ScaleTransition(
        scale: _scale,
        alignment: widget.alignment,
        child: widget.child,
      ),
    ),
  );
}

/// Flashes a soft `selected` background behind [child] when [trigger]
/// changes (not on first build unless [playOnMount]): a conversation that
/// just moved to the top, a setting that was just applied, a row a merge
/// just created. Paint only, no layout.
///
/// ```dart
/// NotionRowHighlight(trigger: room.lastEventId, child: row)
/// ```
class NotionRowHighlight extends StatefulWidget {
  const NotionRowHighlight({
    super.key,
    required this.trigger,
    required this.child,
    this.color,
    this.borderRadius = NotionRadius.mdAll,
    this.playOnMount = false,
  });

  final Object? trigger;

  /// Flash once when first built too (never for rows built by scrolling:
  /// the caller passes true only for a row an action just produced).
  final bool playOnMount;
  final Widget child;

  /// Defaults to `context.notion.colors.selected`.
  final Color? color;
  final BorderRadius borderRadius;

  @override
  State<NotionRowHighlight> createState() => _NotionRowHighlightState();
}

class _NotionRowHighlightState extends State<NotionRowHighlight>
    with SingleTickerProviderStateMixin {
  // Created on the first flash: rows that never flash cost no ticker.
  AnimationController? _flash;
  AnimationController get _controller => _flash ??= AnimationController(
    vsync: this,
    duration: NotionMotion.highlight,
  );
  static final _alpha = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 0,
        end: 1,
      ).chain(CurveTween(curve: NotionMotion.standard)),
      weight: 15,
    ),
    TweenSequenceItem(tween: ConstantTween<double>(1), weight: 30),
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 1,
        end: 0,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 55,
    ),
  ]);

  bool _mounted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_mounted) return;
    _mounted = true;
    if (widget.playOnMount && !NotionMotion.reduced(context)) {
      _controller.forward(from: 0);
    }
  }

  @override
  void didUpdateWidget(NotionRowHighlight oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trigger != widget.trigger && !NotionMotion.reduced(context)) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _flash?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _HighlightPainter(
      animation: _flash?.drive(_alpha) ?? kAlwaysDismissedAnimation,
      color: widget.color ?? context.notion.colors.selected,
      borderRadius: widget.borderRadius,
      direction: Directionality.maybeOf(context),
    ),
    child: widget.child,
  );
}

class _HighlightPainter extends CustomPainter {
  _HighlightPainter({
    required this.animation,
    required this.color,
    required this.borderRadius,
    required this.direction,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final Color color;
  final BorderRadius borderRadius;
  final TextDirection? direction;

  @override
  void paint(Canvas canvas, Size size) {
    final t = animation.value;
    if (t <= 0) return;
    canvas.drawRRect(
      borderRadius.toRRect(Offset.zero & size),
      Paint()..color = color.withValues(alpha: color.a * t),
    );
  }

  @override
  bool shouldRepaint(_HighlightPainter old) =>
      old.color != color ||
      old.borderRadius != borderRadius ||
      !identical(old.animation, animation);
}

/// Shows [child] only after [delay] (then fades it in), so an operation that
/// finishes quickly never flashes a loader. Ticker-driven: no timers, and it
/// waits while `TickerMode` is off.
///
/// ```dart
/// NotionDelayedReveal(child: LinearProgressIndicator())
/// ```
class NotionDelayedReveal extends StatefulWidget {
  const NotionDelayedReveal({
    super.key,
    required this.child,
    this.delay = NotionMotion.loaderGrace,
    this.placeholder = const SizedBox.shrink(),
  });

  final Widget child;
  final Duration delay;

  /// Shown before [delay]; reserve the loader's space here if needed.
  final Widget placeholder;

  @override
  State<NotionDelayedReveal> createState() => _NotionDelayedRevealState();
}

class _NotionDelayedRevealState extends State<NotionDelayedReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _fade;
  late final double _threshold;
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    final total = widget.delay + NotionMotion.short;
    _threshold = widget.delay.inMicroseconds / total.inMicroseconds;
    _controller = AnimationController(vsync: this, duration: total)
      ..addListener(_tick)
      ..forward();
    _fade = CurvedAnimation(
      parent: _controller,
      curve: Interval(_threshold, 1, curve: NotionMotion.standard),
    );
  }

  void _tick() {
    if (_shown || _controller.value < _threshold) return;
    _controller.removeListener(_tick);
    if (NotionMotion.reduced(context)) _controller.value = 1;
    setState(() => _shown = true);
  }

  @override
  void dispose() {
    _fade.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _shown
      ? FadeTransition(opacity: _fade, child: widget.child)
      : widget.placeholder;
}

/// A spinner that appears only when the wait is long enough to notice
/// ([NotionMotion.loaderGrace]); its square is reserved from the start, so
/// nothing shifts when it shows up. After [maxSpin] it freezes on its last
/// frame (a static ring): a wait that never ends draws no more frames.
///
/// ```dart
/// if (loading) const NotionDelayedSpinner()
/// ```
class NotionDelayedSpinner extends StatefulWidget {
  const NotionDelayedSpinner({
    super.key,
    this.size = NotionSize.icon,
    this.strokeWidth = 2,
    this.color,
    this.delay = NotionMotion.loaderGrace,
    this.maxSpin = NotionMotion.loopCap,
    this.semanticsLabel,
  });

  final double size;
  final double strokeWidth;

  /// Read by screen readers instead of the indicator's default.
  final String? semanticsLabel;

  /// Defaults to `context.notion.colors.textSecondary`.
  final Color? color;
  final Duration delay;

  /// How long the ring spins once shown; null spins until removed.
  final Duration? maxSpin;

  @override
  State<NotionDelayedSpinner> createState() => _NotionDelayedSpinnerState();
}

class _NotionDelayedSpinnerState extends State<NotionDelayedSpinner>
    with SingleTickerProviderStateMixin {
  AnimationController? _cap;
  bool _rested = false;

  @override
  void initState() {
    super.initState();
    final maxSpin = widget.maxSpin;
    if (maxSpin == null) return;
    // Ticker-driven (no timer): it also waits while `TickerMode` is off.
    _cap = AnimationController(
      vsync: this,
      duration: widget.delay + NotionMotion.short + maxSpin,
    );
    _cap!.forward().then((_) {
      if (mounted) setState(() => _rested = true);
    });
  }

  @override
  void dispose() {
    _cap?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: widget.size,
    child: TickerMode(
      // Muting the indicator's own ticker keeps its last frame on screen.
      enabled: !_rested,
      // A zero [delay] shows the ring on the first frame (the wait is
      // already visible elsewhere, e.g. a busy send glyph or a loader that
      // appeared after its own grace); only [maxSpin] applies then.
      child: widget.delay == Duration.zero
          ? _ring
          : NotionDelayedReveal(delay: widget.delay, child: _ring),
    ),
  );

  Widget get _ring => CircularProgressIndicator(
    strokeWidth: widget.strokeWidth,
    color: widget.color ?? context.notion.colors.textSecondary,
    semanticsLabel: widget.semanticsLabel,
  );
}

/// Brings [child] back in with a short fade and rise whenever [trigger]
/// changes, keeping its element: one slot that swaps between kept-alive
/// states (the composer and the search bar, the recorder and the composer),
/// where a switcher would mount a second live copy (a focus node, a running
/// recorder). The outgoing state is gone at once (Telegram); the incoming
/// one rises [rise] px over [duration] on `emphasized` and settles to
/// identity (opacity 1, offset 0).
///
/// Never plays on mount, creates no controller until the first change, and
/// does nothing under reduced motion. The tree has one shape throughout, so
/// [child] never remounts.
///
/// ```dart
/// NotionReappear(trigger: searching, child: searching ? bar : composer)
/// ```
class NotionReappear extends StatefulWidget {
  const NotionReappear({
    super.key,
    required this.trigger,
    required this.child,
    this.rise = NotionMotion.rise,
    this.duration = NotionMotion.short,
  });

  /// A value whose change replays the entrance.
  final Object? trigger;
  final Widget child;

  /// Vertical travel in logical pixels (positive: rises from below).
  final double rise;
  final Duration duration;

  @override
  State<NotionReappear> createState() => _NotionReappearState();
}

class _NotionReappearState extends State<NotionReappear>
    with SingleTickerProviderStateMixin {
  static const _fadeCurve = Interval(0, .7, curve: NotionMotion.standard);

  AnimationController? _motion;
  CurvedAnimation? _fade, _move;

  void _play() {
    final controller = _motion ??= AnimationController(
      vsync: this,
      duration: widget.duration,
    );
    _fade ??= CurvedAnimation(parent: controller, curve: _fadeCurve);
    _move ??= CurvedAnimation(
      parent: controller,
      curve: NotionMotion.emphasized,
    );
    controller.forward(from: 0);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (NotionMotion.reduced(context)) _motion?.value = 1;
  }

  @override
  void didUpdateWidget(NotionReappear oldWidget) {
    super.didUpdateWidget(oldWidget);
    _motion?.duration = widget.duration;
    if (oldWidget.trigger == widget.trigger) return;
    if (NotionMotion.reduced(context)) {
      _motion?.value = 1;
    } else {
      _play();
    }
  }

  @override
  void dispose() {
    _fade?.dispose();
    _move?.dispose();
    _motion?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final move = _move ?? kAlwaysCompleteAnimation;
    return FadeTransition(
      opacity: _fade ?? kAlwaysCompleteAnimation,
      child: AnimatedBuilder(
        animation: move,
        child: widget.child,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, widget.rise * (1 - move.value)),
          child: child,
        ),
      ),
    );
  }
}

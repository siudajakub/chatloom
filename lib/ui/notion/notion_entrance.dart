// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The only file that imports flutter_animate. Effects are driven by
// controllers owned here; the `Animate` widget is never mounted because it
// always schedules a `Future.delayed` timer (even for a zero delay), which
// leaves pending timers in widget tests and fires for disposed rows.
import 'dart:math' as math;

import 'package:flutter_animate/flutter_animate.dart'
    show
        Animate,
        Effect,
        EffectEntry,
        FadeEffect,
        MoveEffect,
        ScaleEffect,
        ShakeEffect;
import 'package:material_ui/material_ui.dart';

import 'notion_motion.dart';

/// One-shot entrance: fades [child] in while it rises by [rise] (and scales
/// from [scale]), then settles to identity (opacity 1, offset 0, scale 1).
///
/// * Plays once per mount, after the hosting route finished its push
///   ([afterRoute]); instantly visible under reduced motion or with
///   `enabled: false`.
/// * In a list, give each item its [index] (or put the list in a
///   [NotionEntranceScope], which numbers items and stops the stagger once
///   the first screenful has played, so rows built by scrolling never
///   animate). Delays are capped at [NotionMotion.staggerCap] items.
/// * Never wrap a subtree that holds GlobalKeys you swap elsewhere.
///
/// ```dart
/// NotionEntrance(child: header)
/// NotionEntranceScope(child: ListView(children: [
///   for (final row in rows) NotionEntrance(playKey: row.id, child: row),
/// ]))
/// ```
class NotionEntrance extends StatefulWidget {
  const NotionEntrance({
    super.key,
    required this.child,
    this.index,
    this.rise = NotionMotion.rise,
    this.slide = 0,
    this.scale = 1,
    this.duration = NotionMotion.medium,
    this.afterRoute = true,
    this.playKey,
    this.enabled = true,
    this.alignment = Alignment.center,
  });

  final Widget child;

  /// Position in a stagger. Null: numbered by the [NotionEntranceScope], or 0.
  final int? index;

  /// Vertical travel in logical pixels (positive: rises from below).
  final double rise;

  /// Horizontal travel in logical pixels (positive: from the end side).
  final double slide;

  /// Start scale; 1 keeps the size.
  final double scale;

  final Duration duration;

  /// Wait until the hosting page route finished animating in.
  final bool afterRoute;

  /// Identity inside a [NotionEntranceScope]: an item that already played
  /// (scrolled away and rebuilt) appears without animation.
  final Object? playKey;

  final bool enabled;

  /// Scale origin.
  final Alignment alignment;

  /// Wraps each child in a [NotionEntrance] with its list index.
  static List<Widget> stagger(
    List<Widget> children, {
    double rise = NotionMotion.riseList,
    bool afterRoute = true,
  }) => [
    for (var i = 0; i < children.length; i++)
      NotionEntrance(
        index: i,
        rise: rise,
        afterRoute: afterRoute,
        child: children[i],
      ),
  ];

  @override
  State<NotionEntrance> createState() => _NotionEntranceState();
}

class _NotionEntranceState extends State<NotionEntrance>
    with SingleTickerProviderStateMixin {
  // An entrance that does not play (rows built by scrolling, reduced motion,
  // disabled) never creates its controller or effect chain.
  AnimationController? _motion;
  AnimationController get _controller =>
      _motion ??= AnimationController(vsync: this, duration: widget.duration);
  bool _skip = false;
  bool _decided = false;
  int _index = 0;
  Widget? _chain;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = NotionMotion.reduced(context);
    if (_decided) {
      if (reduced) _motion?.value = 1;
      return;
    }
    _decided = true;
    final scope = _NotionEntranceScopeState._maybeOf(context);
    final claim =
        scope?._claim(widget.playKey, widget.index) ??
        (play: true, index: widget.index ?? 0);
    if (!widget.enabled || !claim.play || reduced) {
      _skip = true;
      return;
    }
    _index = claim.index;
    _controller.duration = NotionMotion.staggerFor(_index) + widget.duration;
    if (widget.afterRoute) {
      NotionMotion.whenRouteSettled(context, () => _start(scope));
    } else {
      _start(scope);
    }
  }

  void _start(_NotionEntranceScopeState? scope) {
    if (!mounted || _controller.value != 0 || _controller.isAnimating) return;
    _controller.forward();
    scope?._started();
  }

  @override
  void didUpdateWidget(NotionEntrance oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _motion?.value = 1;
    if (oldWidget.rise != widget.rise ||
        oldWidget.slide != widget.slide ||
        oldWidget.scale != widget.scale ||
        oldWidget.alignment != widget.alignment) {
      _chain = null;
    }
  }

  @override
  void dispose() {
    _motion?.dispose();
    super.dispose();
  }

  Widget _buildChain(BuildContext context) {
    final delay = NotionMotion.staggerFor(_index);
    final duration = widget.duration;
    final rtl = Directionality.maybeOf(context) == TextDirection.rtl;
    return _EffectChain.build(context, _controller, [
      _SemanticFadeEffect(
        delay: delay,
        duration: duration * .6,
        curve: NotionMotion.standard,
        begin: 0,
        end: 1,
      ),
      if (widget.rise != 0 || widget.slide != 0)
        MoveEffect(
          delay: delay,
          duration: duration,
          curve: NotionMotion.emphasized,
          begin: Offset(rtl ? -widget.slide : widget.slide, widget.rise),
          end: Offset.zero,
        ),
      if (widget.scale != 1)
        ScaleEffect(
          delay: delay,
          duration: duration,
          curve: NotionMotion.emphasized,
          begin: Offset(widget.scale, widget.scale),
          end: const Offset(1, 1),
          alignment: widget.alignment,
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) => _EffectSlot(
    content: widget.child,
    child: _skip ? const _SlotChild() : _chain ??= _buildChain(context),
  );
}

/// Numbers the [NotionEntrance]s below it and limits them to the first
/// appearance of a page: once the first screenful has played (about
/// `staggerCap × stagger + medium`), later entrances render instantly.
class NotionEntranceScope extends StatefulWidget {
  const NotionEntranceScope({super.key, required this.child});

  final Widget child;

  @override
  State<NotionEntranceScope> createState() => _NotionEntranceScopeState();
}

class _NotionEntranceScopeState extends State<NotionEntranceScope>
    with SingleTickerProviderStateMixin {
  int _next = 0;
  bool _closed = false;
  final Set<Object> _played = {};
  AnimationController? _window;

  static _NotionEntranceScopeState? _maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_EntranceScopeMarker>()?.state;

  ({bool play, int index}) _claim(Object? key, int? index) {
    if (_closed) return (play: false, index: 0);
    if (key != null && !_played.add(key)) return (play: false, index: 0);
    final resolved = index ?? _next;
    _next = math.max(_next, resolved + 1);
    return (play: true, index: resolved);
  }

  void _started() {
    if (_window != null) return;
    _window =
        AnimationController(
            vsync: this,
            duration:
                NotionMotion.staggerFor(NotionMotion.staggerCap) +
                NotionMotion.medium,
          )
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed) _closed = true;
          })
          ..forward();
  }

  @override
  void dispose() {
    _window?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _EntranceScopeMarker(state: this, child: widget.child);
}

class _EntranceScopeMarker extends InheritedWidget {
  const _EntranceScopeMarker({required this.state, required super.child});

  final _NotionEntranceScopeState state;

  @override
  bool updateShouldNotify(_EntranceScopeMarker oldWidget) => false;
}

/// A [Column] whose children enter one after another.
class NotionStaggeredColumn extends StatelessWidget {
  const NotionStaggeredColumn({
    super.key,
    required this.children,
    this.crossAxisAlignment = CrossAxisAlignment.stretch,
    this.mainAxisSize = MainAxisSize.min,
    this.rise = NotionMotion.riseList,
    this.afterRoute = true,
  });

  final List<Widget> children;
  final CrossAxisAlignment crossAxisAlignment;
  final MainAxisSize mainAxisSize;
  final double rise;
  final bool afterRoute;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: crossAxisAlignment,
    mainAxisSize: mainAxisSize,
    children: NotionEntrance.stagger(
      children,
      rise: rise,
      afterRoute: afterRoute,
    ),
  );
}

/// Shakes [child] sideways whenever [trigger] changes (not on first build):
/// a wrong code, a rejected action. Nothing under reduced motion.
///
/// ```dart
/// NotionShake(trigger: errorCount, child: pinField)
/// ```
class NotionShake extends StatefulWidget {
  const NotionShake({
    super.key,
    required this.trigger,
    required this.child,
    this.distance = 6,
  });

  final Object? trigger;
  final Widget child;
  final double distance;

  @override
  State<NotionShake> createState() => _NotionShakeState();
}

class _NotionShakeState extends State<NotionShake>
    with SingleTickerProviderStateMixin {
  static const _duration = Duration(milliseconds: 420);
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _duration,
  )..addStatusListener(_rest);

  /// The wave ends at sin(2πn), a hair off zero; rest exactly at identity.
  void _rest(AnimationStatus status) {
    if (status == AnimationStatus.completed) _controller.value = 0;
  }

  Widget? _chain;

  @override
  void didUpdateWidget(NotionShake oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.distance != widget.distance) _chain = null;
    if (oldWidget.trigger != widget.trigger && !NotionMotion.reduced(context)) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _EffectSlot(
    content: widget.child,
    child: _chain ??= _EffectChain.build(context, _controller, [
      ShakeEffect(
        duration: _duration,
        curve: Curves.easeOut,
        hz: 7,
        rotation: 0,
        offset: Offset(widget.distance, 0),
      ),
    ]),
  );
}

/// Builds flutter_animate effects once around a placeholder slot, driven by
/// a controller owned by the caller (no `Animate` widget, no timers, no
/// per-rebuild `CurvedAnimation`s). The real child reaches the slot through
/// [_EffectSlot], so parent rebuilds only rebuild the slot.
abstract final class _EffectChain {
  /// Owner required by [EffectEntry]; never mounted.
  static final Animate _owner =
      Animate(); // design-lint: allow unmounted EffectEntry owner

  static Widget build(
    BuildContext context,
    AnimationController controller,
    List<Effect<dynamic>> effects,
  ) {
    final entries = [
      for (final effect in effects)
        EffectEntry(
          effect: effect,
          delay: effect.delay ?? Duration.zero,
          duration: effect.duration ?? NotionMotion.medium,
          curve: effect.curve ?? Curves.linear,
          owner: _owner,
        ),
    ];
    final total = entries.fold(
      Duration.zero,
      (end, e) => e.end > end ? e.end : end,
    );
    if (total > Duration.zero) controller.duration = total;
    Widget child = const _SlotChild();
    for (final entry in entries) {
      child = entry.effect.build(context, child, controller, entry);
    }
    return child;
  }
}

class _EffectSlot extends InheritedWidget {
  const _EffectSlot({required this.content, required super.child});

  final Widget content;

  @override
  bool updateShouldNotify(_EffectSlot oldWidget) =>
      !identical(oldWidget.content, content);
}

class _SlotChild extends StatelessWidget {
  const _SlotChild();

  @override
  Widget build(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_EffectSlot>()!.content;
}

/// [FadeEffect] that keeps the child in the semantics tree while it is fully
/// transparent, so screen readers never lose an entering section.
class _SemanticFadeEffect extends FadeEffect {
  const _SemanticFadeEffect({
    super.delay,
    super.duration,
    super.curve,
    super.begin,
    super.end,
  });

  @override
  Widget build(
    BuildContext context,
    Widget child,
    AnimationController controller,
    EffectEntry entry,
  ) => FadeTransition(
    opacity: buildAnimation(controller, entry),
    alwaysIncludeSemantics: true,
    child: child,
  );
}

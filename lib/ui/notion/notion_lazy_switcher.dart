// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion_motion.dart';

/// How [NotionLazySwitcher] swaps its child.
enum NotionLazySwitch {
  /// Cross-fade (a line of row text: preview, time).
  fade,

  /// [NotionMorphSwitcher]'s glyph swap without the twist: the new child
  /// scales up from [NotionMotion.popFrom] while the old one fades away.
  morph,
}

/// A switcher for list rows: the same motion as `AnimatedSwitcher`
/// ([NotionFadeThrough]-like fade or [NotionMorphSwitcher]-like morph), but
/// no `AnimationController` exists until the child is first replaced by one
/// with another key or type. Rows built while scrolling therefore cost no
/// ticker (an `AnimatedSwitcher` creates one per mount), and the first build
/// never animates.
///
/// ```dart
/// NotionLazySwitcher(child: Text(time, key: ValueKey(time)))
/// NotionLazySwitcher(style: NotionLazySwitch.morph, bounce: true, child: badge)
/// ```
class NotionLazySwitcher extends StatefulWidget {
  const NotionLazySwitcher({
    super.key,
    required this.child,
    this.style = NotionLazySwitch.fade,
    this.bounce = false,
    this.alignment = AlignmentDirectional.topStart,
  });

  final Widget child;
  final NotionLazySwitch style;

  /// Overshoot on arrival ([NotionMotion.bouncy]); reward elements only.
  final bool bounce;
  final AlignmentGeometry alignment;

  /// Controllers created so far by all switchers (performance tests).
  @visibleForTesting
  static int debugControllers = 0;

  @override
  State<NotionLazySwitcher> createState() => _NotionLazySwitcherState();
}

class _NotionLazySwitcherState extends State<NotionLazySwitcher>
    with TickerProviderStateMixin {
  int _generation = 0;
  Widget? _outgoing;
  int _outgoingGeneration = 0;
  AnimationController? _in, _out;

  static final _fadeIn = CurveTween(curve: NotionMotion.standard);
  static final _fadeOut = Tween<double>(
    begin: 1,
    end: 0,
  ).chain(CurveTween(curve: NotionMotion.exitFast));
  static const _morphFade = Interval(0, .5, curve: NotionMotion.standard);

  Duration get _inDuration => switch (widget.style) {
    NotionLazySwitch.fade => NotionMotion.short,
    NotionLazySwitch.morph =>
      widget.bounce ? NotionMotion.bouncyCurve.duration : NotionMotion.short,
  };

  Duration get _outDuration => switch (widget.style) {
    NotionLazySwitch.fade => NotionMotion.quick,
    NotionLazySwitch.morph => NotionMotion.instant,
  };

  @override
  void didUpdateWidget(NotionLazySwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (Widget.canUpdate(oldWidget.child, widget.child)) return;
    final previous = _generation++;
    if (NotionMotion.reduced(context)) {
      _outgoing = null;
      _in?.value = 1;
      _out?.value = 1;
      return;
    }
    // The old child leaves from where its own entrance got to (like
    // `AnimatedSwitcher`): one that never became visible leaves at once.
    final shown = _in?.value ?? 1;
    _outgoing = shown > 0 ? oldWidget.child : null;
    _outgoingGeneration = previous;
    final incoming = _in ??= _controller();
    incoming
      ..duration = _inDuration
      ..forward(from: 0);
    if (_outgoing == null) return;
    final outgoing = _out ??= _controller()
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted) {
          setState(() => _outgoing = null);
        }
      });
    outgoing
      ..duration = _outDuration
      ..forward(from: 1 - shown);
  }

  AnimationController _controller() {
    NotionLazySwitcher.debugControllers++;
    return AnimationController(vsync: this);
  }

  @override
  void dispose() {
    _in?.dispose();
    _out?.dispose();
    super.dispose();
  }

  // Entering and leaving children have the same shape, so the old child
  // keeps its element when it starts to leave.
  Widget _enter(Widget child) =>
      IgnorePointer(ignoring: false, child: _enterTransition(child));

  Widget _enterTransition(Widget child) {
    final controller = _in;
    switch (widget.style) {
      case NotionLazySwitch.fade:
        return FadeTransition(
          opacity: controller == null
              ? kAlwaysCompleteAnimation
              : controller.drive(_fadeIn),
          child: child,
        );
      case NotionLazySwitch.morph:
        final curve = widget.bounce
            ? NotionMotion.bouncyCurve
            : NotionMotion.snappyCurve;
        return FadeTransition(
          opacity: controller == null
              ? kAlwaysCompleteAnimation
              : controller.drive(CurveTween(curve: _morphFade)),
          child: ScaleTransition(
            scale: controller == null
                ? kAlwaysCompleteAnimation
                : controller.drive(
                    Tween<double>(
                      begin: NotionMotion.popFrom,
                      end: 1,
                    ).chain(CurveTween(curve: curve)),
                  ),
            child: child,
          ),
        );
    }
  }

  Widget _exit(Widget child) {
    final opacity = _out!.drive(_fadeOut);
    return IgnorePointer(
      child: switch (widget.style) {
        NotionLazySwitch.fade => FadeTransition(opacity: opacity, child: child),
        NotionLazySwitch.morph => FadeTransition(
          opacity: opacity,
          child: ScaleTransition(
            scale: _out!.drive(
              Tween<double>(begin: 1, end: NotionMotion.popFrom),
            ),
            child: child,
          ),
        ),
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final outgoing = _outgoing;
    return Stack(
      alignment: widget.alignment,
      children: [
        if (outgoing != null)
          KeyedSubtree(
            key: ValueKey(_outgoingGeneration),
            child: _exit(outgoing),
          ),
        KeyedSubtree(key: ValueKey(_generation), child: _enter(widget.child)),
      ],
    );
  }
}

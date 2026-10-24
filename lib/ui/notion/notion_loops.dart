// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'notion_motion.dart';
import 'notion_tokens.dart';

/// Shared rules for looping animations: one repeating controller, started
/// only when motion is allowed. Tickers are muted under `TickerMode` off
/// (offstage routes, hidden tabs), so a hidden loop schedules no frames.
/// A loop runs at most [loopCap] and then rests on its static frame
/// (DESIGN.md: no endless animation); [restartLoop] starts it afresh.
mixin _NotionLoop<T extends StatefulWidget>
    on State<T>, SingleTickerProviderStateMixin<T> {
  late final AnimationController loop = AnimationController(
    vsync: this,
    duration: period,
  );

  Duration get period;
  bool get loopEnabled => true;

  /// Longest run of the loop; null loops until disabled.
  Duration? get loopCap => NotionMotion.loopCap;

  bool _rested = false;

  void syncLoop() {
    final run = loopEnabled && !_rested && !NotionMotion.reduced(context);
    if (run && !loop.isAnimating) {
      final cap = loopCap;
      loop
          .repeat(
            count: cap == null
                ? null
                : NotionMotion.loopCount(period, cap: cap),
          )
          // A stopped loop never completes this future; only the cap does.
          .then((_) {
            if (!mounted) return;
            setState(() {
              _rested = true;
              loop.value = 0;
            });
          });
    } else if (!run && (loop.isAnimating || loop.value != 0)) {
      loop
        ..stop()
        ..value = 0;
    }
  }

  /// Starts a rested loop again (the state it shows began anew).
  void restartLoop() {
    _rested = false;
    syncLoop();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    syncLoop();
  }

  @override
  void dispose() {
    loop.dispose();
    super.dispose();
  }
}

/// Three dots that rise and brighten in a wave: someone is typing.
/// Paint only (one `CustomPaint` behind a repaint boundary), static dots
/// under reduced motion.
///
/// ```dart
/// NotionSizeReveal(visible: typing, child: const NotionTypingDots())
/// ```
class NotionTypingDots extends StatefulWidget {
  const NotionTypingDots({super.key, this.size = 6, this.color});

  /// Dot diameter. The widget is `4.5 × size` wide and `3 × size` tall.
  final double size;

  /// Defaults to `context.notion.colors.textSecondary`.
  final Color? color;

  /// One wave across the dots.
  static const Duration period = Duration(milliseconds: 1200);

  @override
  State<NotionTypingDots> createState() => _NotionTypingDotsState();
}

class _NotionTypingDotsState extends State<NotionTypingDots>
    with SingleTickerProviderStateMixin, _NotionLoop {
  @override
  Duration get period => NotionTypingDots.period;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      size: Size(widget.size * 4.5, widget.size * 3),
      painter: _DotsPainter(
        loop,
        widget.color ?? context.notion.colors.textSecondary,
        widget.size,
        animated: loop.isAnimating,
      ),
    ),
  );
}

class _DotsPainter extends CustomPainter {
  _DotsPainter(this.animation, this.color, this.size, {required this.animated})
    : super(repaint: animation);

  final Animation<double> animation;
  final Color color;
  final double size;
  final bool animated;

  @override
  void paint(Canvas canvas, Size box) {
    final paint = Paint();
    for (var i = 0; i < 3; i++) {
      var wave = 0.0;
      if (animated) {
        final phase = (animation.value - i * .16) % 1;
        wave = phase < .6 ? math.sin(phase / .6 * math.pi) : 0;
      }
      paint.color = color.withValues(
        alpha: color.a * (animated ? .35 + .65 * wave : .7),
      );
      canvas.drawCircle(
        Offset(
          size * .75 + i * size * 1.5,
          box.height / 2 + size * .25 - wave * size * .65,
        ),
        size / 2,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DotsPainter old) =>
      old.color != color || old.size != size || old.animated != animated;
}

/// A soft ring that expands and fades behind [child] on a loop: a live call,
/// recording, an incoming call. Transform and opacity only; no box shadows.
/// Nothing under reduced motion or with `enabled: false`.
///
/// ```dart
/// NotionPulse(color: colors.danger, child: callButton)
/// ```
class NotionPulse extends StatefulWidget {
  const NotionPulse({
    super.key,
    required this.child,
    this.color,
    this.enabled = true,
    this.spread = 1.35,
    this.borderRadius = NotionRadius.pillAll,
    this.maxDuration = NotionMotion.liveLoopCap,
  });

  /// The ring rests after this long (null: until [enabled] turns off).
  final Duration? maxDuration;

  final Widget child;

  /// Defaults to `context.notion.colors.danger`.
  final Color? color;
  final bool enabled;

  /// Final scale of the ring relative to the child.
  final double spread;
  final BorderRadius borderRadius;

  static const Duration period = Duration(milliseconds: 1600);

  @override
  State<NotionPulse> createState() => _NotionPulseState();
}

class _NotionPulseState extends State<NotionPulse>
    with SingleTickerProviderStateMixin, _NotionLoop {
  late final Animation<double> _scale = loop.drive(
    Tween<double>(
      begin: 1,
      end: widget.spread,
    ).chain(CurveTween(curve: NotionMotion.standard)),
  );
  late final Animation<double> _opacity = loop.drive(
    Tween<double>(begin: .45, end: 0).chain(CurveTween(curve: Curves.easeOut)),
  );

  @override
  Duration get period => NotionPulse.period;

  @override
  bool get loopEnabled => widget.enabled;

  @override
  Duration? get loopCap => widget.maxDuration;

  @override
  void didUpdateWidget(NotionPulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) restartLoop();
  }

  @override
  Widget build(BuildContext context) {
    final ring = loop.isAnimating;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: ring
              ? IgnorePointer(
                  child: RepaintBoundary(
                    child: FadeTransition(
                      opacity: _opacity,
                      child: ScaleTransition(
                        scale: _scale,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: widget.color ?? context.notion.colors.danger,
                            borderRadius: widget.borderRadius,
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        widget.child,
      ],
    );
  }
}

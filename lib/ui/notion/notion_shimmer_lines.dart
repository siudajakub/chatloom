// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion_motion.dart';
import 'notion_skeleton.dart';
import 'notion_tokens.dart';

/// Placeholder lines of text that is on its way (a transcript being made):
/// rounded bars in the surrounding text colour with a soft highlight sweeping
/// from the start edge to the end edge. Lighter than [NotionSkeleton] (one
/// `CustomPaint`, no layout of its own child), and it takes its colour from
/// [color], so it reads on incoming and accent-coloured outgoing bubbles
/// alike.
///
/// Each line is as tall as one line of [style], so the text that replaces
/// the placeholder grows the slot as little as possible. Static bars under
/// reduced motion and after [maxDuration]; the loop stops under `TickerMode`
/// off.
///
/// ```dart
/// NotionShimmerLines(color: bubbleText, lines: 2)
/// ```
class NotionShimmerLines extends StatefulWidget {
  const NotionShimmerLines({
    super.key,
    this.color,
    this.lines = 2,
    this.style = NotionType.callout,
    this.width = defaultWidth,
    this.maxDuration = NotionMotion.loopCap,
    this.onRest,
  }) : assert(lines > 0);

  /// The sweep rests on static bars after this long (null: never).
  final Duration? maxDuration;

  /// Called once when the sweep rested after [maxDuration], so the owner
  /// can explain a wait that takes unusually long.
  final VoidCallback? onRest;

  /// Defaults to `context.notion.colors.text`.
  final Color? color;
  final int lines;

  /// The text style the placeholder stands in for (line height).
  final TextStyle style;

  /// Preferred width; the parent's constraints may make it narrower.
  final double width;

  /// Preferred width of the placeholder (the last line is shorter).
  static const double defaultWidth = 220;

  /// Sweep period: the skeleton's, slow and quiet.
  static const Duration period = NotionSkeleton.shimmerPeriod;

  /// Height of [lines] lines of [style] at [scaler].
  static double heightFor(TextScaler scaler, TextStyle style, int lines) =>
      lines * scaler.scale(style.fontSize ?? 15) * (style.height ?? 1.4);

  @override
  State<NotionShimmerLines> createState() => _NotionShimmerLinesState();
}

class _NotionShimmerLinesState extends State<NotionShimmerLines>
    with SingleTickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: NotionShimmerLines.period,
  );

  bool _rested = false;

  void _sync() {
    if (!NotionMotion.reduced(context) && !_rested) {
      if (!_loop.isAnimating) {
        final cap = widget.maxDuration;
        _loop
            .repeat(
              count: cap == null
                  ? null
                  : NotionMotion.loopCount(NotionShimmerLines.period, cap: cap),
            )
            // Completes only at the cap; a stopped loop never completes.
            .then((_) {
              if (!mounted) return;
              setState(() {
                _rested = true;
                _loop.value = 0;
              });
              widget.onRest?.call();
            });
      }
    } else if (_loop.isAnimating || _loop.value != 0) {
      _loop
        ..stop()
        ..value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final height = NotionShimmerLines.heightFor(
      MediaQuery.textScalerOf(context),
      widget.style,
      widget.lines,
    );
    return RepaintBoundary(
      child: CustomPaint(
        size: Size(widget.width, height),
        painter: _ShimmerLinesPainter(
          _loop,
          color: widget.color ?? context.notion.colors.text,
          lines: widget.lines,
          animated: _loop.isAnimating,
          rtl: Directionality.of(context) == TextDirection.rtl,
        ),
      ),
    );
  }
}

class _ShimmerLinesPainter extends CustomPainter {
  _ShimmerLinesPainter(
    this.animation, {
    required this.color,
    required this.lines,
    required this.animated,
    required this.rtl,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final Color color;
  final int lines;
  final bool animated;
  final bool rtl;

  /// Relative length of each line; the last one ends early like a sentence.
  static double _length(int index, int count) =>
      index == count - 1 && count > 1 ? .62 : (index.isEven ? 1 : .88);

  @override
  void paint(Canvas canvas, Size size) {
    final lineHeight = size.height / lines;
    final bar = lineHeight * .5;
    final base = color.withValues(alpha: color.a * .18);
    final paint = Paint()..color = base;
    if (animated) {
      // A band about a third of the width travels across and off both edges.
      final t = rtl ? 1 - animation.value : animation.value;
      final centre = -.35 + t * 1.7;
      paint.shader = LinearGradient(
        colors: [
          base,
          color.withValues(alpha: color.a * .42),
          base,
        ],
        stops: [
          (centre - .18).clamp(0.0, 1.0),
          centre.clamp(0.0, 1.0),
          (centre + .18).clamp(0.0, 1.0),
        ],
      ).createShader(Offset.zero & size);
    }
    for (var i = 0; i < lines; i++) {
      final width = size.width * _length(i, lines);
      final top = i * lineHeight + (lineHeight - bar) / 2;
      final left = rtl ? size.width - width : 0.0;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, top, width, bar),
          Radius.circular(bar / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_ShimmerLinesPainter old) =>
      old.color != color ||
      old.lines != lines ||
      old.animated != animated ||
      old.rtl != rtl;
}

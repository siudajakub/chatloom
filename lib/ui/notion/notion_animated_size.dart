// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion_motion.dart';

/// `AnimatedSize` that honours reduced motion without Flutter's zero-length
/// pitfall: a zero `duration` completes its controller synchronously inside
/// `performLayout` on the next relayout (for example when a glass dialog
/// settles and its surface changes) and trips "RenderAnimatedSize was
/// mutated in its own performLayout". Under reduced motion the size snaps
/// in one frame instead; otherwise it eases over [duration].
class NotionAnimatedSize extends StatelessWidget {
  const NotionAnimatedSize({
    super.key,
    required this.child,
    this.duration = NotionMotion.medium,
    this.curve = NotionMotion.standard,
    this.alignment = Alignment.center,
  });

  final Widget child;
  final Duration duration;
  final Curve curve;
  final AlignmentGeometry alignment;

  /// One frame: the shortest change that still runs on a ticker.
  static const Duration reducedDuration = Duration(microseconds: 1);

  @override
  Widget build(BuildContext context) => AnimatedSize(
    duration: NotionMotion.reduced(context) ? reducedDuration : duration,
    curve: curve,
    alignment: alignment,
    child: child,
  );
}

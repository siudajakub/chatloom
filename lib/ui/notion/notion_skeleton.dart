// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The only file that imports skeletonizer (it exports a `ShimmerEffect` that
// clashes with flutter_animate's; keep the two packages in separate files).
import 'package:material_ui/material_ui.dart';
import 'package:skeletonizer/skeletonizer.dart';

import 'notion_motion.dart';
import 'notion_tokens.dart';

/// Loading state that matches the final layout: paints [child] (usually the
/// real row widgets built from placeholder data, or [NotionSkeletonRow]s) as
/// grey bones with a slow shimmer, then cross-fades to the real content when
/// [enabled] turns false.
///
/// * Shimmer is a repeating ticker: it stops under `TickerMode` off and is
///   replaced by a static fill under reduced motion. Never leave a skeleton
///   enabled in a settled golden (`pumpAndSettle` would time out).
/// * Pointer input is ignored while enabled.
///
/// ```dart
/// NotionSkeleton(
///   enabled: loading,
///   child: Column(children: [for (var i = 0; i < 8; i++) const NotionSkeletonRow()]),
/// )
/// ```
class NotionSkeleton extends StatelessWidget {
  const NotionSkeleton({super.key, required this.child, this.enabled = true})
    : _sliver = false;

  /// Skeleton for a sliver child (no cross-fade).
  const NotionSkeleton.sliver({
    super.key,
    required this.child,
    this.enabled = true,
  }) : _sliver = true;

  final Widget child;
  final bool enabled;
  final bool _sliver;

  /// Shimmer period: slow and quiet.
  static const Duration shimmerPeriod = Duration(milliseconds: 1500);

  /// Marks a subtree that stays real inside a skeleton (a header, a button).
  static Widget keep(Widget child) => Skeleton.keep(child: child);

  /// Marks a subtree that is not drawn at all inside a skeleton.
  static Widget ignore(Widget child) => Skeleton.ignore(child: child);

  /// Draws a compound subtree (an avatar with a badge) as one bone.
  static Widget unite(Widget child) => Skeleton.unite(child: child);

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    final effect = NotionMotion.reduced(context)
        ? SolidColorEffect(color: colors.surface)
        : ShimmerEffect(
            baseColor: colors.surface,
            highlightColor: colors.selected,
            duration: shimmerPeriod,
          );
    const radius = TextBoneBorderRadius(NotionRadius.smAll);
    if (_sliver) {
      return Skeletonizer.sliver(
        enabled: enabled,
        effect: effect,
        textBoneBorderRadius: radius,
        child: child,
      );
    }
    return Skeletonizer(
      enabled: enabled,
      effect: effect,
      textBoneBorderRadius: radius,
      enableSwitchAnimation: true,
      switchAnimationConfig: const SwitchAnimationConfig(
        duration: NotionMotion.short,
        reverseDuration: NotionMotion.quick,
        switchInCurve: NotionMotion.standard,
        switchOutCurve: NotionMotion.exitFast,
        layoutBuilder: _topStartLayout,
      ),
      child: child,
    );
  }

  static Widget _topStartLayout(Widget? current, List<Widget> previous) =>
      Stack(
        alignment: AlignmentDirectional.topStart,
        children: [...previous, ?current],
      );
}

/// Generic placeholder row for a [NotionSkeleton]: avatar, title line and
/// [lines] - 1 shorter lines, sized like a `NotionListRow`/inbox row.
class NotionSkeletonRow extends StatelessWidget {
  const NotionSkeletonRow({
    super.key,
    this.avatar = true,
    this.avatarSize = NotionSize.avatar,
    this.lines = 2,
  });

  final bool avatar;
  final double avatarSize;
  final int lines;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: NotionSize.rowMinHeight),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: NotionSpace.xs),
      child: Row(
        children: [
          if (avatar) ...[
            Bone.circle(size: avatarSize),
            const SizedBox(width: NotionSpace.sm),
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Bone.text(words: 3, style: NotionType.body),
                for (var i = 1; i < lines; i++) ...[
                  const SizedBox(height: NotionSpace.xxs),
                  const Bone.text(words: 6, style: NotionType.footnote),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

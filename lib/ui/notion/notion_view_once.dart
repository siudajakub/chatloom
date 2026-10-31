// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion_motion.dart';
import 'notion_pressable.dart';
import 'notion_tokens.dart';

/// "Tap to view" card of view-once media (an Instagram view-once photo or
/// video): an opaque card with an eye in a circle, the kind and limit
/// ("Photo · View once") and the [hint]. It shows nothing of the media: no
/// thumbnail, no blur. Inside a media bubble pass the bubble's
/// [borderRadius] so the hairline follows its corners. Data and callbacks
/// only; it sits in scrolling content, so it is opaque, never glass.
class NotionViewOnceCard extends StatelessWidget {
  const NotionViewOnceCard({
    super.key,
    required this.title,
    required this.semanticLabel,
    this.hint = 'Tap to view',
    this.icon = Icons.visibility_outlined,
    this.onTap,
    this.borderRadius = NotionRadius.mdAll,
  });

  /// Kind and limit, e.g. "Photo · View once".
  final String title;

  /// What a screen reader says, e.g. "View-once photo".
  final String semanticLabel;
  final String hint;
  final IconData icon;
  final VoidCallback? onTap;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    final typography = context.notion.typography;
    return Semantics(
      container: true,
      button: onTap != null,
      label: '$semanticLabel. $hint',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: colors.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: borderRadius,
          side: BorderSide(color: colors.border, width: NotionSize.border),
        ),
        child: InkWell(
          onTap: onTap,
          // The ink presses, the content scales inside it (as in the dock).
          child: NotionPressable(
            enabled: onTap != null,
            scale: NotionMotion.pressButton,
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                NotionSpace.sm,
                NotionSpace.sm,
                NotionSpace.md,
                NotionSpace.sm,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.selected,
                      shape: BoxShape.circle,
                    ),
                    child: SizedBox.square(
                      dimension: NotionSize.avatar,
                      child: Icon(
                        icon,
                        size: NotionSize.iconMd,
                        color: colors.text,
                      ),
                    ),
                  ),
                  const SizedBox(width: NotionSpace.sm),
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: typography.callout.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          hint,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: typography.captionMuted,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A small reminder pill over media, e.g. on opened view-once media:
/// "Not marked as opened on Instagram". The icon sits on the media scrim
/// (like a video's duration pill); [label] is its tooltip (tap or hover)
/// and what a screen reader says.
class NotionViewOnceBadge extends StatelessWidget {
  const NotionViewOnceBadge({
    super.key,
    required this.label,
    this.icon = Icons.visibility_off_outlined,
  });

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: label,
    excludeSemantics: true,
    child: Tooltip(
      message: label,
      triggerMode: TooltipTriggerMode.tap,
      excludeFromSemantics: true,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: NotionMediaColors.scrim,
          borderRadius: NotionRadius.pillAll,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: NotionSpace.xs,
            vertical: NotionSpace.xxs,
          ),
          child: Icon(
            icon,
            size: NotionSize.iconSm,
            color: NotionMediaColors.onScrim,
          ),
        ),
      ),
    ),
  );
}

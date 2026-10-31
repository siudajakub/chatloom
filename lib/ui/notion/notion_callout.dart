// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion.dart';

enum NotionCalloutTone { neutral, warning, danger }

/// Inline notice for a state the user can fix: icon, title, short message,
/// one action, optional secondary action and dismiss. A flat `surface`
/// block like Notion's callout; [tone] colours only the icon (status colours
/// are never decoration).
///
/// [compact] is one row for a state that fixes itself and only needs a
/// nudge (a lasting connection problem): a small icon, the title over at
/// most one muted line, the action as a quiet button and the dismiss; no
/// secondary action. About half the full height.
class NotionCallout extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final NotionCalloutTone tone;

  /// Primary one-tap fix.
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool actionBusy;

  /// Quiet second action, e.g. "2 more" opening details.
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  /// Hides the callout; the caller decides for how long.
  final VoidCallback? onDismiss;
  final String dismissLabel;

  /// One row instead of the full block (see the class comment).
  final bool compact;

  const NotionCallout({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.tone = NotionCalloutTone.neutral,
    this.actionLabel,
    this.onAction,
    this.actionBusy = false,
    this.secondaryLabel,
    this.onSecondary,
    this.onDismiss,
    this.dismissLabel = 'Dismiss',
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final colors = tokens.colors;
    final iconColor = switch (tone) {
      NotionCalloutTone.neutral => colors.textSecondary,
      NotionCalloutTone.warning => colors.warning,
      NotionCalloutTone.danger => colors.danger,
    };
    if (compact) return _compact(context, iconColor);
    final hasAction = actionLabel != null;
    final hasSecondary = secondaryLabel != null && onSecondary != null;
    final dismissible = onDismiss != null;
    return Semantics(
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: NotionRadius.mdAll,
        ),
        child: Padding(
          // With a dismiss button the 48 pt target sits in the top-right
          // corner; the text keeps the same 12 pt inset either way.
          padding: dismissible
              ? const EdgeInsets.fromLTRB(
                  NotionSpace.sm,
                  NotionSpace.xxs,
                  NotionSpace.xxs,
                  NotionSpace.sm,
                )
              : const EdgeInsets.all(NotionSpace.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(
                  top: (dismissible ? NotionSpace.xs : 0) + NotionSpace.xxs / 2,
                ),
                child: Icon(icon, size: NotionSize.icon, color: iconColor),
              ),
              const SizedBox(width: NotionSpace.sm),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    top: dismissible ? NotionSpace.xs : 0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: tokens.typography.callout.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (message != null)
                        Padding(
                          padding: const EdgeInsets.only(
                            top: NotionSpace.xxs / 2,
                          ),
                          child: Text(
                            message!,
                            style: tokens.typography.footnoteMuted,
                          ),
                        ),
                      if (hasAction || hasSecondary)
                        Padding(
                          padding: const EdgeInsets.only(top: NotionSpace.xs),
                          child: Wrap(
                            spacing: NotionSpace.xs,
                            runSpacing: NotionSpace.xs,
                            children: [
                              if (hasAction)
                                NotionButton(
                                  label: actionLabel!,
                                  onPressed: onAction,
                                  busy: actionBusy,
                                ),
                              if (hasSecondary)
                                NotionButton.ghost(
                                  label: secondaryLabel!,
                                  onPressed: onSecondary,
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (dismissible)
                NotionIconButton(
                  icon: Icons.close,
                  label: dismissLabel,
                  onPressed: onDismiss,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _compact(BuildContext context, Color iconColor) {
    final typography = context.notion.typography;
    final dismissible = onDismiss != null;
    return Semantics(
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.notion.colors.surface,
          borderRadius: NotionRadius.mdAll,
        ),
        child: Padding(
          // The buttons bring their own 48 pt targets; the text keeps the
          // full callout's 12 pt inset.
          padding: EdgeInsetsDirectional.fromSTEB(
            NotionSpace.sm,
            NotionSpace.xxs,
            dismissible ? NotionSpace.xxs : NotionSpace.xs,
            NotionSpace.xxs,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: NotionSize.touchTarget,
            ),
            child: Row(
              children: [
                Icon(icon, size: NotionSize.iconSm, color: iconColor),
                const SizedBox(width: NotionSpace.xs),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typography.footnote.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (message != null)
                        Text(
                          message!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: typography.captionMuted,
                        ),
                    ],
                  ),
                ),
                if (actionLabel != null)
                  NotionButton.ghost(
                    label: actionLabel!,
                    onPressed: onAction,
                    busy: actionBusy,
                  ),
                if (dismissible)
                  NotionIconButton(
                    icon: Icons.close,
                    label: dismissLabel,
                    onPressed: onDismiss,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

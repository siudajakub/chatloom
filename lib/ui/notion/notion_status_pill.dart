// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion_motion.dart';
import 'notion_switchers.dart';
import 'notion_tokens.dart';

/// What a [NotionStatusPill] reports. Only the dot takes the status colour;
/// the text stays neutral (status colours are never decoration).
enum NotionStatusTone { neutral, success, warning, danger }

/// A compact read-only status: a coloured dot and a short label in a pill
/// ("Connected", "Needs attention", "Disconnected"), like the account
/// status in Telegram's and Messenger's linked-account lists. Opaque, so it
/// can sit in scrolling rows; a change of label or tone fades through in
/// place.
class NotionStatusPill extends StatelessWidget {
  const NotionStatusPill({
    super.key,
    required this.label,
    this.tone = NotionStatusTone.neutral,
  });

  final String label;
  final NotionStatusTone tone;

  /// Diameter of the status dot.
  static const double dot = 8;

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    final dotColor = switch (tone) {
      NotionStatusTone.neutral => colors.textTertiary,
      NotionStatusTone.success => colors.success,
      NotionStatusTone.warning => colors.warning,
      NotionStatusTone.danger => colors.danger,
    };
    return Semantics(
      container: true,
      label: label,
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: NotionRadius.pillAll,
          border: Border.all(color: colors.border, width: .5),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            NotionSpace.xs,
            NotionSpace.xxs,
            NotionSpace.sm,
            NotionSpace.xxs,
          ),
          child: NotionFadeThrough(
            duration: NotionMotion.short,
            alignment: AlignmentDirectional.centerStart,
            child: Row(
              key: ValueKey((label, tone)),
              mainAxisSize: MainAxisSize.min,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                  ),
                  child: const SizedBox.square(dimension: dot),
                ),
                const SizedBox(width: NotionSpace.xs - 2),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.notion.typography.caption,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion_motion.dart';
import 'notion_pressable.dart';
import 'notion_tokens.dart';

export 'details_contract.dart';
export 'initial_avatar.dart';
export 'notion_activity.dart';
export 'notion_appearance.dart';
export 'notion_callout.dart';
export 'notion_contrast.dart';
export 'notion_delivery_tick.dart';
export 'notion_entrance.dart';
export 'notion_glass.dart';
export 'notion_lazy_switcher.dart';
export 'notion_hover_toolbar.dart';
export 'notion_link_preview.dart';
export 'notion_loops.dart';
export 'notion_media_viewer.dart';
export 'notion_media_playback_controls.dart';
export 'notion_modal_routes.dart';
export 'notion_motion.dart';
export 'notion_pressable.dart';
export 'notion_primitives.dart';
export 'notion_reactions.dart';
export 'notion_shimmer_lines.dart';
export 'notion_skeleton.dart';
export 'notion_status_line.dart';
export 'notion_status_pill.dart';
export 'notion_swipe_action.dart';
export 'notion_switchers.dart';
export 'notion_tokens.dart';

/// Uses the active theme so the existing light/system preference remains usable.
class NotionIconButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  const NotionIconButton({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
    this.selected = false,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NotionPressable(
      enabled: onPressed != null,
      scale: NotionMotion.pressIcon,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: selected ? 1 : 0),
        duration: NotionMotion.of(context, NotionMotion.quick),
        curve: NotionMotion.standard,
        builder: (context, t, _) => IconButton(
          tooltip: label,
          onPressed: onPressed,
          icon: Icon(icon, size: NotionSize.iconMd),
          style: IconButton.styleFrom(
            minimumSize: const Size.square(NotionTokens.touchTarget),
            foregroundColor: scheme.onSurface,
            backgroundColor: t == 0
                ? Colors.transparent
                : scheme.surfaceContainerHighest.withValues(
                    alpha: scheme.surfaceContainerHighest.a * t,
                  ),
            // A circle, like the dock's icons.
            shape: NotionShapes.pill,
          ),
        ),
      ),
    );
  }
}

class NotionPropertyRow extends StatelessWidget {
  final String label;
  final Widget value;
  final VoidCallback? onTap;
  const NotionPropertyRow({
    super.key,
    required this.label,
    required this.value,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) => NotionPressable(
    enabled: onTap != null,
    scale: NotionMotion.pressRow,
    child: _propertyRow(context),
  );

  Widget _propertyRow(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: NotionRadius.rowAll,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final caption = Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 15,
            ),
          );
          final large = MediaQuery.textScalerOf(context).scale(15) > 22;
          if (large && constraints.maxWidth < 480) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                caption,
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: value),
                    if (onTap != null)
                      const Icon(Icons.edit_outlined, size: 20),
                  ],
                ),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 100, child: caption),
              Expanded(child: value),
              if (onTap != null) const Icon(Icons.edit_outlined, size: 20),
            ],
          );
        },
      ),
    ),
  );
}

class NotionListRow extends StatelessWidget {
  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  const NotionListRow({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    child: NotionPressable(
      enabled: onTap != null,
      scale: NotionMotion.pressRow,
      child: _row(context),
    ),
  );

  Widget _row(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: NotionRadius.rowAll,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final detail =
                trailing ??
                (onTap == null
                    ? null
                    : const Icon(Icons.chevron_right, size: 22));
            final large =
                MediaQuery.textScalerOf(context).scale(16) > 22 &&
                constraints.maxWidth < 480;
            final text = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: NotionTokens.body),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                if (large && detail != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: detail,
                  ),
              ],
            );
            return Row(
              crossAxisAlignment: large
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.center,
              children: [
                if (leading != null) ...[
                  SizedBox(width: 24, child: leading),
                  const SizedBox(width: 14),
                ],
                Expanded(child: text),
                if (!large && detail != null) ...[
                  const SizedBox(width: 10),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth * .44,
                    ),
                    child: detail,
                  ),
                ],
              ],
            );
          },
        ),
      ),
    ),
  );
}

class NotionCompactChatHeader extends StatelessWidget {
  final Widget avatar;
  final String name;
  final VoidCallback? onDetails;

  /// Optional line under the name (connection status, `NotionStatusLine`).
  final Widget? status;
  const NotionCompactChatHeader({
    super.key,
    required this.avatar,
    required this.name,
    required this.onDetails,
    this.status,
  });
  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    label: 'Chat details for $name',
    excludeSemantics: true,
    enabled: onDetails != null,
    onTap: onDetails,
    child: InkWell(
      onTap: onDetails,
      borderRadius: NotionRadius.pillAll,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          children: [
            Container(
              width: 1,
              height: 20,
              color: Theme.of(context).dividerColor,
            ),
            const SizedBox(width: 12),
            avatar,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  ?status,
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

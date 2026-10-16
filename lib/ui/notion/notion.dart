// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

export 'details_contract.dart';
export 'initial_avatar.dart';

/// Shared presentation values for the approved Notion dark v2 interface.
abstract final class NotionTokens {
  static const background = Color(0xFF191919);
  static const surface = Color(0xFF252525);
  static const selected = Color(0xFF2F2F2F);
  static const border = Color(0xFF383838);
  static const text = Color(0xFFE8E7E5);
  static const secondary = Color(0xFFAAAAA5);
  static const cover = Color(0xFF33312B);
  static const double inset = 20;
  static const double avatarRadius = 5;
  static const double radius = 7;
  static const double headerHeight = 56;
  static const double touchTarget = 48;
  static const title = TextStyle(
    fontSize: 30,
    fontWeight: FontWeight.w700,
    height: 1.15,
  );
  static const heading = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );
  static const body = TextStyle(fontSize: 16, height: 1.4);
  static const caption = TextStyle(fontSize: 12, height: 1.4);
}

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
  Widget build(BuildContext context) => IconButton(
    tooltip: label,
    onPressed: onPressed,
    icon: Icon(icon, size: 22),
    style: IconButton.styleFrom(
      minimumSize: const Size.square(NotionTokens.touchTarget),
      foregroundColor: Theme.of(context).colorScheme.onSurface,
      backgroundColor: selected
          ? Theme.of(context).colorScheme.surfaceContainerHighest
          : Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
    ),
  );
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
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
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
    child: InkWell(
      onTap: onTap,
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
    ),
  );
}

class NotionCompactChatHeader extends StatelessWidget {
  final Widget avatar;
  final String name;
  final VoidCallback? onDetails;
  const NotionCompactChatHeader({
    super.key,
    required this.avatar,
    required this.name,
    required this.onDetails,
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
      borderRadius: BorderRadius.circular(5),
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
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

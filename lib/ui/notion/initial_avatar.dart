// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion_tokens.dart';

/// Production fallback for absent/unavailable permitted photo avatars.
class NotionInitialAvatar extends StatelessWidget {
  final String? name;
  final double size;
  final Color? backgroundColor;
  final Color? textColor;
  final IconData? icon;
  const NotionInitialAvatar({
    super.key,
    this.name,
    this.size = 40,
    this.backgroundColor,
    this.textColor,
    this.icon,
  });
  static String initials(String? name) {
    final words = (name ?? '')
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    return words.length == 1
        ? words.first.characters.first
        : '${words.first.characters.first}${words.last.characters.first}';
  }

  @override
  Widget build(BuildContext context) {
    // Letter avatars follow the colour intensity: grey (Muted), a tint of a
    // per-name hue (Balanced) or the saturated hue (Vivid, Messenger).
    final palette = context.notion.palette.avatar(name);
    final foreground = textColor ?? palette.foreground;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: backgroundColor ?? palette.background,
        borderRadius: NotionRadius.avatarAll,
      ),
      child: icon == null
          ? Text(
              initials(name),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: foreground,
                fontWeight: FontWeight.w600,
                fontSize: size / 2.5,
              ),
            )
          : Icon(icon, color: foreground, size: size / 2),
    );
  }
}

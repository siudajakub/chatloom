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
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color:
          backgroundColor ??
          Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: NotionRadius.avatarAll,
    ),
    child: icon == null
        ? Text(
            initials(name),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: textColor ?? Theme.of(context).colorScheme.onSurface,
              fontWeight: FontWeight.w600,
              fontSize: size / 2.5,
            ),
          )
        : Icon(icon, color: textColor, size: size / 2),
  );
}

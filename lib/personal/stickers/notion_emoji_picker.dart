// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:material_ui/material_ui.dart';

/// The recently used emoji of every picker (composer panel, reactions,
/// settings). The picker keeps them itself, in the app's preferences under
/// `recent`; this reads that list so a picker opens on it (Telegram) and
/// only falls back to the smileys while it is empty.
abstract final class NotionEmojiRecents {
  static const _key = 'recent';

  /// Whether at least one emoji was used.
  static bool get any {
    try {
      final raw = AppSettings.store.getString(_key);
      if (raw == null) return false;
      final list = jsonDecode(raw);
      return list is List && list.isNotEmpty;
    } catch (_) {
      // Preferences not ready (tests, early start) or unreadable.
      return false;
    }
  }

  /// Where a picker opens: the recents, or the smileys while there are
  /// none (never an empty page).
  static Category get initialCategory =>
      any ? Category.RECENT : Category.SMILEYS;
}

/// The emoji picker's configuration in Notion roles (instead of the
/// legacy `colorScheme.onInverseSurface/primary` styling): transparent
/// grid, muted category icons with the accent on the selected one, no
/// search bar (the panel has its own controls). It opens on the recently
/// used emoji ([NotionEmojiRecents.initialCategory]) unless [initCategory]
/// says otherwise.
Config notionEmojiPickerConfig(BuildContext context, {Category? initCategory}) {
  final notion = context.notion;
  final colors = notion.colors;
  return Config(
    height: null,
    locale: Localizations.localeOf(context),
    emojiViewConfig: EmojiViewConfig(
      backgroundColor: Colors.transparent,
      columns: 8,
      emojiSizeMax: 30,
      noRecents: const NotionEmojiNoRecents(),
      loadingIndicator: const SizedBox.shrink(),
    ),
    bottomActionBarConfig: const BottomActionBarConfig(enabled: false),
    categoryViewConfig: CategoryViewConfig(
      initCategory: initCategory ?? NotionEmojiRecents.initialCategory,
      backgroundColor: Colors.transparent,
      iconColor: colors.textTertiary,
      iconColorSelected: colors.accent,
      indicatorColor: colors.accent,
      backspaceColor: colors.textSecondary,
      dividerColor: colors.border,
    ),
    skinToneConfig: SkinToneConfig(
      dialogBackgroundColor: colors.selected,
      indicatorColor: colors.textSecondary,
    ),
  );
}

/// "No recent emoji" in the emoji grid.
class NotionEmojiNoRecents extends StatelessWidget {
  const NotionEmojiNoRecents({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(NotionSpace.md),
      child: Text(
        'Emoji you use show up here.',
        textAlign: TextAlign.center,
        style: context.notion.typography.calloutMuted,
      ),
    ),
  );
}

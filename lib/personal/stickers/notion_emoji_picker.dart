// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:material_ui/material_ui.dart';

/// The emoji picker's configuration in Notion roles (instead of the
/// legacy `colorScheme.onInverseSurface/primary` styling): transparent
/// grid, muted category icons with the accent on the selected one, no
/// search bar (the panel has its own controls).
Config notionEmojiPickerConfig(
  BuildContext context, {
  Category initCategory = Category.RECENT,
}) {
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
      initCategory: initCategory,
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

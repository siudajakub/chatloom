// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/conversation_message_actions.dart';
import 'package:chatloom/pages/chat_list/chat_actions_menu.dart';
import 'package:chatloom/personal/stickers/notion_emoji_picker.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/settings_switch_list_tile.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'settings_chat.dart';

class SettingsChatView extends StatelessWidget {
  final SettingsChatController controller;
  const SettingsChatView(this.controller, {super.key});

  Future<void> _saveSetting(
    BuildContext context,
    Future<void> Function() save,
  ) async {
    try {
      await save();
      if (context.mounted) controller.updateState();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save this setting. Try again.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return NotionSettingsScaffold(
      title: 'Chats',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Everyday gestures first (Telegram "Chat Settings", Signal "Chats").
          SettingsSwitchListTile.adaptive(
            title: 'Send with Enter',
            subtitle: 'Shift+Enter adds a new line',
            setting: AppSettings.sendOnEnter,
          ),
          SettingsSwitchListTile.adaptive(
            title: 'Swipe to reply',
            setting: AppSettings.swipeRightToLeftToReply,
          ),
          SettingsSwitchListTile.adaptive(
            title: 'Swipe chats in the list',
            subtitle: 'Choose what each direction does below',
            setting: AppSettings.inboxSwipeActions,
            onChanged: (_) => controller.updateState(),
          ),
          if (AppSettings.inboxSwipeActions.value) ...[
            for (final (setting, label, fallback) in [
              (
                AppSettings.inboxSwipeLeft,
                'Swipe left',
                InboxSwipeChoice.archive,
              ),
              (
                AppSettings.inboxSwipeRight,
                'Swipe right',
                InboxSwipeChoice.read,
              ),
            ])
              NotionPickerRow<InboxSwipeChoice>(
                key: Key('settings_${setting.name}'),
                label: label,
                value: InboxSwipeChoice.parse(setting.value, fallback),
                options: [
                  for (final choice in InboxSwipeChoice.values)
                    NotionChoice(choice, choice.label),
                ],
                onChanged: (value) =>
                    _saveSetting(context, () => setting.setItem(value.name)),
              ),
          ],
          NotionPickerRow<String>(
            key: const Key('settings_emoji_suggestion_language'),
            label: 'Emoji suggestion language',
            subtitle: 'Language of emoji names while you type',
            value: AppSettings.emojiSuggestionLocale.value,
            placeholder: AppSettings.emojiSuggestionLocale.value,
            options: const [
              // Supported by emoji_picker_flutter 4.5.4's
              // getDefaultEmojiLocale. Other codes fall back to English.
              NotionChoice('', 'Follow app language'),
              NotionChoice('de', 'Deutsch'),
              NotionChoice('en', 'English'),
              NotionChoice('es', 'Español'),
              NotionChoice('fr', 'Français'),
              NotionChoice('hi', 'हिन्दी'),
              NotionChoice('it', 'Italiano'),
              NotionChoice('ja', '日本語'),
              NotionChoice('nl', 'Nederlands'),
              NotionChoice('pt', 'Português'),
              NotionChoice('ru', 'Русский'),
              NotionChoice('zh', '中文'),
            ],
            onChanged: (value) => _saveSetting(
              context,
              () => AppSettings.emojiSuggestionLocale.setItem(value),
            ),
          ),
          if (PlatformInfos.isDesktop || PlatformInfos.isWeb)
            SettingsSwitchListTile.adaptive(
              title: 'Open chats with the details panel',
              subtitle: 'Applies when opening a chat in a wide window',
              setting: AppSettings.displayChatDetailsColumn,
            ),
          SettingsSwitchListTile.adaptive(
            title: L10n.of(context).doubleTapToReact,
            subtitle: L10n.of(context).doubleTapToReactDescription,
            setting: AppSettings.doubleTapToReact,
            onChanged: (_) => controller.updateState(),
          ),
          NotionListRow(
            key: const Key('settings_quick_reactions_row'),
            title: 'Quick reactions',
            subtitle: 'The reactions above a long-pressed message',
            trailing: Text(
              ConversationMessageActions.preferredReactions().join(' '),
              style: NotionType.body,
            ),
            onTap: () async {
              await showQuickReactionsEditor(context);
              controller.updateState();
            },
          ),
          if (AppSettings.doubleTapToReact.value)
            NotionListRow(
              key: const Key('settings_double_tap_reaction_row'),
              title: L10n.of(context).doubleTapReaction,
              // Empty: the network's first quick reaction (a heart
              // wherever the network has one).
              subtitle: AppSettings.doubleTapReaction.value.isEmpty
                  ? 'Automatic: each network’s first reaction'
                  : null,
              trailing: Text(
                AppSettings.doubleTapReaction.value.isEmpty
                    ? ConversationMessageActions.preferredReactions().first
                    : AppSettings.doubleTapReaction.value,
                style: NotionType.heading,
              ),
              onTap: () async {
                final emoji = await showDoubleTapReactionPicker(context);
                if (emoji != null) {
                  await AppSettings.doubleTapReaction.setItem(emoji);
                  controller.updateState();
                }
              },
            ),
          const NotionSettingsSection('Messages'),
          SettingsSwitchListTile.adaptive(
            title: 'Show photo and video previews',
            setting: AppSettings.showThumbnailsInTimeline,
          ),
          SettingsSwitchListTile.adaptive(
            title: 'Play GIFs and animated stickers',
            subtitle: 'Animations pause when reduced motion is on',
            setting: AppSettings.autoplayImages,
          ),
          SettingsSwitchListTile.adaptive(
            title: 'Link previews',
            subtitle: 'Show a card for the first link in a message',
            setting: AppSettings.showLinkPreviews,
          ),
          SettingsSwitchListTile.adaptive(
            title: 'Formatted messages',
            subtitle: 'Show bold, italics, lists and links',
            setting: AppSettings.renderHtml,
          ),
          NotionPickerRow<int>(
            key: const Key('settings_message_preview_lines'),
            label: 'Long message preview',
            subtitle: 'Collapse longer messages until you expand them',
            value: AppSettings.messagePreviewMaxLines.value,
            placeholder: '${AppSettings.messagePreviewMaxLines.value} lines',
            options: const [
              NotionChoice(0, 'Unlimited'),
              NotionChoice(10, '10 lines'),
              NotionChoice(25, '25 lines'),
              NotionChoice(50, '50 lines'),
              NotionChoice(100, '100 lines'),
            ],
            onChanged: (value) => _saveSetting(
              context,
              () => AppSettings.messagePreviewMaxLines.setItem(value),
            ),
          ),
          SettingsSwitchListTile.adaptive(
            title: 'Hide deleted messages',
            subtitle: 'Leave no placeholder where a message was deleted',
            setting: AppSettings.hideRedactedEvents,
          ),
          SettingsSwitchListTile.adaptive(
            title: 'Hide unknown message types',
            subtitle: 'Technical events the app can’t display',
            setting: AppSettings.hideUnknownEvents,
          ),
          const NotionSettingsSection('Media & people'),
          NotionListRow(
            key: const Key('settings_voice_video_row'),
            leading: const Icon(Icons.mic_none_outlined),
            title: 'Voice messages & round videos',
            subtitle: 'Recording quality, noise reduction, auto-download',
            onTap: () => context.push('/rooms/settings/chat/media'),
          ),
          NotionListRow(
            key: const Key('settings_stickers_row'),
            leading: const Icon(Icons.sticky_note_2_outlined),
            title: 'Stickers & GIFs',
            subtitle: 'Sticker packs, favourites, import from Telegram',
            onTap: () => context.push('/rooms/settings/chat/stickers'),
          ),
          NotionListRow(
            leading: const Icon(Icons.people_outline),
            title: 'Merged conversations',
            subtitle: 'One timeline for a person across networks',
            onTap: () => context.push('/rooms/settings/people'),
          ),
        ],
      ),
    );
  }
}

/// Edits the quick reaction bar (Telegram's "Reactions", Messenger's
/// "Customize reactions"): tap a slot to replace its emoji; the order is
/// the bar's order. Saves on every change.
Future<void> showQuickReactionsEditor(BuildContext context) =>
    showNotionSheet<void>(
      context: context,
      title: 'Quick reactions',
      builder: (context) => const _QuickReactionsEditor(),
    );

class _QuickReactionsEditor extends StatefulWidget {
  const _QuickReactionsEditor();

  @override
  State<_QuickReactionsEditor> createState() => _QuickReactionsEditorState();
}

class _QuickReactionsEditorState extends State<_QuickReactionsEditor> {
  late List<String> _emoji = [
    ...ConversationMessageActions.preferredReactions(),
  ];

  Future<void> _save(List<String> emoji) async {
    setState(() => _emoji = emoji);
    try {
      await ConversationMessageActions.saveQuickReactions(emoji);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save this setting. Try again.'),
          ),
        );
      }
    }
  }

  Future<void> _replace(int index) async {
    final picked = await showEmojiChoiceSheet(
      context,
      title: 'Reaction ${index + 1}',
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    final next = [..._emoji];
    // Picking one already in the bar swaps the two.
    final existing = next.indexOf(picked);
    if (existing >= 0) next[existing] = next[index];
    next[index] = picked;
    await _save(next);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final isDefault = listEquals(_emoji, NotionReactions.defaults);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Tap a reaction to change it. Networks with a fixed set of '
          'reactions keep only the ones they allow.',
          style: tokens.typography.footnoteMuted,
        ),
        const SizedBox(height: NotionSpace.sm),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: NotionSpace.xs,
          runSpacing: NotionSpace.xs,
          children: [
            for (var i = 0; i < _emoji.length; i++)
              Semantics(
                button: true,
                label: 'Reaction ${i + 1}: ${_emoji[i]}. Change',
                excludeSemantics: true,
                child: InkWell(
                  key: Key('quick_reaction_slot_$i'),
                  customBorder: const CircleBorder(),
                  onTap: () => _replace(i),
                  child: Container(
                    width: NotionSize.touchTarget,
                    height: NotionSize.touchTarget,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: tokens.colors.surface,
                      border: Border.all(color: tokens.colors.border),
                    ),
                    child: Text(_emoji[i], style: NotionType.heading),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: NotionSpace.md),
        NotionButton(
          key: const Key('quick_reactions_reset'),
          expand: true,
          label: 'Restore defaults',
          onPressed: isDefault
              ? null
              : () => _save([...NotionReactions.defaults]),
        ),
      ],
    );
  }
}

/// One emoji from the full picker as a Notion sheet; null when dismissed.
Future<String?> showEmojiChoiceSheet(
  BuildContext context, {
  required String title,
}) => showNotionSheet<String>(
  context: context,
  title: title,
  builder: (context) => SizedBox(
    height: math.min(420.0, MediaQuery.sizeOf(context).height * .5),
    child: EmojiPicker(
      onEmojiSelected: (_, emoji) => Navigator.of(context).pop(emoji.emoji),
      config: notionEmojiPickerConfig(context, initCategory: Category.SMILEYS),
    ),
  ),
);

/// The double-tap reaction picker as a Notion sheet (Telegram's "Quick
/// reaction"): the emoji grid, and "Automatic" to follow each network's
/// first quick reaction. Returns the emoji, '' for Automatic, or null when
/// dismissed.
Future<String?> showDoubleTapReactionPicker(BuildContext context) =>
    showNotionSheet<String>(
      context: context,
      title: L10n.of(context).doubleTapReaction,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: SizedBox(
              height: math.min(420.0, MediaQuery.sizeOf(context).height * .5),
              child: EmojiPicker(
                onEmojiSelected: (_, emoji) =>
                    Navigator.of(context).pop(emoji.emoji),
                config: notionEmojiPickerConfig(context),
              ),
            ),
          ),
          const SizedBox(height: NotionSpace.sm),
          NotionButton(
            key: const Key('double_tap_reaction_automatic'),
            expand: true,
            label: 'Automatic',
            onPressed: () => Navigator.of(context).pop(''),
          ),
        ],
      ),
    );

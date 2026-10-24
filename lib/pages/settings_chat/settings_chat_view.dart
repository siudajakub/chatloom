// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/stickers/notion_emoji_picker.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/settings_switch_list_tile.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'settings_chat.dart';

class SettingsChatView extends StatelessWidget {
  final SettingsChatController controller;
  const SettingsChatView(this.controller, {super.key});

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
            subtitle: 'Left to archive, right to mark as read or unread',
            setting: AppSettings.inboxSwipeActions,
          ),
          SettingsSwitchListTile.adaptive(
            title: L10n.of(context).doubleTapToReact,
            subtitle: L10n.of(context).doubleTapToReactDescription,
            setting: AppSettings.doubleTapToReact,
            onChanged: (_) => controller.updateState(),
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
                    ? NotionReactions.defaults.first
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
            title: 'Hide deleted messages',
            subtitle: 'Leave no placeholder where a message was deleted',
            setting: AppSettings.hideRedactedEvents,
          ),
          // Formatted messages and unknown message types are in
          // Settings › Advanced › Developer (CS-22).
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
                config: notionEmojiPickerConfig(
                  context,
                  initCategory: Category.SMILEYS,
                ),
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

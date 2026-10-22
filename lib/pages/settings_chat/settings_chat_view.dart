// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/adaptive_bottom_sheet.dart';
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
    final theme = Theme.of(context);

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
            title: L10n.of(context).doubleTapToReact,
            subtitle: L10n.of(context).doubleTapToReactDescription,
            setting: AppSettings.doubleTapToReact,
            onChanged: (_) => controller.updateState(),
          ),
          if (AppSettings.doubleTapToReact.value)
            ListTile(
              title: Text(L10n.of(context).doubleTapReaction),
              // Empty: the network's first quick reaction (a heart
              // wherever the network has one).
              subtitle: AppSettings.doubleTapReaction.value.isEmpty
                  ? const Text('Automatic: each network’s first reaction')
                  : null,
              trailing: Text(
                AppSettings.doubleTapReaction.value.isEmpty
                    ? NotionReactions.defaults.first
                    : AppSettings.doubleTapReaction.value,
                style: NotionType.heading,
              ),
              onTap: () async {
                final emoji = await showAdaptiveBottomSheet<String>(
                  context: context,
                  builder: (context) => Scaffold(
                    appBar: AppBar(
                      title: Text(L10n.of(context).doubleTapReaction),
                      leading: CloseButton(
                        onPressed: () => Navigator.of(context).pop(null),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(''),
                          child: const Text('Automatic'),
                        ),
                      ],
                    ),
                    body: SizedBox(
                      height: double.infinity,
                      child: EmojiPicker(
                        onEmojiSelected: (_, emoji) =>
                            Navigator.of(context).pop(emoji.emoji),
                        config: Config(
                          locale: Localizations.localeOf(context),
                          emojiViewConfig: const EmojiViewConfig(
                            backgroundColor: Colors.transparent,
                          ),
                          bottomActionBarConfig: const BottomActionBarConfig(
                            enabled: false,
                          ),
                          categoryViewConfig: CategoryViewConfig(
                            initCategory: Category.SMILEYS,
                            backspaceColor: theme.colorScheme.primary,
                            iconColor: theme.colorScheme.primary.withAlpha(128),
                            iconColorSelected: theme.colorScheme.primary,
                            indicatorColor: theme.colorScheme.primary,
                            backgroundColor: theme.colorScheme.surface,
                          ),
                          skinToneConfig: SkinToneConfig(
                            dialogBackgroundColor: Color.lerp(
                              theme.colorScheme.surface,
                              theme.colorScheme.primaryContainer,
                              0.75,
                            )!,
                            indicatorColor: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
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

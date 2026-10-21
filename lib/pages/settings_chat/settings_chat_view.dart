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
      title: 'Chats & media',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NotionListRow(
            key: const Key('settings_voice_video_row'),
            leading: const Icon(Icons.mic_none_outlined),
            title: 'Voice messages & round videos',
            subtitle: 'Recording quality, noise reduction, auto-download',
            onTap: () => context.push('/rooms/settings/chat/media'),
          ),
          NotionListRow(
            leading: const Icon(Icons.people_outline),
            title: 'People & merged conversations',
            subtitle: 'Keep one timeline across a person’s networks',
            onTap: () => context.push('/rooms/settings/people'),
          ),
          const NotionSettingsSection('Messages'),
          SettingsSwitchListTile.adaptive(
            title: L10n.of(context).formattedMessages,
            subtitle: L10n.of(context).formattedMessagesDescription,
            setting: AppSettings.renderHtml,
          ),
          SettingsSwitchListTile.adaptive(
            title: L10n.of(context).showThumbnailsInTimeline,
            setting: AppSettings.showThumbnailsInTimeline,
          ),
          SettingsSwitchListTile.adaptive(
            title: L10n.of(context).hideRedactedMessages,
            subtitle: L10n.of(context).hideRedactedMessagesBody,
            setting: AppSettings.hideRedactedEvents,
          ),
          SettingsSwitchListTile.adaptive(
            title: L10n.of(context).hideInvalidOrUnknownMessageFormats,
            setting: AppSettings.hideUnknownEvents,
          ),
          const NotionSettingsSection('Gestures & typing'),
          SettingsSwitchListTile.adaptive(
            title: L10n.of(context).sendOnEnter,
            setting: AppSettings.sendOnEnter,
          ),
          SettingsSwitchListTile.adaptive(
            title: L10n.of(context).swipeRightToLeftToReply,
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
        ],
      ),
    );
  }
}

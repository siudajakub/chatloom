// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/sticker_picker_dialog.dart';
import 'package:chatloom/pages/chat/trust_user_key_dialog.dart';
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/error_reporter.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'conversation_source.dart';

class ChatEmojiPicker extends StatelessWidget {
  final ConversationComposerHost controller;
  const ChatEmojiPicker(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Slides open like a sheet and keeps its content while it closes.
    return NotionSizeReveal(
      visible: controller.showEmojiPicker,
      duration: NotionMotion.long,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height / 2,
        child: DefaultTabController(
          length: 2,
          child: Column(
            children: [
              TabBar(
                tabs: [
                  Tab(text: L10n.of(context).emojis),
                  Tab(text: L10n.of(context).stickers),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    EmojiPicker(
                      onEmojiSelected: controller.onEmojiSelected,
                      onBackspacePressed: controller.emojiPickerBackspace,
                      config: Config(
                        locale: Localizations.localeOf(context),
                        emojiViewConfig: EmojiViewConfig(
                          noRecents: const NoRecent(),
                          backgroundColor: theme.colorScheme.onInverseSurface,
                        ),
                        bottomActionBarConfig: const BottomActionBarConfig(
                          enabled: false,
                        ),
                        categoryViewConfig: CategoryViewConfig(
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
                    StickerPickerDialog(
                      room: controller.room,
                      onSelected: (sticker) async {
                        final proceed = await showTrustUserInRoomDialog(
                          context,
                          controller.room,
                        );
                        if (!proceed) return;
                        // The picker is closed by the time the server
                        // answers: report on the app's navigator.
                        const reporter = ErrorReporter.action(
                          null,
                          action: ErrorAction.send,
                        );
                        controller.room
                            .sendEvent(
                              {
                                'body': sticker.body,
                                'info': sticker.info ?? {},
                                'url': sticker.url.toString(),
                              },
                              type: EventTypes.Sticker,
                              threadRootEventId: controller.activeThreadId,
                              threadLastEventId: controller.threadLastEventId,
                            )
                            .then<void>(
                              (_) {},
                              onError: reporter.onErrorCallback,
                            );
                        controller.hideEmojiPicker();
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class NoRecent extends StatelessWidget {
  const NoRecent({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Text(
          L10n.of(context).emoteKeyboardNoRecents,
          style: Theme.of(context).textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

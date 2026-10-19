// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:collection/collection.dart';
import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/pages/chat/conversation_source.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Who is typing in the conversation's rooms (all source rooms of a merged
/// person chat), under the newest message. The row grows in and out with a
/// size reveal, avatars pop, and the bubble runs [NotionTypingDots] (a
/// paint-only loop that stops offstage and under reduced motion).
class TypingIndicators extends StatefulWidget {
  final ConversationTimelineSource controller;
  const TypingIndicators(this.controller, {super.key});

  @override
  State<TypingIndicators> createState() => _TypingIndicatorsState();
}

class _TypingIndicatorsState extends State<TypingIndicators> {
  /// Last non-empty set, shown while the row collapses.
  List<User> _shown = const [];

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final theme = Theme.of(context);

    const avatarSize = Avatar.defaultSize / 2;

    final rooms = controller.typingRooms;
    final roomIds = {for (final room in rooms) room.id};
    return StreamBuilder<Object>(
      stream: controller.room.client.onSync.stream.where(
        (syncUpdate) => roomIds.any(
          (roomId) =>
              syncUpdate.rooms?.join?[roomId]?.ephemeral?.any(
                (ephemeral) => ephemeral.type == 'm.typing',
              ) ??
              false,
        ),
      ),
      builder: (context, _) {
        final ownId = Matrix.of(context).client.userID;
        final typingUsers = [
          for (final room in rooms)
            ...room.typingUsers.where((u) => u.stateKey != ownId),
        ];
        if (typingUsers.isNotEmpty) _shown = typingUsers;
        final users = _shown;
        final newest = controller.conversationEvents?.firstOrNull;

        return Container(
          width: double.infinity,
          alignment: Alignment.center,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: FluffyThemes.maxTimelineWidth,
            ),
            child: NotionSizeReveal(
              visible: typingUsers.isNotEmpty,
              alignment: newest != null && newest.senderId == ownId
                  ? Alignment.topRight
                  : Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: NotionSpace.xs,
                  vertical: NotionSpace.xxs,
                ),
                child: Row(
                  children: [
                    Container(
                      alignment: Alignment.center,
                      height: avatarSize,
                      width: Avatar.defaultSize,
                      child: Stack(
                        children: [
                          if (users.isNotEmpty)
                            NotionPop(
                              key: ValueKey(users.first.id),
                              child: Avatar(
                                size: avatarSize,
                                client: controller.room.client,
                                mxContent: users.first.avatarUrl,
                                name: users.first.calcDisplayname(),
                              ),
                            ),
                          if (users.length == 2)
                            Padding(
                              padding: const EdgeInsets.only(left: 16),
                              child: NotionPop(
                                key: ValueKey(users.last.id),
                                child: Avatar(
                                  size: avatarSize,
                                  client: controller.room.client,
                                  mxContent: users.last.avatarUrl,
                                  name: users.last.calcDisplayname(),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Material(
                      color: theme.colorScheme.surfaceContainerHigh,
                      borderRadius: const BorderRadius.all(
                        Radius.circular(AppConfig.borderRadius),
                      ),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: NotionSpace.sm,
                          vertical: NotionSpace.xxs,
                        ),
                        child: NotionTypingDots(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

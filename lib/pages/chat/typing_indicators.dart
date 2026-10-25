// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/themes.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/personal/ui/conversation_activity_widgets.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:collection/collection.dart';
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
  Client? _shownClient;
  String? _shownRooms;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    const avatarSize = NotionBubble.avatar;

    final rooms = controller.typingRooms;
    final roomSignature = (rooms.map((room) => room.id).toList()..sort()).join(
      '|',
    );
    if (!identical(_shownClient, controller.room.client) ||
        _shownRooms != roomSignature) {
      _shown = const [];
      _shownClient = controller.room.client;
      _shownRooms = roomSignature;
    }
    return ConversationActivityBuilder(
      client: controller.room.client,
      rooms: rooms,
      builder: (context, activity) {
        final ownId = controller.room.client.userID;
        final typingUsers = conversationTypingUsers(activity);
        if (typingUsers.isNotEmpty) _shown = typingUsers;
        final users = _shown;
        final newest = controller.conversationEvents?.firstOrNull;
        final incoming =
            switch (controller.conversationPalette.theme?.incomingColor) {
              final int color => Color(color),
              _ => ConversationBubbleColors.of(context).incoming,
            };

        return Semantics(
          liveRegion: true,
          label: conversationTypingText(
            context,
            activity,
            sourceLabels: rooms.length > 1,
          ),
          child: Container(
            width: double.infinity,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: NotionSpace.sm),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: ChatLoomThemes.maxTimelineWidth,
              ),
              child: NotionSizeReveal(
                visible: typingUsers.isNotEmpty,
                alignment: newest != null && newest.senderId == ownId
                    ? Alignment.topRight
                    : Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: NotionSpace.xxs,
                  ),
                  child: ConversationBubble(
                    outgoing: false,
                    backgroundColor: incoming,
                    avatar: Stack(
                      clipBehavior: Clip.none,
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
                        if (users.length > 1)
                          PositionedDirectional(
                            start: NotionBubble.avatarSlot - avatarSize,
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
                    body: Builder(
                      builder: (context) => SizedBox(
                        height:
                            MediaQuery.textScalerOf(
                                  context,
                                ).scale(NotionType.body.fontSize!) *
                                NotionType.body.height! +
                            NotionSpace.xxs,
                        child: Center(
                          widthFactor: 1,
                          child: NotionTypingDots(
                            color: NotionContrast.readable(
                              incoming,
                              context.notion.colors.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

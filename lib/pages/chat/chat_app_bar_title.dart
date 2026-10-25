// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/config/themes.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat.dart';
import 'package:chatloom/pages/chat_list/chat_list_item.dart';
import 'package:chatloom/personal/connection_status.dart';
import 'package:chatloom/personal/disappearing_label.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/person_location.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart'
    show notionNetworkLabel;
import 'package:chatloom/personal/ui/conversation_activity_widgets.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class ChatAppBarTitle extends StatelessWidget {
  final ChatController controller;
  const ChatAppBarTitle(this.controller, {super.key});
  @override
  Widget build(BuildContext context) {
    final room = controller.room;
    final personal = PersonalClient.of(room.client);
    final projection = InboxProjection(personal);
    final name = projection.displayName(room);
    return ConversationActivityBuilder(
      client: room.client,
      rooms: [room],
      headerPresence: true,
      builder: (context, activity) => NotionCompactChatHeader(
        // The partner's member event may load after the page is built.
        avatar: StreamBuilder(
          stream: room.client.onRoomState.stream.where(
            (u) =>
                u.roomId == room.id &&
                (u.state.type == EventTypes.RoomMember ||
                    u.state.type == EventTypes.RoomAvatar),
          ),
          builder: (context, _) => ListenableBuilder(
            listenable: personal,
            builder: (context, _) => ConversationActivityAvatar(
              activity: activity,
              child: notionInboxAvatar(personal, projection, room, size: 32),
            ),
          ),
        ),
        name: name,
        status: ConversationActivityStatus(
          client: room.client,
          rooms: [room],
          activity: activity,
          fallback: ChatHeaderSubtitle.infoLabel(context, room),
        ),
        onDetails: () => ChatLoomThemes.isThreeColumnMode(context)
            ? controller.toggleDisplayChatDetailsColumn()
            : context.go('${chatLocation(context, room.id)}/details'),
      ),
    );
  }
}

/// The line under the chat name, Telegram style, in priority order:
///
/// 1. a connection problem ("Connecting…", "Waiting for network…"), debounced
///    by [ConnectionStatusMonitor];
/// 2. "typing…" with the typing dots in the accent while someone else types
///    (the same received typing the timeline shows under the newest message;
///    this line only displays it and never sends typing);
/// 3. otherwise the network of a direct chat ("WhatsApp") or the member count
///    of a group.
///
/// States fade through each other. Only this line rebuilds on typing and
/// connection changes, never the header or the timeline.
class ChatHeaderSubtitle extends StatelessWidget {
  final Room room;

  /// Test seam; defaults to the client's shared monitor.
  final ConnectionStatusMonitor? monitor;

  const ChatHeaderSubtitle({super.key, required this.room, this.monitor});

  /// "typing…", or who is typing in a group; null while nobody else types.
  static String? typingLabel(BuildContext context, Room room) {
    final own = room.client.userID;
    final typing = room.typingUsers.where((user) => user.id != own).toList();
    if (typing.isEmpty) return null;
    if (room.isDirectChatForDisplay) return 'typing…';
    final l10n = L10n.of(context);
    return switch (typing.length) {
      1 => l10n.userIsTyping(typing.first.calcDisplayname()),
      2 => l10n.userAndUserAreTyping(
        typing.first.calcDisplayname(),
        typing[1].calcDisplayname(),
      ),
      _ => l10n.userAndOthersAreTyping(
        typing.first.calcDisplayname(),
        typing.length - 1,
      ),
    };
  }

  /// The resting line: network of a direct chat, member count of a group,
  /// and the network's disappearing-message timer ("WhatsApp · ⏱ 1 day",
  /// FX-13) like WhatsApp's and Telegram's chat headers.
  static String? infoLabel(BuildContext context, Room room) {
    final info = _info(context, room);
    final timer = disappearingTimerLabel(room);
    if (timer == null) return info;
    return info == null ? '⏱ $timer' : '$info · ⏱ $timer';
  }

  static String? _info(BuildContext context, Room room) {
    if (room.isDirectChatForDisplay) {
      final network = notionNetworkLabel(PersonalClient.networkOf(room));
      return network == 'Other' ? null : network;
    }
    final members =
        room.summary.mJoinedMemberCount ?? room.getParticipants().length;
    if (members <= 0) return null;
    return L10n.of(context).countParticipants(members);
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<Object>(
    stream: room.client.onSync.stream.where(
      (update) =>
          update.rooms?.join?[room.id]?.ephemeral?.any(
            (event) => event.type == 'm.typing',
          ) ??
          false,
    ),
    builder: (context, _) => ValueListenableBuilder(
      valueListenable: monitor ?? ConnectionStatusMonitor.of(room.client),
      builder: (context, phase, _) {
        final problem = phase.label;
        if (problem != null) {
          return _line(context, problem, key: 'status:$problem', live: true);
        }
        final typing = typingLabel(context, room);
        if (typing != null) {
          return _line(context, typing, key: 'typing', typing: true);
        }
        final info = infoLabel(context, room);
        return _line(context, info, key: 'info:$info');
      },
    ),
  );

  Widget _line(
    BuildContext context,
    String? text, {
    required String key,
    bool typing = false,
    bool live = false,
  }) {
    final notion = context.notion;
    final style = typing
        ? notion.typography.captionMuted.copyWith(color: notion.colors.accent)
        : notion.typography.captionMuted;
    return NotionFadeThrough(
      duration: NotionMotion.short,
      alignment: AlignmentDirectional.centerStart,
      child: text == null
          ? SizedBox.shrink(key: ValueKey(key))
          : Semantics(
              key: ValueKey(key),
              liveRegion: typing || live,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (typing) ...[
                    NotionTypingDots(size: 4, color: notion.colors.accent),
                    const SizedBox(width: NotionSpace.xxs),
                  ],
                  Flexible(
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

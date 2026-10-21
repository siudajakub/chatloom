// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/config/themes.dart';
import 'package:chatloom/pages/chat/chat.dart';
import 'package:chatloom/pages/chat_list/chat_list_item.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/person_location.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/health_status_widgets.dart';
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
    return NotionCompactChatHeader(
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
          builder: (context, _) =>
              notionInboxAvatar(personal, projection, room, size: 32),
        ),
      ),
      name: name,
      status: ConnectionStatusLine(client: room.client),
      onDetails: () => ChatLoomThemes.isThreeColumnMode(context)
          ? controller.toggleDisplayChatDetailsColumn()
          : context.go('${chatLocation(context, room.id)}/details'),
    );
  }
}

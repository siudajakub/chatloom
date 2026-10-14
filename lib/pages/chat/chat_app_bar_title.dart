// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/pages/chat/chat.dart';
import 'package:fluffychat/personal/inbox_projection.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

class ChatAppBarTitle extends StatelessWidget {
  final ChatController controller;
  const ChatAppBarTitle(this.controller, {super.key});
  @override
  Widget build(BuildContext context) {
    final room = controller.room;
    if (controller.selectedEvents.isNotEmpty) {
      return Text(controller.selectedEvents.length.toString());
    }
    final name = InboxProjection(
      PersonalClient.of(room.client),
    ).displayName(room);
    return NotionCompactChatHeader(
      avatar: Avatar(
        client: room.client,
        mxContent: room.avatar,
        name: name,
        size: 32,
      ),
      name: name,
      onDetails: () => FluffyThemes.isThreeColumnMode(context)
          ? controller.toggleDisplayChatDetailsColumn()
          : context.go('/rooms/${room.id}/details'),
    );
  }
}

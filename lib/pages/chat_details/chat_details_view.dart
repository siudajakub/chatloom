// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat_details/chat_details.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/notion_chat_details_adapter.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:material_ui/material_ui.dart';

class ChatDetailsView extends StatelessWidget {
  final ChatDetailsController controller;
  const ChatDetailsView(this.controller, {super.key});
  @override
  Widget build(BuildContext context) {
    final client = Matrix.of(context).client;
    final room = client.getRoomById(controller.roomId!);
    if (room == null) {
      return NotionScaffold(
        title: 'Chat details',
        onBack: () => Navigator.of(context).maybePop(),
        body: const NotionEmptyState(
          icon: Icons.link_off_outlined,
          title: 'This source is no longer available',
          message: 'Your private preferences have not been changed.',
        ),
      );
    }
    return NotionLiveChatDetails(
      key: ValueKey((client, room.id)),
      personal: PersonalClient.of(client),
      room: room,
      controller: controller,
    );
  }
}

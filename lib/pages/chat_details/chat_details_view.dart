// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat_details/chat_details.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/notion_chat_details_adapter.dart';
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
      return Scaffold(
        appBar: AppBar(title: const Text('Chat details')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              'This source is no longer available. Your private preferences have not been changed.',
            ),
          ),
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

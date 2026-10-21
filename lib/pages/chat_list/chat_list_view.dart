// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat_list/chat_list.dart';
import 'package:material_ui/material_ui.dart';
import 'chat_list_body.dart';

class ChatListView extends StatelessWidget {
  final ChatListController controller;
  const ChatListView(this.controller, {super.key});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: FocusManager.instance.primaryFocus?.unfocus,
      excludeFromSemantics: true,
      behavior: HitTestBehavior.translucent,
      child: ChatListViewBody(controller),
    );
  }
}

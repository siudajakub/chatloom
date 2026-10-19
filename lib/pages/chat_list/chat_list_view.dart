// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/pages/chat_list/chat_list.dart';
import 'package:fluffychat/pages/chat_list/navigation_rail.dart';
import 'package:material_ui/material_ui.dart';
import 'chat_list_body.dart';

class ChatListView extends StatelessWidget {
  final ChatListController controller;
  const ChatListView(this.controller, {super.key});
  @override
  Widget build(BuildContext context) {
    final wide = FluffyThemes.isColumnMode(context);
    return PopScope(
      canPop: !controller.isSearchMode && controller.activeSpaceId == null,
      onPopInvokedWithResult: (pop, _) {
        if (pop) return;
        if (controller.activeSpaceId != null) {
          controller.clearActiveSpace();
          return;
        }
        if (controller.isSearchMode) controller.cancelSearch();
      },
      child: Row(
        children: [
          if (wide)
            Material(
              color: Theme.of(context).colorScheme.surface,
              child: SpacesNavigationRail(
                activeSpaceId: controller.activeSpaceId,
                onGoToChats: controller.clearActiveSpace,
                onGoToSpaceId: controller.setActiveSpace,
              ),
            ),
          if (wide) Container(width: 1, color: Theme.of(context).dividerColor),
          Expanded(
            child: GestureDetector(
              onTap: FocusManager.instance.primaryFocus?.unfocus,
              excludeFromSemantics: true,
              behavior: HitTestBehavior.translucent,
              child: ChatListViewBody(controller),
            ),
          ),
        ],
      ),
    );
  }
}

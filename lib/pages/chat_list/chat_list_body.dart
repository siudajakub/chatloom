// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat_list/chat_list.dart';
import 'package:chatloom/pages/chat_list/chat_list_item.dart';
import 'package:chatloom/pages/chat_list/inbox_health_status.dart';
import 'package:chatloom/pages/chat_list/space_view.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/ui/health_status_widgets.dart';
import 'package:chatloom/personal/ui/notion_inbox_page.dart';
import 'package:chatloom/personal/ui/notion_inbox_pins.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class ChatListViewBody extends StatelessWidget {
  final ChatListController controller;
  const ChatListViewBody(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final client = Matrix.of(context).client;
    final activeSpace = controller.activeSpaceId;
    if (activeSpace != null)
      return Scaffold(
        body: SpaceView(
          key: ValueKey(activeSpace),
          spaceId: activeSpace,
          onBack: controller.clearActiveSpace,
          onChatTab: controller.onChatTap,
          activeChat: controller.activeChat,
        ),
      );
    final inbox = controller.inbox;
    return ListenableBuilder(
      listenable: inbox,
      builder: (context, _) {
        final projection = inbox.projection;
        final delegated = inbox.delegated;
        final rooms = controller.filterRooms();
        final pins =
            (controller.personalFilter == InboxFilter.inbox ? rooms : <Room>[])
                .where((room) => projection.metadataFor(room).isPinned)
                .map(
                  (room) => NotionPinnedShortcut(
                    name: projection.displayName(room),
                    avatar: notionInboxAvatar(
                      controller.personal,
                      projection,
                      room,
                      size: 28,
                    ),
                    onTap: () => controller.onChatTap(room),
                    onLongPress: () => controller.chatContextAction(
                      room,
                      context,
                      delegated[room.id],
                    ),
                    order: projection.metadataFor(room).pinOrder!,
                    isGroup: !room.isDirectChatForDisplay,
                  ),
                )
                .toList();
        final positions = <String, int>{
          for (final (index, room) in rooms.indexed) room.id: index,
        };
        return NotionInboxPage(
          scrollController: controller.scrollController,
          rowCount: rooms.length,
          rowBuilder: (context, index) {
            final room = rooms[index];
            final entity = projection.entityFor(room);
            return ChatListItem(
              room,
              projection: projection,
              flash: controller.rowFlash(entity),
              flashOnMount: controller.takeFreshFlash(entity),
              space: delegated[room.id],
              key: ValueKey(chatListItemKey(room.id)),
              onTap: () => controller.onChatTap(room),
              onLongPress: (posContext) => controller.chatContextAction(
                room,
                posContext,
                delegated[room.id],
              ),
              activeChat:
                  controller.activeChat == room.id ||
                  (controller.activeGroup != null &&
                      projection.groupFor(room)?.id == controller.activeGroup),
            );
          },
          rowIndexOf: (key) {
            if (key is! ValueKey<String>) return null;
            final value = key.value;
            if (!value.startsWith(_rowKeyPrefix)) return null;
            return positions[value.substring(_rowKeyPrefix.length)];
          },
          pins: pins,
          loading: inbox.loading,
          emptyMessage: controller.selectedNetwork != null
              ? 'No chats from this network in the current view.'
              : controller.personalFilter != InboxFilter.inbox ||
                    controller.activeFilter != ActiveFilter.allChats
              ? 'No chats in ${inboxViewLabel(controller.personalFilter)}. Choose another view or network.'
              : 'No chats yet. Use Search to find people on your networks.',
          // Connection, encryption and private sync, bridges, push and the
          // worker in one row; it takes no space while there is nothing to say.
          status: InboxHealthStatus(key: ValueKey(client), client: client),
          headerStatus: ConnectionStatusLine(client: client),
          onSettings: () => context.go('/rooms/settings'),
          // Search is also where new chats start (no separate compose button).
          onSearch: controller.openSearch,
          networks: controller.availableNetworks,
          selectedNetwork: controller.selectedNetwork,
          selectedView: controller.personalFilter,
          onViewSelected: (view) => controller.setPersonalFilter(view, null),
          onManageNetworks: () => context.push('/rooms/settings/networks'),
          onNetworkSelected: controller.setNetwork,
        );
      },
    );
  }
}

const _rowKeyPrefix = 'chat_list_item_';

/// Stable inbox row key (also used by tests and captures).
String chatListItemKey(String roomId) => '$_rowKeyPrefix$roomId';

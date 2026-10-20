// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/config/themes.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat_list/chat_list.dart';
import 'package:chatloom/pages/chat_list/chat_list_item.dart';
import 'package:chatloom/pages/chat_list/client_chooser_button.dart';
import 'package:chatloom/pages/chat_list/inbox_health_status.dart';
import 'package:chatloom/pages/chat_list/space_view.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/organization_page.dart';
import 'package:chatloom/personal/personal_search_page.dart';
import 'package:chatloom/personal/ui/notion_inbox_page.dart';
import 'package:chatloom/personal/ui/notion_inbox_pins.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/personal/ui/notion_search_controls.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/sync_status_localization.dart';
import 'package:chatloom/widgets/adaptive_dialogs/public_room_dialog.dart';
import 'package:chatloom/widgets/adaptive_dialogs/user_dialog.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:chatloom/widgets/future_loading_dialog.dart';
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
        final failed = inbox.syncFailed;
        final status = client.onSyncStatus.value;
        final positions = <String, int>{
          for (final (index, room) in rooms.indexed) room.id: index,
        };
        return NotionInboxPage(
          scrollController: controller.scrollController,
          rowCount: rooms.length,
          rowBuilder: (context, index) {
            final room = rooms[index];
            return ChatListItem(
              room,
              projection: projection,
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
          emptyMessage: controller.searchController.text.trim().isNotEmpty
              ? 'No matching chats in the current view. Try another name or change the filter.'
              : controller.selectedNetwork != null
              ? 'No chats from this network in the current view.'
              : controller.personalFilter != InboxFilter.inbox ||
                    controller.activeFilter != ActiveFilter.allChats
              ? 'No chats in ${inboxViewLabel(controller.personalFilter)}. Choose another view or network.'
              : 'No chats yet. Start a new chat.',
          // Connection first, then encryption and private sync health; each
          // takes no space while there is nothing to say.
          status: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The offline notice grows in and shrinks away with the
              // connection instead of shifting the list in one jump.
              NotionSizeReveal(
                visible: failed && status != null,
                revealOnMount: true,
                child: Padding(
                  padding: const EdgeInsets.only(top: NotionSpace.xs),
                  child: SizedBox(
                    width: double.infinity,
                    child: NotionCallout(
                      icon: Icons.cloud_off_outlined,
                      title: status?.calcLocalizedString(context) ?? '',
                      message: 'Showing loaded chats.',
                      actionLabel: 'Retry',
                      onAction: () => showFutureLoadingDialog(
                        context: context,
                        future: () =>
                            client.oneShotSync(timeout: Duration.zero),
                      ),
                    ),
                  ),
                ),
              ),
              InboxHealthStatus(key: ValueKey(client), client: client),
            ],
          ),
          onCompose: () => context.go('/rooms/newprivatechat'),
          onSettings: () => context.go('/rooms/settings'),
          onSearch: controller.startSearch,
          networks: controller.availableNetworks,
          selectedNetwork: controller.selectedNetwork,
          selectedView: controller.personalFilter,
          onViewSelected: (view) => controller.setPersonalFilter(view, null),
          onManageNetworks: () => context.push('/rooms/settings/networks'),
          onNetworkSelected: controller.setNetwork,
          searchTools: controller.isSearchMode
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    NotionInboxSearch(
                      controller: controller.searchController,
                      focusNode: controller.searchFocusNode,
                      onChanged: controller.onSearchEnter,
                      onClose: controller.cancelSearch,
                      searchingPublic: controller.isSearching,
                      onHistorySearch: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              PersonalSearchPage(personal: controller.personal),
                        ),
                      ),
                      onPublicDiscovery: controller.discoverPublic,
                      options: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton.icon(
                            onPressed: () => _showOptions(context),
                            icon: const Icon(Icons.tune, size: 18),
                            label: const Text('Inbox view'),
                          ),
                          ClientChooserButton(controller),
                        ],
                      ),
                    ),
                    if (controller.publicDiscovery) _publicResults(context),
                  ],
                )
              : null,
        );
      },
    );
  }

  void _showOptions(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Inbox view', style: NotionTokens.heading),
              const SizedBox(height: 12),
              PersonalInboxFilters(
                personal: controller.personal,
                value: controller.personalFilter,
                labelKey: controller.personalLabel,
                onChanged: (filter, label) {
                  controller.setPersonalFilter(filter, label);
                  Navigator.of(context).pop();
                },
              ),
              Wrap(
                children: [
                  for (final filter in ActiveFilter.values.where(
                    (f) => f != ActiveFilter.tag,
                  ))
                    TextButton(
                      onPressed: () {
                        controller.setActiveFilter(filter, null);
                        Navigator.of(context).pop();
                      },
                      child: Text(filter.toLocalizedString(context)),
                    ),
                ],
              ),
              if (controller.spaces.isNotEmpty) ...[
                const Divider(),
                Text('Spaces', style: NotionTokens.heading),
                for (final space in controller.spaces)
                  TextButton.icon(
                    onPressed: () {
                      controller.setActiveSpace(space.id);
                      Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.workspaces_outlined),
                    label: Text(space.getLocalizedDisplayname()),
                  ),
              ],
              IconButton(
                tooltip: 'Sync & transcriptions',
                icon: const Icon(Icons.sync_outlined),
                onPressed: () => context.push('/rooms/settings/sync'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _publicResults(BuildContext context) {
    final publicRooms = controller.roomSearchResult?.chunk
        .where((r) => r.roomType != 'm.space')
        .toList();
    final publicSpaces = controller.roomSearchResult?.chunk
        .where((r) => r.roomType == 'm.space')
        .toList();
    final users = controller.userSearchResult?.results;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Text('Public discovery', style: NotionTokens.heading),
        Text(
          'This query is sent to the selected homeserver directory.',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        TextButton.icon(
          onPressed: controller.setServer,
          icon: const Icon(Icons.edit_outlined, size: 16),
          label: Text(
            controller.searchServer ??
                Matrix.of(context).client.homeserver?.host ??
                'Choose homeserver',
          ),
        ),
        if (!controller.isSearching &&
            publicRooms?.isEmpty == true &&
            publicSpaces?.isEmpty == true &&
            users?.isEmpty == true)
          const Text(
            'No results in this directory. Other networks and message history were not searched.',
          ),
        if (publicRooms?.isNotEmpty == true) ...[
          const Text('Public rooms'),
          PublicRoomsHorizontalList(publicRooms: publicRooms),
        ],
        if (publicSpaces?.isNotEmpty == true) ...[
          const Text('Public spaces'),
          PublicRoomsHorizontalList(publicRooms: publicSpaces),
        ],
        if (users?.isNotEmpty == true) ...[
          const Text('People'),
          SizedBox(
            height: 106,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: users!.length,
              itemBuilder: (context, i) => _SearchItem(
                title:
                    users[i].displayName ??
                    users[i].userId.localpart ??
                    'Unknown name',
                avatar: users[i].avatarUrl,
                onPressed: () =>
                    UserDialog.show(context: context, profile: users[i]),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

const _rowKeyPrefix = 'chat_list_item_';

/// Stable inbox row key (also used by tests and captures).
String chatListItemKey(String roomId) => '$_rowKeyPrefix$roomId';

class PublicRoomsHorizontalList extends StatelessWidget {
  const PublicRoomsHorizontalList({super.key, required this.publicRooms});

  final List<PublishedRoomsChunk>? publicRooms;

  @override
  Widget build(BuildContext context) {
    final publicRooms = this.publicRooms;
    return AnimatedContainer(
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(),
      height: publicRooms == null || publicRooms.isEmpty ? 0 : 106,
      duration: ChatLoomThemes.animationDuration,
      curve: ChatLoomThemes.animationCurve,
      child: publicRooms == null
          ? null
          : ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: publicRooms.length,
              itemBuilder: (context, i) => _SearchItem(
                title:
                    publicRooms[i].name ??
                    publicRooms[i].canonicalAlias?.localpart ??
                    L10n.of(context).group,
                avatar: publicRooms[i].avatarUrl,
                onPressed: () => showAdaptiveDialog(
                  context: context,
                  barrierDismissible: true,
                  builder: (c) => PublicRoomDialog(
                    roomAlias:
                        publicRooms[i].canonicalAlias ?? publicRooms[i].roomId,
                    chunk: publicRooms[i],
                  ),
                ),
              ),
            ),
    );
  }
}

class _SearchItem extends StatelessWidget {
  final String title;
  final Uri? avatar;
  final void Function() onPressed;

  const _SearchItem({
    required this.title,
    this.avatar,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onPressed,
    child: SizedBox(
      width: 84,
      child: Column(
        mainAxisSize: .min,
        children: [
          const SizedBox(height: 8),
          Avatar(mxContent: avatar, name: title),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(
              title,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    ),
  );
}

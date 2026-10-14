// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:async/async.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat_list/chat_list.dart';
import 'package:fluffychat/pages/chat_list/chat_list_item.dart';
import 'package:fluffychat/pages/chat_list/client_chooser_button.dart';
import 'package:fluffychat/pages/chat_list/space_view.dart';
import 'package:fluffychat/personal/inbox_projection.dart';
import 'package:fluffychat/personal/organization_page.dart';
import 'package:fluffychat/personal/personal_hub.dart';
import 'package:fluffychat/personal/personal_search_page.dart';
import 'package:fluffychat/personal/ui/notion_inbox_page.dart';
import 'package:fluffychat/personal/ui/notion_inbox_pins.dart';
import 'package:fluffychat/personal/ui/notion_search_controls.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/utils/stream_extension.dart';
import 'package:fluffychat/utils/sync_status_localization.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/public_room_dialog.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/user_dialog.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:fluffychat/widgets/matrix.dart';
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
      return SpaceView(
        key: ValueKey(activeSpace),
        spaceId: activeSpace,
        onBack: controller.clearActiveSpace,
        onChatTab: controller.onChatTap,
        activeChat: controller.activeChat,
      );
    final spaces = client.rooms.where((room) => room.isSpace);
    final delegated = <String, Room>{};
    for (final space in spaces) {
      for (final child in space.spaceChildren) {
        if (child.roomId != null) delegated[child.roomId!] = space;
      }
    }
    return StreamBuilder<Object>(
      key: ValueKey(client.clientName),
      stream: StreamGroup.merge<Object>([
        client.onSync.stream.where((s) => s.hasRoomUpdate),
        client.onSyncStatus.stream,
        controller.personal.changes,
      ]).rateLimit(const Duration(milliseconds: 200)),
      builder: (context, _) {
        final projection = InboxProjection(controller.personal);
        final rooms = controller.filteredRooms
            .where(
              (room) =>
                  !AppSettings.hideRoomsInSpaces.value ||
                  delegated[room.id] == null,
            )
            .toList();
        final pins = rooms
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
                isGroup: !room.isDirectChat,
              ),
            )
            .toList();
        final status = client.onSyncStatus.value;
        final failed = status?.status == SyncStatus.error;
        return NotionInboxPage(
          scrollController: controller.scrollController,
          rows: rooms
              .map(
                (room) => ChatListItem(
                  room,
                  space: delegated[room.id],
                  key: ValueKey('chat_list_item_${room.id}'),
                  onTap: () => controller.onChatTap(room),
                  onLongPress: (posContext) => controller.chatContextAction(
                    room,
                    posContext,
                    delegated[room.id],
                  ),
                  activeChat: controller.activeChat == room.id,
                ),
              )
              .toList(),
          pins: pins,
          loading: client.prevBatch == null && !failed,
          emptyMessage: controller.searchController.text.trim().isNotEmpty
              ? 'No matching chats in the current view. Try another name or change the filter.'
              : controller.selectedNetwork != null
              ? 'No chats from this network in the current view.'
              : controller.personalFilter != InboxFilter.inbox ||
                    controller.activeFilter != ActiveFilter.allChats
              ? 'No chats in this view. Change the inbox filter to see other conversations.'
              : 'No chats yet. Start a new chat.',
          status: failed
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.cloud_off_outlined, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${status!.calcLocalizedString(context)}. Showing loaded chats.',
                          style: const TextStyle(fontSize: 12, height: 1.4),
                        ),
                      ),
                      TextButton(
                        onPressed: () => showFutureLoadingDialog(
                          context: context,
                          future: () =>
                              client.oneShotSync(timeout: Duration.zero),
                        ),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : null,
          onCompose: () => context.go('/rooms/newprivatechat'),
          onSettings: () => context.go('/rooms/settings'),
          onSearch: controller.startSearch,
          networks: controller.availableNetworks,
          selectedNetwork: controller.selectedNetwork,
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
                  for (final tag in controller.roomTags.keys)
                    TextButton(
                      onPressed: () {
                        controller.setActiveFilter(ActiveFilter.tag, tag);
                        Navigator.of(context).pop();
                      },
                      child: Text(tag.replaceFirst('u.', '')),
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
              const PersonalHubButton(),
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
      duration: FluffyThemes.animationDuration,
      curve: FluffyThemes.animationCurve,
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

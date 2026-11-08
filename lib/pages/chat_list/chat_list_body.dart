// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat/message_deletion.dart';
import 'package:chatloom/pages/chat_list/chat_list.dart';
import 'package:chatloom/pages/chat_list/chat_list_item.dart';
import 'package:chatloom/pages/chat_list/inbox_health_status.dart';
import 'package:chatloom/pages/chat_list/inbox_pins.dart';
import 'package:chatloom/personal/hidden_messages.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/kept_messages.dart';
import 'package:chatloom/personal/media/avatar_cache.dart';
import 'package:chatloom/personal/ui/health_status_widgets.dart';
import 'package:chatloom/personal/ui/notion_inbox_page.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class ChatListViewBody extends StatefulWidget {
  final ChatListController controller;
  const ChatListViewBody(this.controller, {super.key});

  @override
  State<ChatListViewBody> createState() => _ChatListViewBodyState();
}

class _ChatListViewBodyState extends State<ChatListViewBody> {
  Object? _prefetchKey;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final client = Matrix.of(context).client;
    final inbox = controller.inbox;
    return ListenableBuilder(
      // "Remove for you" (FX-16) and a delete for everyone change a row's
      // preview; the rows' own signatures keep that to the rows concerned.
      listenable: Listenable.merge([
        inbox,
        HiddenMessages.instance,
        MessageDeletions.changes,
        KeptMessages.instance,
      ]),
      builder: (context, _) {
        final projection = inbox.projection;
        final usable = !inbox.loading && !inbox.localLoadFailed;
        final rooms = usable ? controller.filterRooms() : <Room>[];
        // Network marks on avatars only while every network is listed and
        // there is more than one (UX-17, FT-12).
        final showNetworks =
            controller.selectedNetwork == null &&
            controller.availableNetworks.length > 1;
        final pins =
            (controller.personalFilter == InboxFilter.inbox ? rooms : <Room>[])
                .where((room) => projection.metadataFor(room).isPinned)
                .map(
                  (room) => inboxPinnedShortcut(
                    controller.personal,
                    projection,
                    room,
                    onTap: () => controller.onChatTap(room),
                    onLongPress: () =>
                        controller.chatContextAction(room, context),
                    showNetworks: showNetworks,
                  ),
                )
                .toList();
        final positions = <String, int>{
          for (final (index, room) in rooms.indexed) room.id: index,
        };
        controller.rowMemo.retain(rooms.length);
        // Resolve ahead-of-screen avatars once per selection/data change,
        // after the current frame. Parent builds, deleted-preview notices and
        // other presentation-only changes must not repeatedly scan 80 photos
        // (the disk cache's byte deduplication happens after URI resolution).
        final physicalSide =
            _avatarPrefetchSide * MediaQuery.devicePixelRatioOf(context);
        final prefetchKey = (inbox, inbox.generation, rooms, physicalSide);
        if (_prefetchKey != prefetchKey) {
          _prefetchKey = prefetchKey;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _prefetchKey != prefetchKey || !inbox.active) {
              return;
            }
            AvatarCache.prefetch(
              client,
              rooms
                  .take(_avatarPrefetchRows)
                  .map(projection.avatarFor)
                  .whereType<Uri>(),
              physicalSide,
            );
          });
        }
        return NotionInboxPage(
          unreadCount: usable ? controller.unreadViewCount() : 0,
          requestCount: usable ? controller.requestViewCount() : 0,
          scrollController: controller.scrollController,
          rowCount: rooms.length,
          rowOrder: [for (final room in rooms) room.id],
          rowBuilder: (context, index) {
            final room = rooms[index];
            final entity = projection.entityFor(room);
            final flash = controller.rowFlash(entity);
            final active =
                controller.activeChat == room.id ||
                (controller.activeGroup != null &&
                    projection.groupFor(room)?.id == controller.activeGroup);
            // An unchanged row returns the same widget, so a publish
            // (another room's message, a typing change) rebuilds only the
            // rows whose inputs changed.
            final row = controller.rowMemo.resolve(
              entity,
              chatListItemSignature(
                room,
                projection,
                activeChat: active,
                flash: flash,
                showNetworks: showNetworks,
              ),
              () => ChatListItem(
                room,
                projection: projection,
                flash: flash,
                flashOnMount: controller.takeFreshFlash(entity),
                key: ValueKey(chatListItemKey(room.id)),
                onTap: () => controller.onChatTap(room),
                onLongPress: (posContext) =>
                    controller.chatContextAction(room, posContext),
                activeChat: active,
                showNetworks: showNetworks,
              ),
            );
            // Swipes (UX-14) wrap the memoised row; same key, so the list
            // still finds the row by room.
            final sides = controller.rowSwipeSides(room, projection);
            if (sides == null) return row;
            return NotionSwipeAction(
              key: ValueKey(chatListItemKey(room.id)),
              endToStart: sides.toStart,
              startToEnd: sides.toEnd,
              child: row,
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
          onRetryLoading: inbox.localLoadFailed
              ? controller.retryLocalInbox
              : null,
          emptyMessage: inbox.localLoadFailed
              ? 'Retry loading your chats, or check sync and storage in Settings.'
              : controller.personalFilter == InboxFilter.aside
              ? 'No chats in Aside${controller.selectedNetwork == null ? '' : ' from this network'}. Hold a chat and choose Move to Aside.'
              : controller.selectedNetwork != null
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
          onMarkAllRead: usable ? controller.markViewRead : null,
          onReorderPins: controller.reorderPins,
        );
      },
    );
  }
}

const _rowKeyPrefix = 'chat_list_item_';

/// Inbox rows whose avatars are fetched ahead, and their row avatar size.
const _avatarPrefetchRows = 80;
const double _avatarPrefetchSide = 42;

/// Stable inbox row key (also used by tests and captures).
String chatListItemKey(String roomId) => '$_rowKeyPrefix$roomId';

/// Built inbox rows by entity, reused while their signature
/// ([chatListItemSignature]) stays equal. Bounded: cleared when it holds
/// far more rows than the list shows.
class InboxRowMemo {
  final _rows = <String, (List<Object?>, Widget)>{};

  /// Rows built (not reused) since creation; performance tests.
  @visibleForTesting
  int debugBuilt = 0;

  Widget resolve(
    String entity,
    List<Object?> signature,
    Widget Function() build,
  ) {
    final cached = _rows[entity];
    if (cached != null && listEquals(cached.$1, signature)) return cached.$2;
    debugBuilt++;
    final row = build();
    _rows[entity] = (signature, row);
    return row;
  }

  void retain(int visible) {
    if (_rows.length > visible * 2 + 64) _rows.clear();
  }

  void clear() => _rows.clear();
}

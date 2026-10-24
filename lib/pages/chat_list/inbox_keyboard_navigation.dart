// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat_list/chat_actions_menu.dart';
import 'package:chatloom/pages/chat_list/chat_list.dart';
import 'package:chatloom/utils/macos_desktop.dart';
import 'package:collection/collection.dart';
import 'package:matrix/matrix.dart';

/// The row [delta] places after [current] in a list of [length] rows, or
/// null past either end (Telegram does not wrap). Without an open row the
/// first (forward) or last (backward) row.
int? inboxNeighbour({
  required int length,
  required int? current,
  required int delta,
}) {
  if (length == 0) return null;
  if (current == null) return delta > 0 ? 0 : length - 1;
  final next = current + delta;
  return next < 0 || next >= length ? null : next;
}

/// The first row after [current] for which [matches] holds, continuing from
/// the top; null when no other row matches.
int? inboxNextMatching({
  required int length,
  required int? current,
  required bool Function(int index) matches,
}) {
  final start = current ?? -1;
  for (var offset = 1; offset <= length; offset++) {
    final index = (start + offset) % length;
    if (index == current) break;
    if (matches(index)) return index;
  }
  return null;
}

/// The inbox's keyboard commands (Mac): rows in the order on screen (pinned
/// chats come first), the open chat or person from the route.
MacInboxCommands inboxKeyboardCommands(ChatListController controller) {
  List<Room> rows() => controller.mounted ? controller.filterRooms() : const [];
  int? current(List<Room> rooms) {
    final projection = controller.inbox.projection;
    final group = controller.activeGroup;
    final index = rooms.indexWhere(
      (room) =>
          room.id == controller.activeChat ||
          (group != null && projection.groupFor(room)?.id == group),
    );
    return index < 0 ? null : index;
  }

  void open(List<Room> rooms, int? index) {
    if (index != null) controller.onChatTap(rooms[index]);
  }

  /// The open row's menu entry among [actions] (whichever of the pair
  /// applies), applied as the menu or a swipe would: at once, with Undo
  /// for archiving. A disabled entry (private sync not ready) does nothing.
  void toggle(Set<ChatMenuAction> actions) {
    final rooms = rows();
    final index = current(rooms);
    if (index == null) return;
    final room = rooms[index];
    final item = chatMenuItems(
      controller.personal,
      room,
      pinLabel: '',
      unpinLabel: '',
    ).firstWhereOrNull((item) => actions.contains(item.action));
    if (item == null || !item.enabled) return;
    controller.applyRowAction(room, item.action);
  }

  return MacInboxCommands(
    search: controller.openSearch,
    openAt: (index) {
      final rooms = rows();
      if (index < rooms.length) open(rooms, index);
    },
    step: (delta) {
      final rooms = rows();
      open(
        rooms,
        inboxNeighbour(
          length: rooms.length,
          current: current(rooms),
          delta: delta,
        ),
      );
    },
    nextUnread: () {
      final rooms = rows();
      final projection = controller.inbox.projection;
      open(
        rooms,
        inboxNextMatching(
          length: rooms.length,
          current: current(rooms),
          matches: (index) {
            final room = rooms[index];
            return projection.unreadCount(room) > 0 || room.isUnreadOrInvited;
          },
        ),
      );
    },
    toggleArchived: () =>
        toggle(const {ChatMenuAction.archive, ChatMenuAction.unarchive}),
    toggleUnread: () =>
        toggle(const {ChatMenuAction.read, ChatMenuAction.unread}),
  );
}

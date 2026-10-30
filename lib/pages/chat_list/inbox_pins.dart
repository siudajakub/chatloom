// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat_list/chat_list_item.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/push_rule_mirror.dart';
import 'package:chatloom/personal/ui/notion_inbox_network_badge.dart';
import 'package:chatloom/personal/ui/notion_inbox_pins.dart';
import 'package:chatloom/personal/ui/notion_network_adapter.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

/// The pinned bubble of [room] (a pinned inbox row): its avatar, the unread
/// state the row shows (count, manual dot, mention, muted) and, with
/// [showNetworks], the row's network marks.
NotionPinnedShortcut inboxPinnedShortcut(
  PersonalClient personal,
  InboxProjection projection,
  Room room, {
  required VoidCallback onTap,
  VoidCallback? onLongPress,
  bool showNetworks = false,
}) {
  final metadata = projection.metadataFor(room);
  final group = projection.groupFor(room);
  final sources = group == null
      ? [room]
      : [
          for (final member in group.members)
            ?room.client.getRoomById(member.roomId),
        ];
  final invite = room.membership == Membership.invite;
  return NotionPinnedShortcut(
    name: projection.displayName(room),
    avatar: notionInboxAvatar(
      personal,
      projection,
      room,
      size: notionPinnedAvatarSize,
    ),
    onTap: onTap,
    onLongPress: onLongPress,
    order: metadata.pinOrder ?? 0,
    isGroup: !room.isDirectChatForDisplay,
    id: projection.entityFor(room),
    unreadCount: projection.unreadCount(room),
    unread: sources.any(personalRoomUnread),
    mentioned: !invite && sources.any((source) => source.highlightCount > 0),
    muted:
        metadata.muted ||
        sources.any((source) => source.pushRuleState != PushRuleState.notify),
    networks: showNetworks
        ? notionBadgeNetworks(notionRoomNetworks(projection, room))
        : const [],
  );
}

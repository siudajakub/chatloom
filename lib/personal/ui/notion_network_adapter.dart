// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/personal/inbox_projection.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:matrix/matrix.dart';

/// Only eligible groups returned by InboxProjection participate; invalid or
/// foreign-account memberships cannot add a displayed network.
Set<String> notionRoomNetworks(InboxProjection projection, Room room) {
  final group = projection.groupFor(room);
  if (group == null) return {PersonalClient.networkOf(room)};
  return group.members
      .map((source) => room.client.getRoomById(source.roomId))
      .whereType<Room>()
      .map(PersonalClient.networkOf)
      .toSet();
}

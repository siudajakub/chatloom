// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/personal/bridged_room.dart';
import 'package:matrix/matrix.dart';

/// Empty or malformed avatar state is not a photo. In particular Uri('')
/// must not mask the bridge's channel photo or a loaded contact photo.
Uri? usableAvatarUri(Object? value) {
  final uri = value is Uri
      ? value
      : value is String
      ? Uri.tryParse(value.trim())
      : null;
  return uri?.scheme == 'mxc' &&
          uri!.host.isNotEmpty &&
          uri.pathSegments.length == 1 &&
          uri.pathSegments.single.isNotEmpty
      ? uri
      : null;
}

Uri? _bridgePhoto(Room room) {
  for (final type in bridgeInfoStateTypes) {
    for (final state in room.states[type]?.values ?? <StrippedStateEvent>[]) {
      final channel = state.content['channel'];
      final avatar = usableAvatarUri(
        channel is Map ? channel['avatar_url'] : null,
      );
      if (avatar != null) return avatar;
    }
  }
  return null;
}

/// Photo from loaded room/contact state only. A group never borrows a
/// participant's photo. A direct portal can reuse the same person's member
/// photo from another room, when lazy-loading omitted it in this portal.
Uri? roomAvatarUri(Room room) {
  final own = usableAvatarUri(room.avatar) ?? _bridgePhoto(room);
  if (own != null) return own;
  final partner = room.directChatMatrixIDForDisplay;
  if (!room.isDirectChatForDisplay || partner == null) return null;
  return userAvatarUri(room.unsafeGetUserFromMemoryOrFallback(partner));
}

Uri? userAvatarUri(User user) {
  final own = usableAvatarUri(user.avatarUrl);
  if (own != null) return own;
  for (final room in user.room.client.rooms) {
    if (room.membership != Membership.join) continue;
    final member = usableAvatarUri(
      room.getState(EventTypes.RoomMember, user.id)?.content['avatar_url'],
    );
    if (member != null) return member;
    if (room.isDirectChatForDisplay &&
        room.directChatMatrixIDForDisplay == user.id) {
      final photo =
          usableAvatarUri(
            room.getState(EventTypes.RoomAvatar)?.content['url'],
          ) ??
          _bridgePhoto(room);
      if (photo != null) return photo;
    }
  }
  return null;
}

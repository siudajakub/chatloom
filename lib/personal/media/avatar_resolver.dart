// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatloom/personal/bridged_room.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
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
  // Prefer this portal's contact photo over another room's older state.
  final room = user.room;
  if (room.membership == Membership.join) {
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
  return LoadedAvatarIndex.of(room.client).photoFor(user.id);
}

/// Account-local index of already loaded contact photos. Missing photos used
/// to scan every room on every row/build, quadratic for a photo-less inbox.
/// One pass now serves every lookup until relevant loaded state changes.
class LoadedAvatarIndex {
  static final _indexes = Expando<LoadedAvatarIndex>('loaded avatar photos');
  static LoadedAvatarIndex of(Client client) =>
      _indexes[client] ??= LoadedAvatarIndex._(client);

  final Client client;
  final _photos = <String, Uri>{};
  bool _dirty = true;
  int _roomCount = -1;
  String? _owner;
  Object? _lastState;
  Object? _lastSync;
  final _subscriptions = <StreamSubscription>[];

  LoadedAvatarIndex._(this.client) {
    _subscriptions.addAll([
      client.onRoomState.stream.listen((update) {
        final type = update.state.type;
        if (type == EventTypes.RoomMember ||
            type == EventTypes.RoomAvatar ||
            type == EventTypes.RoomCreate ||
            type == 'com.beeper.room_features' ||
            bridgeInfoStateTypes.contains(type)) {
          _dirty = true;
        }
      }, onError: (Object _) {}),
      client.onSync.stream.listen(_onSync, onError: (Object _) {}),
    ]);
  }

  void _onSync(SyncUpdate sync) {
    if (sync.accountData?.any((event) => event.type == 'm.direct') == true ||
        sync.rooms?.leave?.isNotEmpty == true ||
        sync.rooms?.invite?.isNotEmpty == true) {
      _dirty = true;
    }
  }

  @visibleForTesting
  int debugBuilds = 0;
  @visibleForTesting
  int debugRoomsScanned = 0;

  Uri? photoFor(String userId) {
    // setState and sync publish asynchronously. Observe their newest values
    // as well: same-turn callers must not receive an obsolete contact photo.
    final state = client.onRoomState.value;
    if (!identical(state, _lastState)) {
      _dirty = true;
      _lastState = state;
    }
    final sync = client.onSync.value;
    if (!identical(sync, _lastSync)) {
      if (sync != null) _onSync(sync);
      _lastSync = sync;
    }
    if (_dirty ||
        _roomCount != client.rooms.length ||
        _owner != client.userID) {
      _dirty = false;
      _roomCount = client.rooms.length;
      _owner = client.userID;
      debugBuilds++;
      _photos.clear();
      for (final room in client.rooms) {
        debugRoomsScanned++;
        if (room.membership != Membership.join) continue;
        // Preserve first-room precedence: member photo before that room's DM
        // photo, then the next room. Groups supply member photos only.
        for (final entry
            in room.states[EventTypes.RoomMember]?.entries ??
                <MapEntry<String, StrippedStateEvent>>[]) {
          final photo = usableAvatarUri(entry.value.content['avatar_url']);
          if (photo != null) _photos.putIfAbsent(entry.key, () => photo);
        }
        if (!room.isDirectChatForDisplay) continue;
        final partner = room.directChatMatrixIDForDisplay;
        if (partner == null) continue;
        final photo =
            usableAvatarUri(
              room.getState(EventTypes.RoomAvatar)?.content['url'],
            ) ??
            _bridgePhoto(room);
        if (photo != null) _photos.putIfAbsent(partner, () => photo);
      }
    }
    return _photos[userId];
  }

  @visibleForTesting
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _indexes[client] = null;
  }
}

/// Changes that can affect [userAvatarUri], without rebuilding the timeline
/// for unrelated messages, receipts or other participants' profiles.
bool affectsUserAvatar(User user, String roomId, StrippedStateEvent state) {
  if (state.type == EventTypes.RoomMember) return state.stateKey == user.id;
  if (state.type != EventTypes.RoomAvatar &&
      !bridgeInfoStateTypes.contains(state.type)) {
    return false;
  }
  final room = roomId == user.room.id
      ? user.room
      : user.room.client.getRoomById(roomId);
  return room != null &&
      room.membership == Membership.join &&
      room.isDirectChatForDisplay &&
      room.directChatMatrixIDForDisplay == user.id;
}

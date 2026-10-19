// SPDX-License-Identifier: AGPL-3.0-or-later

/// "Was this sent by me?" for the app, including bridge ghosts of the owner's
/// own remote accounts (Telegram/WhatsApp/Signal… messages sent from the
/// native apps without double puppeting).
///
/// Stable API (used by the inbox, chat search, previews, notifications):
/// ```dart
/// final own = OwnSenderResolver.of(client);
/// own.isOwnEvent(event);          // account or own ghost, evidence scoped to
///                                 // the event's room (previews, labels)
/// own.isOwnSender(senderId, roomId: room.id);
/// own.isStronglyOwnEvent(event);  // account or receiver-proved ghost only;
///                                 // the only check that may suppress a
///                                 // notification or a mention
/// own.identity;                   // personal_core OwnRemoteIdentity
/// OwnSenderResolver.invalidate(client); // after injecting state in tests
/// ```
/// One resolver per [Client], built lazily from already-loaded room state (no
/// network). It is rebuilt only after bridge, member or `m.direct` state
/// changed or the room count changed; checks in between are a set lookup.
/// Bridge declarations count only in joined rooms, when sent by the declared
/// bridge bot that is itself joined. See
/// `packages/personal_core/lib/src/own_identity.dart` for the layers.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

class OwnSenderResolver {
  static final _resolvers = Expando<OwnSenderResolver>('own sender');

  static OwnSenderResolver of(Client client) =>
      _resolvers[client] ??= OwnSenderResolver._(client);

  /// Forces a rebuild on the next query (tests, explicit state injection).
  static void invalidate(Client client) => _resolvers[client]?._dirty = true;

  final Client client;
  OwnRemoteIdentity? _identity;
  bool _dirty = true;
  int _roomCount = -1;
  String? _userId;
  StreamSubscription? _stateSub, _syncSub;

  OwnSenderResolver._(this.client) {
    _stateSub = client.onRoomState.stream.listen((update) {
      final type = update.state.type;
      if (type == EventTypes.RoomMember ||
          ownIdentityBridgeStateTypes.contains(type)) {
        _dirty = true;
      }
    }, onError: (_) {});
    _syncSub = client.onSync.stream.listen((sync) {
      if (sync.accountData?.any((e) => e.type == 'm.direct') == true) {
        _dirty = true;
      }
    }, onError: (_) {});
  }

  /// Number of identity rebuilds so far (performance tests).
  int debugBuilds = 0;

  OwnRemoteIdentity get identity {
    final current = _identity;
    if (current != null &&
        !_dirty &&
        _roomCount == client.rooms.length &&
        _userId == client.userID) {
      return current;
    }
    _dirty = false;
    _roomCount = client.rooms.length;
    _userId = client.userID;
    debugBuilds++;
    try {
      return _identity = _build();
    } catch (e) {
      Logs().w('Own sender identity unavailable (${e.runtimeType})');
      return _identity = OwnRemoteIdentity.accountOnly(client.userID);
    }
  }

  /// Any evidence; layer-2/3 ghosts count only in [roomId]. For previews and
  /// "outgoing" labels, never for notification suppression.
  bool isOwnSender(String senderId, {String? roomId}) =>
      senderId == client.userID || identity.isOwn(senderId, roomId: roomId);

  bool isOwnEvent(Event event) =>
      isOwnSender(event.senderId, roomId: event.room.id);

  /// The account or a receiver-proved (layer 1) own ghost. Use this, not
  /// [isOwnSender], before suppressing a notification or a mention.
  bool isStronglyOwnSender(String senderId) =>
      senderId == client.userID || identity.isStronglyOwn(senderId);

  bool isStronglyOwnEvent(Event event) => isStronglyOwnSender(event.senderId);

  OwnRemoteIdentity _build() {
    final rooms = <BridgeRoomSnapshot>[];
    for (final room in client.rooms) {
      final snapshot = bridgeRoomSnapshot(room);
      if (snapshot != null) rooms.add(snapshot);
    }
    return OwnRemoteIdentity.resolve(
      accountUserId: client.userID,
      rooms: rooms,
      displaynameOf: (id) {
        for (final room in client.rooms) {
          if (room.membership != Membership.join) continue;
          final content = room.getState(EventTypes.RoomMember, id)?.content;
          if (content?['membership'] != 'join') continue;
          final name = content?['displayname'];
          if (name is String && name.trim().isNotEmpty) return name;
        }
        return null;
      },
    );
  }

  @visibleForTesting
  void dispose() {
    _stateSub?.cancel();
    _syncSub?.cancel();
    _resolvers[client] = null;
  }
}

/// Converts loaded state of one room; null for spaces, rooms the owner has
/// not joined and rooms without bridge state. Each declaration carries its
/// sender and whether the declared bot is joined (checked in personal_core).
/// Members are only collected for small DM-shaped rooms.
BridgeRoomSnapshot? bridgeRoomSnapshot(Room room) {
  if (room.isSpace || room.membership != Membership.join) return null;
  bool joined(String userId) =>
      room.getState(EventTypes.RoomMember, userId)?.content['membership'] ==
      'join';
  final bridges = <BridgeInfoSnapshot>[];
  for (final type in ownIdentityBridgeStateTypes) {
    for (final state in room.states[type]?.values ?? <StrippedStateEvent>[]) {
      final info = BridgeInfoSnapshot.fromContent(
        state.content,
        senderId: state.senderId,
        isJoined: joined,
      );
      if (info != null) bridges.add(info);
    }
  }
  if (bridges.isEmpty) return null;
  final shape = BridgeRoomSnapshot(
    roomId: room.id,
    bridges: bridges,
    ownerJoined: true,
    directPartnerId: room.directChatMatrixID,
  );
  if (!shape.dmShaped) return shape;
  final memberStates = room.states[EventTypes.RoomMember];
  if (memberStates == null || memberStates.length > 12) return shape;
  final members = <String, String?>{};
  for (final entry in memberStates.entries) {
    final content = entry.value.content;
    if (content['membership'] != 'join') continue;
    final name = content['displayname'];
    members[entry.key] = name is String ? name : null;
  }
  return BridgeRoomSnapshot(
    roomId: room.id,
    bridges: bridges,
    ownerJoined: true,
    directPartnerId: shape.directPartnerId,
    joinedMembers: members,
  );
}

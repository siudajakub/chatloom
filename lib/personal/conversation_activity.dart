// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/bridged_room.dart';
import 'package:chatloom/personal/conversation_classification.dart';
import 'package:chatloom/personal/own_sender.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

class ConversationTypingUser {
  final Room room;
  final User user;
  const ConversationTypingUser(this.room, this.user);
}

/// An observed status for one source, never a combined cross-network status.
class ConversationPresence {
  final Room room;
  final User user;
  final PresenceType presence;
  final bool online;
  final DateTime? lastActive;
  const ConversationPresence({
    required this.room,
    required this.user,
    required this.presence,
    required this.online,
    required this.lastActive,
  });
}

/// Receives activity through the existing sync loop. It never queries presence
/// or sends typing/presence, and owns only one-shot expiry timers.
///
/// Persisted/cache-only online values have no receipt timestamp in the SDK,
/// so only live observations may claim online. Bridged ghosts need explicit
/// remote provenance: generic Matrix puppet presence is insufficient.
class ConversationActivity extends ChangeNotifier {
  ConversationActivity({
    required this.client,
    required Iterable<Room> rooms,
    DateTime Function()? now,
    this.onlineFreshness = const Duration(minutes: 5),
    bool Function(Room)? presenceAllowed,
  }) : _now = now ?? DateTime.now,
       _presenceAllowed = presenceAllowed {
    setRooms(rooms);
  }

  final Client client;
  final DateTime Function() _now;
  final Duration onlineFreshness;
  final bool Function(Room)? _presenceAllowed;
  List<Room> _rooms = const [];
  final _typingUntil = <String, DateTime>{};
  final _seen = <String, (CachedPresence, DateTime)>{};
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Timer? _expiry;
  bool _failed = false;

  void setRooms(Iterable<Room> rooms) {
    final next = <String, Room>{
      for (final room in rooms)
        if (identical(room.client, client)) room.id: room,
    }.values.toList();
    if (listEquals(_rooms, next)) return;
    _rooms = next;
    _typingUntil.removeWhere((id, _) => !_rooms.any((r) => r.id == id));
    if (hasListeners) {
      _seedTyping();
      _scheduleExpiry();
      notifyListeners();
    }
  }

  Set<String> _services(Room room) {
    final functional = room
        .getState('io.element.functional_members')
        ?.content['service_members'];
    return {
      for (final type in bridgeInfoStateTypes)
        for (final event in room.states[type]?.values ?? <StrippedStateEvent>[])
          if (event.content['bridgebot'] is String)
            event.content['bridgebot'] as String,
      if (functional is List) ...functional.whereType<String>(),
    };
  }

  bool _eligible(Room room, String id) =>
      !_services(room).contains(id) &&
      !OwnSenderResolver.of(client).isOwnSender(id, roomId: room.id) &&
      room.getState(EventTypes.RoomMember, id)?.content['membership'] == 'join';

  String? counterpartId(Room room) {
    if (!identical(room.client, client) ||
        room.membership != Membership.join ||
        room.isSpace)
      return null;
    final kind = ConversationClassifier(client.rooms).classify(room);
    if (kind.isGroup || kind.technical) return null;
    final direct = room.directChatMatrixID;
    if (direct != null && _eligible(room, direct)) return direct;
    final members = room.getParticipants([Membership.join, Membership.invite]);
    final joined = room.summary.mJoinedMemberCount;
    final invited = room.summary.mInvitedMemberCount;
    if (joined == null ||
        invited == null ||
        members.length != joined + invited) {
      return null;
    }
    final peers = members.where((u) => _eligible(room, u.id)).toList();
    return peers.length == 1 ? peers.single.id : null;
  }

  List<User> typingUsersFor(Room room) {
    if (!identical(room.client, client) ||
        room.membership != Membership.join ||
        !_rooms.contains(room))
      return const [];
    final until = _typingUntil[room.id];
    if (_failed || until == null || !_now().isBefore(until)) return const [];
    final seen = <String>{};
    return _typingIds(room)
        .where(
          (id) =>
              !_services(room).contains(id) &&
              !OwnSenderResolver.of(client).isOwnSender(id, roomId: room.id) &&
              !{'leave', 'ban'}.contains(
                room.getState(EventTypes.RoomMember, id)?.content['membership'],
              ) &&
              seen.add(id),
        )
        .map(
          (id) =>
              room.getState(EventTypes.RoomMember, id)?.asUser(room) ??
              User(id, room: room),
        )
        .toList();
  }

  Iterable<String> _typingIds(Room room) {
    final ids = room.ephemerals['m.typing']?.content['user_ids'];
    return ids is List ? ids.whereType<String>() : const [];
  }

  bool typingFor(Room room) => typingUsersFor(room).isNotEmpty;

  List<ConversationTypingUser> get typing => [
    for (final room in _rooms)
      for (final user in typingUsersFor(room))
        ConversationTypingUser(room, user),
  ];

  List<ConversationPresence> get presences {
    final at = _now();
    return [
      for (final room in _rooms)
        ...() {
          if (!(_presenceAllowed?.call(room) ?? !isBridgedRoom(room))) {
            return <ConversationPresence>[];
          }
          final id = counterpartId(room);
          if (id == null) return <ConversationPresence>[];
          final live = _seen[id];
          // Reading this in-memory cache cannot perform a network request.
          // ignore: deprecated_member_use
          final value = live?.$1 ?? client.presences[id];
          if (value == null) return <ConversationPresence>[];
          final last = value.lastActiveTimestamp;
          final validLast = last != null && !last.isAfter(at) ? last : null;
          final online =
              !_failed &&
              live != null &&
              !live.$2.isAfter(at) &&
              at.difference(live.$2) < onlineFreshness &&
              value.presence == PresenceType.online;
          if (!online && validLast == null) return <ConversationPresence>[];
          return [
            ConversationPresence(
              room: room,
              user: room.unsafeGetUserFromMemoryOrFallback(id),
              presence: value.presence,
              online: online,
              lastActive: validLast,
            ),
          ];
        }(),
    ];
  }

  @override
  void addListener(VoidCallback listener) {
    final attach = !hasListeners;
    super.addListener(listener);
    if (attach) _attach();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) _detach();
  }

  void _seedTyping() {
    for (final room in _rooms) {
      if (_typingIds(room).isNotEmpty) {
        _typingUntil.putIfAbsent(
          room.id,
          () => _now().add(client.typingIndicatorTimeout),
        );
      }
    }
  }

  void _attach() {
    _failed = client.onSyncStatus.value?.status == SyncStatus.error;
    _seedTyping();
    _subscriptions.add(
      client.onPresenceChanged.stream.listen((value) {
        if (_rooms.any((r) => counterpartId(r) == value.userid)) {
          _seen[value.userid] = (value, _now());
          _changed();
        }
      }),
    );
    _subscriptions.add(
      client.onSync.stream.listen((sync) {
        var changed = false;
        for (final room in _rooms) {
          if (sync.rooms?.join?[room.id]?.ephemeral?.any(
                (e) => e.type == 'm.typing',
              ) ==
              true) {
            _typingUntil[room.id] = _now().add(client.typingIndicatorTimeout);
            changed = true;
          }
        }
        if (changed) _changed();
      }),
    );
    _subscriptions.add(
      client.onRoomState.stream.listen((update) {
        if (_rooms.any((r) => r.id == update.roomId)) _changed();
      }),
    );
    _subscriptions.add(
      client.onSyncStatus.stream.listen((update) {
        if (update.status == SyncStatus.error) {
          _failed = true;
          _typingUntil.clear();
          // Do not resurrect old online claims after reconnecting.
          _seen.clear();
          _changed();
        } else if (update.status == SyncStatus.finished && _failed) {
          _failed = false;
          _changed();
        }
      }),
    );
    _scheduleExpiry();
  }

  void _changed() {
    _scheduleExpiry();
    notifyListeners();
  }

  void _scheduleExpiry() {
    _expiry?.cancel();
    final now = _now();
    final deadlines = [
      ..._typingUntil.values,
      for (final observation in _seen.values)
        observation.$2.add(onlineFreshness),
    ].where((value) => value.isAfter(now)).toList()..sort();
    if (hasListeners && deadlines.isNotEmpty) {
      _expiry = Timer(deadlines.first.difference(now), _changed);
    }
  }

  void _detach() {
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    _subscriptions.clear();
    _expiry?.cancel();
    _expiry = null;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }
}

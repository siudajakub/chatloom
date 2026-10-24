// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/bridged_room.dart';
import 'package:chatloom/personal/conversation_classification.dart';
import 'package:chatloom/personal/own_sender.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

/// Session-only receipt times, shared by visible activity widgets. The account
/// owner pins this observer before sync; UI listeners otherwise retain it only
/// while visible. There are no timers, requests or persistent writes here.
class ConversationActivityReceipts {
  ConversationActivityReceipts._(this.client, this._now);
  static final _clients = Expando<ConversationActivityReceipts>(
    'activity receipts',
  );
  static ConversationActivityReceipts of(
    Client client, {
    DateTime Function()? now,
  }) => _clients[client] ??= ConversationActivityReceipts._(
    client,
    now ?? DateTime.now,
  );
  static void start(Client client) {
    final ledger = of(client);
    if (ledger._pinned) return;
    ledger._pinned = true;
    ledger.retain();
  }

  static void stop(Client client) {
    final ledger = _clients[client];
    if (ledger == null || !ledger._pinned) return;
    ledger._pinned = false;
    ledger.observed.clear();
    ledger._changes.add(null);
    ledger.release();
  }

  final Client client;
  final DateTime Function() _now;
  final observed = <String, (CachedPresence, DateTime)>{};
  final _changes = StreamController<String?>.broadcast();
  Stream<String?> get changes => _changes.stream;
  StreamSubscription<CachedPresence>? _presence;
  StreamSubscription<SyncStatusUpdate>? _status;
  int _owners = 0;
  bool _pinned = false;

  void retain() {
    if (_owners++ != 0) return;
    _presence = client.onPresenceChanged.stream.listen((value) {
      observed[value.userid] = (value, _now());
      _changes.add(value.userid);
    });
    _status = client.onSyncStatus.stream.listen((value) {
      if (value.status == SyncStatus.error) {
        observed.clear();
        _changes.add(null);
      }
    });
  }

  void release() {
    if (_owners == 0 || --_owners != 0) return;
    unawaited(_presence?.cancel());
    unawaited(_status?.cancel());
    _presence = null;
    _status = null;
    observed.clear();
  }

  /// Legacy user-profile surfaces may show native Matrix members too, but
  /// never a bridge ghost or an online value lacking a fresh session receipt.
  CachedPresence? safeNativePresence(
    String userId, {
    DateTime? now,
    Duration freshness = const Duration(minutes: 5),
  }) {
    var native = false;
    for (final room in client.rooms) {
      if (room.membership != Membership.join ||
          room.getState(EventTypes.RoomMember, userId)?.content['membership'] !=
              'join')
        continue;
      if (isBridgedRoom(room)) return null;
      native = true;
    }
    if (!native || userId == client.userID) return null;
    final at = now ?? _now();
    final live = observed[userId];
    // ignore: deprecated_member_use
    final value = live?.$1 ?? client.presences[userId];
    if (value == null) return null;
    final last = value.lastActiveTimestamp;
    if (last != null && (last.millisecondsSinceEpoch <= 0 || last.isAfter(at)))
      return null;
    final fresh =
        live != null &&
        !live.$2.isAfter(at) &&
        at.difference(live.$2) < freshness;
    if (!fresh && last == null) return null;
    final safe = CachedPresence.fromJson(value.toJson());
    if (!fresh) safe.presence = PresenceType.offline;
    if (!fresh || safe.presence != PresenceType.online) {
      safe.currentlyActive = false;
    }
    return safe;
  }
}

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
    _receipts = ConversationActivityReceipts.of(client, now: _now);
    setRooms(rooms);
  }

  final Client client;
  final DateTime Function() _now;
  final Duration onlineFreshness;
  final bool Function(Room)? _presenceAllowed;
  List<Room> _rooms = const [];
  final _typingUntil = <String, DateTime>{};
  final _typingEvents = <String, BasicEvent?>{};
  late final ConversationActivityReceipts _receipts;
  final _counterparts = <String, String>{};
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
    _refreshCounterparts();
    _typingUntil.removeWhere((id, _) => !_rooms.any((r) => r.id == id));
    _typingEvents.removeWhere((id, _) => !_rooms.any((r) => r.id == id));
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

  String? counterpartId(Room room) =>
      identical(room.client, client) ? _counterparts[room.id] : null;

  /// One classifier per client, shared by every row (BP-09): building one
  /// walks every room's bridge state, and each inbox row used to build its
  /// own on creation and on every relevant state event of any room. It is
  /// rebuilt when a bridge info or functional-members event arrives (once per
  /// event, not once per row) or when it does not cover a row's room.
  static final _sharedClassifier = Expando<ConversationClassifier>(
    'activity classifier',
  );
  static final _sharedStamp = Expando<Object>('activity classifier stamp');

  /// Classifiers built for counterparts (tests only).
  @visibleForTesting
  static int debugClassifierBuilds = 0;

  void _invalidateClassifier(Object stamp) {
    if (identical(_sharedStamp[client], stamp)) return;
    _sharedStamp[client] = stamp;
    _sharedClassifier[client] = null;
  }

  ConversationClassifier _classifier() {
    final shared = _sharedClassifier[client];
    if (shared != null && _rooms.every(shared.covers)) return shared;
    debugClassifierBuilds++;
    return _sharedClassifier[client] = ConversationClassifier(client.rooms);
  }

  bool _refreshScheduled = false;
  bool _refreshOwnRoom = false;

  /// Coalesces a burst of state events (a catch-up delivers full state for
  /// many rooms, a group a member burst) into one recompute.
  void _scheduleRefresh({required bool ownRoom}) {
    _refreshOwnRoom |= ownRoom;
    if (_refreshScheduled) return;
    _refreshScheduled = true;
    scheduleMicrotask(() {
      _refreshScheduled = false;
      final own = _refreshOwnRoom;
      _refreshOwnRoom = false;
      if (!hasListeners) return;
      final previous = Map<String, String>.of(_counterparts);
      _refreshCounterparts();
      if (own || !mapEquals(previous, _counterparts)) _changed();
    });
  }

  void _refreshCounterparts() {
    final classifier = _classifier();
    _counterparts.clear();
    for (final room in _rooms) {
      final id = _resolveCounterpart(room, classifier);
      if (id != null) _counterparts[room.id] = id;
    }
  }

  String? _resolveCounterpart(Room room, ConversationClassifier classifier) {
    if (!identical(room.client, client) ||
        room.membership != Membership.join ||
        room.isSpace) {
      return null;
    }
    final kind = classifier.classify(room);
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
        !_rooms.contains(room)) {
      return const [];
    }
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
          final live = _receipts.observed[id];
          // Reading this in-memory cache cannot perform a network request.
          // ignore: deprecated_member_use
          final value = live?.$1 ?? client.presences[id];
          if (value == null) return <ConversationPresence>[];
          final last = value.lastActiveTimestamp;
          final validLast =
              last != null &&
                  last.millisecondsSinceEpoch > 0 &&
                  !last.isAfter(at)
              ? last
              : null;
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
      final event = room.ephemerals['m.typing'];
      if (!identical(_typingEvents[room.id], event)) {
        _typingEvents[room.id] = event;
        if (_typingIds(room).isNotEmpty) {
          _typingUntil[room.id] = _now().add(client.typingIndicatorTimeout);
        } else {
          _typingUntil.remove(room.id);
        }
      }
    }
  }

  void _attach() {
    _failed = client.onSyncStatus.value?.status == SyncStatus.error;
    _seedTyping();
    _receipts.retain();
    _subscriptions.add(
      _receipts.changes.listen((userId) {
        if (userId == null || _counterparts.containsValue(userId)) {
          _changed();
        }
      }),
    );
    _subscriptions.add(
      client.onSync.stream.listen((sync) {
        var changed = false;
        if (sync.accountData?.any((event) => event.type == 'm.direct') ==
            true) {
          _refreshCounterparts();
          changed = true;
        }
        for (final room in _rooms) {
          if (sync.rooms?.join?[room.id]?.ephemeral?.any(
                (e) => e.type == 'm.typing',
              ) ==
              true) {
            _typingUntil[room.id] = _now().add(client.typingIndicatorTimeout);
            _typingEvents[room.id] = room.ephemerals['m.typing'];
            changed = true;
          }
        }
        if (changed) _changed();
      }),
    );
    _subscriptions.add(
      client.onRoomState.stream.listen((update) {
        final ownRoom = _rooms.any((r) => r.id == update.roomId);
        final type = update.state.type;
        if (!ownRoom &&
            !bridgeInfoStateTypes.contains(type) &&
            type != 'io.element.functional_members')
          return;
        if (ownRoom &&
            !bridgeInfoStateTypes.contains(type) &&
            !{
              EventTypes.RoomMember,
              EventTypes.RoomCreate,
              'com.beeper.room_features',
              'io.element.functional_members',
            }.contains(type))
          return;
        if (bridgeInfoStateTypes.contains(type) ||
            type == 'io.element.functional_members') {
          _invalidateClassifier(update.state);
        }
        _scheduleRefresh(ownRoom: ownRoom);
      }),
    );
    _subscriptions.add(
      client.onSyncStatus.stream.listen((update) {
        if (update.status == SyncStatus.error) {
          _failed = true;
          _typingUntil.clear();
          // Do not resurrect old online claims after reconnecting.
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
      for (final id in _counterparts.values)
        if (_receipts.observed[id] case final observation?)
          observation.$2.add(onlineFreshness),
    ].where((value) => value.isAfter(now)).toList()..sort();
    if (hasListeners && deadlines.isNotEmpty) {
      _expiry = Timer(deadlines.first.difference(now), _changed);
    }
  }

  void _detach() {
    if (_subscriptions.isNotEmpty) _receipts.release();
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

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/conversation_activity.dart';
import 'package:chatloom/personal/own_sender.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

const _owner = '@owner:example.invalid';
const _peer = '@peer:example.invalid';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Activity must never access database or network');
}

class _Client extends Client {
  _Client() : super('activity fixture', database: _NoDatabase());
  @override
  String get userID => _owner;
  final direct = <String, List<String>>{};
  @override
  Map<String, List<String>> get directChats => direct;
}

void _state(
  Room room,
  String type,
  Map<String, dynamic> content, {
  String key = '',
}) {
  room.setState(
    Event(
      room: room,
      type: type,
      stateKey: key,
      content: content,
      senderId: _owner,
      eventId: '\$fixture-$type-$key',
      originServerTs: DateTime.utc(2026),
    ),
  );
}

Room _dm(_Client client, String id) {
  final room = Room(
    id: id,
    client: client,
    summary: RoomSummary.fromJson({
      'm.joined_member_count': 2,
      'm.invited_member_count': 0,
    }),
  );
  client.rooms.add(room);
  client.direct[_peer] = [...?client.direct[_peer], id];
  for (final id in [_owner, _peer]) {
    _state(room, EventTypes.RoomMember, {'membership': 'join'}, key: id);
  }
  return room;
}

void main() {
  late _Client client;
  late Room room;
  late ConversationActivity activity;
  late DateTime now;
  var notifications = 0;
  void listener() {
    notifications++;
  }

  setUp(() {
    client = _Client();
    room = _dm(client, '!room:example.invalid');
    now = DateTime.utc(2026, 10, 23);
    activity = ConversationActivity(
      client: client,
      rooms: [room],
      now: () => now,
    );
    notifications = 0;
  });
  tearDown(() {
    activity.dispose();
    OwnSenderResolver.of(client).dispose();
  });

  testWidgets(
    'cached online is unknown; live online expires without fake offline',
    (tester) async {
      activity.addListener(listener);
      // ignore: deprecated_member_use
      client.presences[_peer] = CachedPresence(
        PresenceType.online,
        null,
        null,
        true,
        _peer,
      );
      expect(activity.presences, isEmpty);
      client.onPresenceChanged.add(
        CachedPresence(PresenceType.online, null, null, true, _peer),
      );
      await tester.pump();
      expect(activity.presences.single.online, isTrue);
      now = now.add(const Duration(minutes: 5));
      final before = notifications;
      await tester.pump(const Duration(minutes: 5));
      expect(activity.presences, isEmpty);
      expect(notifications, greaterThan(before));
    },
  );

  testWidgets(
    'last active is explicit, future timestamps rejected, bridge ghosts hidden',
    (tester) async {
      activity.addListener(listener);
      final value = CachedPresence(
        PresenceType.offline,
        null,
        null,
        false,
        _peer,
      )..lastActiveTimestamp = now.subtract(const Duration(hours: 1));
      client.onPresenceChanged.add(value);
      await tester.pump();
      expect(activity.presences.single.lastActive, value.lastActiveTimestamp);
      value.lastActiveTimestamp = now.add(const Duration(seconds: 1));
      expect(activity.presences, isEmpty);
      value.lastActiveTimestamp = now;
      _state(room, 'm.bridge', {
        'protocol': {'id': 'telegram'},
      });
      expect(activity.presences, isEmpty);
      activity.removeListener(listener);
    },
  );

  testWidgets('typing expires and filters owner and declared service members', (
    tester,
  ) async {
    activity.addListener(listener);
    const bot = '@bot:example.invalid';
    _state(room, 'io.element.functional_members', {
      'service_members': [bot],
    });
    final event = BasicEvent(
      type: 'm.typing',
      content: {
        'user_ids': [_owner, _peer, bot, _peer],
      },
    );
    room.ephemerals['m.typing'] = event;
    client.onSync.add(
      SyncUpdate(
        nextBatch: 'fixture',
        rooms: RoomsUpdate(
          join: {
            room.id: JoinedRoomUpdate(ephemeral: [event]),
          },
        ),
      ),
    );
    await tester.pump();
    expect(activity.typing.map((e) => e.user.id), [_peer]);
    now = now.add(client.typingIndicatorTimeout);
    final before = notifications;
    await tester.pump(client.typingIndicatorTimeout);
    expect(activity.typing, isEmpty);
    expect(notifications, greaterThan(before));
  });

  testWidgets(
    'disconnect invalidates online and typing; reconnect cannot resurrect them',
    (tester) async {
      activity.addListener(listener);
      client.onPresenceChanged.add(
        CachedPresence(PresenceType.online, null, null, true, _peer),
      );
      await tester.pump();
      expect(activity.presences.single.online, isTrue);
      client.onSyncStatus.add(const SyncStatusUpdate(SyncStatus.error));
      await tester.pump();
      expect(activity.presences, isEmpty);
      client.onSyncStatus.add(const SyncStatusUpdate(SyncStatus.finished));
      await tester.pump();
      expect(activity.presences, isEmpty);
    },
  );

  test('rooms from another client and non-DM presence are excluded', () {
    final other = _Client();
    final otherRoom = _dm(other, '!other:example.invalid');
    activity.setRooms([otherRoom]);
    expect(activity.counterpartId(otherRoom), isNull);
    expect(activity.typing, isEmpty);
    client.direct.clear();
    activity.setRooms([room]);
    _state(room, EventTypes.RoomMember, {
      'membership': 'join',
    }, key: '@third:example.invalid');
    room.summary = RoomSummary.fromJson({
      'm.joined_member_count': 3,
      'm.invited_member_count': 0,
    });
    activity.setRooms([]);
    activity.setRooms([room]);
    expect(activity.counterpartId(room), isNull);
  });

  testWidgets('detached monitor receives no activity notifications', (
    tester,
  ) async {
    activity.addListener(listener);
    activity.removeListener(listener);
    client.onPresenceChanged.add(
      CachedPresence(PresenceType.online, null, null, true, _peer),
    );
    await tester.pump();
    expect(notifications, 0);
    expect(activity.presences, isEmpty);
  });

  testWidgets(
    'session receipt preceding the view is shared across activity models',
    (tester) async {
      final receipts = ConversationActivityReceipts.of(client, now: () => now);
      receipts.retain();
      client.onPresenceChanged.add(
        CachedPresence(PresenceType.online, null, null, true, _peer),
      );
      await tester.pump();
      activity.addListener(listener);
      expect(activity.presences.single.online, isTrue);
      final second = ConversationActivity(
        client: client,
        rooms: [room],
        now: () => now,
      );
      second.addListener(listener);
      expect(second.presences.single.online, isTrue);
      activity.removeListener(listener);
      expect(second.presences.single.online, isTrue);
      second.dispose();
      receipts.release();
    },
  );

  testWidgets(
    'm.direct changes invalidate counterpart without unrelated presence traffic',
    (tester) async {
      activity.addListener(listener);
      expect(activity.counterpartId(room), _peer);
      client.direct.clear();
      _state(room, EventTypes.RoomMember, {
        'membership': 'join',
      }, key: '@third:example.invalid');
      room.summary = RoomSummary.fromJson({
        'm.joined_member_count': 3,
        'm.invited_member_count': 0,
      });
      final before = notifications;
      client.onSync.add(
        SyncUpdate(
          nextBatch: 'direct-update',
          accountData: [BasicEvent(type: 'm.direct', content: {})],
        ),
      );
      await tester.pump();
      expect(activity.counterpartId(room), isNull);
      expect(notifications, greaterThan(before));
      activity.removeListener(listener);
    },
  );

  testWidgets(
    'legacy native presence rejects stale receipt and joined bridge ghost',
    (tester) async {
      final receipts = ConversationActivityReceipts.of(client, now: () => now);
      receipts.retain();
      client.onPresenceChanged.add(
        CachedPresence(PresenceType.online, null, null, true, _peer),
      );
      await tester.pump();
      expect(receipts.safeNativePresence(_peer)?.presence, PresenceType.online);
      now = now.add(const Duration(minutes: 5));
      expect(receipts.safeNativePresence(_peer), isNull);
      now = now.subtract(const Duration(minutes: 5));
      final portal = _dm(client, '!portal:example.invalid');
      _state(portal, 'm.bridge', {
        'protocol': {'id': 'telegram'},
      });
      expect(receipts.safeNativePresence(_peer), isNull);
      receipts.release();
    },
  );

  testWidgets(
    'reattach preserves old typing expiry and accepts a new ephemeral',
    (tester) async {
      room.ephemerals['m.typing'] = BasicEvent(
        type: 'm.typing',
        content: {
          'user_ids': [_peer],
        },
      );
      activity.addListener(listener);
      expect(activity.typing, hasLength(1));
      activity.removeListener(listener);
      now = now.add(client.typingIndicatorTimeout);
      activity.addListener(listener);
      expect(
        activity.typing,
        isEmpty,
        reason: 'same ephemeral cannot renew typing',
      );
      activity.removeListener(listener);
      room.ephemerals['m.typing'] = BasicEvent(
        type: 'm.typing',
        content: {
          'user_ids': [_peer],
        },
      );
      activity.addListener(listener);
      expect(
        activity.typing,
        hasLength(1),
        reason: 'a new event while detached starts a fresh deadline',
      );
      activity.removeListener(listener);
    },
  );

  testWidgets(
    'stale unavailable becomes last-active only; contradictory active is sanitized',
    (tester) async {
      final receipts = ConversationActivityReceipts.of(client, now: () => now);
      receipts.retain();
      final value = CachedPresence(
        PresenceType.unavailable,
        null,
        null,
        true,
        _peer,
      )..lastActiveTimestamp = now.subtract(const Duration(hours: 1));
      client.onPresenceChanged.add(value);
      await tester.pump();
      expect(receipts.safeNativePresence(_peer)?.currentlyActive, isFalse);
      expect(
        receipts.safeNativePresence(_peer)?.presence,
        PresenceType.unavailable,
      );
      now = now.add(const Duration(minutes: 5));
      final safe = receipts.safeNativePresence(_peer)!;
      expect(safe.presence, PresenceType.offline);
      expect(safe.currentlyActive, isFalse);
      expect(
        safe.lastActiveTimestamp!.isAtSameMomentAs(value.lastActiveTimestamp!),
        isTrue,
      );
      value.lastActiveTimestamp = null;
      expect(receipts.safeNativePresence(_peer), isNull);
      receipts.release();
    },
  );

  testWidgets('epoch and negative last-active timestamps are rejected', (
    tester,
  ) async {
    activity.addListener(listener);
    final receipts = ConversationActivityReceipts.of(client);
    for (final millis in [0, -1]) {
      client.onPresenceChanged.add(
        CachedPresence(PresenceType.offline, null, null, false, _peer)
          ..lastActiveTimestamp = DateTime.fromMillisecondsSinceEpoch(millis),
      );
      await tester.pump();
      expect(activity.presences, isEmpty);
      expect(receipts.safeNativePresence(_peer), isNull);
    }
    activity.removeListener(listener);
  });

  testWidgets('a member burst in a group costs no classifier per event and '
      'rows share one classifier; a DM partner change still updates (BP-09)', (
    tester,
  ) async {
    final group = Room(
      id: '!group:example.invalid',
      client: client,
      summary: RoomSummary.fromJson({
        'm.joined_member_count': 2,
        'm.invited_member_count': 0,
      }),
    );
    client.rooms.add(group);
    final rows = [
      for (var i = 0; i < 10; i++)
        ConversationActivity(client: client, rooms: [group], now: () => now),
    ];
    for (final row in rows) {
      row.addListener(listener);
    }
    activity.addListener(listener);
    await tester.pump();
    final builds = ConversationActivity.debugClassifierBuilds;
    for (var i = 0; i < 100; i++) {
      _state(group, EventTypes.RoomMember, {
        'membership': 'join',
      }, key: '@member$i:example.invalid');
    }
    await tester.pump();
    expect(
      ConversationActivity.debugClassifierBuilds - builds,
      lessThanOrEqualTo(1),
      reason: 'rooms × rows × events used to build a classifier each time',
    );

    // A bridge info event anywhere rebuilds the shared classifier once.
    final before = ConversationActivity.debugClassifierBuilds;
    _state(group, 'm.bridge', {
      'bridgebot': '@bot:example.invalid',
      'protocol': {'id': 'telegram'},
    }, key: 'bridge');
    await tester.pump();
    expect(ConversationActivity.debugClassifierBuilds - before, 1);

    // The DM's partner still resolves after a membership change.
    expect(activity.counterpartId(room), _peer);
    _state(room, EventTypes.RoomMember, {'membership': 'leave'}, key: _peer);
    await tester.pump();
    expect(activity.counterpartId(room), isNull);

    for (final row in rows) {
      row.removeListener(listener);
      row.dispose();
    }
    activity.removeListener(listener);
  });
}

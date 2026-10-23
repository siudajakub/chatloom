// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/conversation_activity.dart';
import 'package:chatloom/personal/own_sender.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/matrix_api_lite/model/room_summary.dart';

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
}

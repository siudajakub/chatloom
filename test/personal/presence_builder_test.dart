// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/widgets/presence_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

const _peer = '@peer:example.invalid';

class _Database implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Presence display must not query database');
}

class _Client extends Client {
  _Client(super.clientName) : super(database: _Database()) {
    final room = Room(id: '!native:example.invalid', client: this);
    rooms.add(room);
    room.setState(
      Event(
        room: room,
        type: EventTypes.RoomMember,
        stateKey: _peer,
        senderId: _peer,
        eventId: r'$fixture',
        originServerTs: DateTime.utc(2026),
        content: {'membership': 'join'},
      ),
    );
  }
  @override
  String get userID => '@owner:example.invalid';

  @override
  Future<CachedPresence> fetchCurrentPresence(
    String userId, {
    bool fetchOnlyFromCached = false,
  }) => throw StateError('Presence display must not fetch');
}

Widget _host(Client client, String userId) => MaterialApp(
  home: PresenceBuilder(
    client: client,
    userId: userId,
    builder: (_, presence) => Text(
      presence == null
          ? 'unknown'
          : '${presence.userid}:${presence.presence.name}',
    ),
  ),
);

void main() {
  testWidgets('profile ignores cached online and receives live sync', (
    tester,
  ) async {
    final client = _Client('presence-cache');
    // ignore: deprecated_member_use
    client.presences[_peer] = CachedPresence(
      PresenceType.online,
      null,
      null,
      true,
      _peer,
    );
    await tester.pumpWidget(_host(client, _peer));
    expect(find.text('unknown'), findsOneWidget);
    client.onPresenceChanged.add(
      CachedPresence(PresenceType.online, null, null, true, _peer),
    );
    await tester.pumpAndSettle();
    expect(find.text('$_peer:online'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('recycled profile rebinds account and ignores old events', (
    tester,
  ) async {
    final first = _Client('presence-first');
    final second = _Client('presence-second');
    await tester.pumpWidget(_host(first, _peer));
    first.onPresenceChanged.add(
      CachedPresence(PresenceType.online, null, null, true, _peer),
    );
    await tester.pumpAndSettle();
    expect(find.text('$_peer:online'), findsOneWidget);
    await tester.pumpWidget(_host(second, _peer));
    expect(find.text('unknown'), findsOneWidget);
    second.onPresenceChanged.add(
      CachedPresence(PresenceType.unavailable, 10000, null, false, _peer),
    );
    first.onPresenceChanged.add(
      CachedPresence(PresenceType.online, null, null, true, _peer),
    );
    await tester.pumpAndSettle();
    expect(find.text('$_peer:unavailable'), findsOneWidget);
    await tester.pumpWidget(_host(second, '@next:example.invalid'));
    expect(find.text('unknown'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    second.onPresenceChanged.add(
      CachedPresence(PresenceType.online, null, null, true, _peer),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile suppresses bridge ghosts and reacts to disconnect', (
    tester,
  ) async {
    final client = _Client('presence-bridge');
    await tester.pumpWidget(_host(client, _peer));
    client.onPresenceChanged.add(
      CachedPresence(PresenceType.online, null, null, true, _peer),
    );
    await tester.pumpAndSettle();
    expect(find.text('$_peer:online'), findsOneWidget);
    client.onSyncStatus.add(const SyncStatusUpdate(SyncStatus.error));
    await tester.pumpAndSettle();
    expect(find.text('unknown'), findsOneWidget);
    final room = client.rooms.single;
    room.setState(
      Event(
        room: room,
        type: 'm.bridge',
        stateKey: '',
        senderId: client.userID,
        eventId: r'$bridge',
        originServerTs: DateTime.utc(2026),
        content: {
          'protocol': {'id': 'telegram'},
        },
      ),
    );
    client.onPresenceChanged.add(
      CachedPresence(PresenceType.online, null, null, true, _peer),
    );
    await tester.pumpAndSettle();
    expect(find.text('unknown'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Usernames and numbers of the people of one-to-one chats, read from local
// member state for the search. Synthetic rooms; nothing is fetched.
import 'package:chatloom/personal/bridge_contact_search.dart';
import 'package:chatloom/personal/chat_handles.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

const _owner = '@owner:example.invalid';
const _bot = '@sh-instagrambot:beeper.local';
const _peer = '@sh-instagram_1:beeper.local';
const _groupMember = '@sh-instagram_2:beeper.local';

/// Every store access fails, as a closed store would.
class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

/// A store that knows one member event.
class _Store implements DatabaseApi {
  _Store(this.users);
  final Map<String, Map<String, Object?>> users;
  final reads = <String>[];

  @override
  Future<User?> getUser(String userId, Room room) async {
    reads.add(userId);
    final content = users[userId];
    if (content == null) return null;
    return User(
      userId,
      room: room,
      displayName: content['displayname'] as String?,
      membership: 'join',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

class _Client extends Client {
  _Client([DatabaseApi? database])
    : super('synthetic handles', database: database ?? _NoDatabase());
  @override
  String get userID => _owner;
}

int _serial = 0;

void _state(
  Room room,
  String type,
  Map<String, dynamic> content, {
  String key = '',
}) => room.setState(
  Event(
    room: room,
    type: type,
    stateKey: key,
    content: content,
    eventId: '\$fixture-${_serial++}',
    senderId: _bot,
    originServerTs: DateTime.utc(2026),
  ),
);

void _member(Room room, String id, String name, [List<String>? identifiers]) =>
    _state(room, EventTypes.RoomMember, {
      'membership': 'join',
      'displayname': name,
      'com.beeper.bridge.identifiers': ?identifiers,
    }, key: id);

Room _room(
  Client client,
  String id, {
  required bool dm,
  Map<String, List<String>> members = const {},
  List<String> heroes = const [],
}) {
  final room = Room(
    id: id,
    client: client,
    membership: Membership.join,
    summary: RoomSummary.fromJson({
      'm.heroes': [_bot, ...heroes],
      'm.joined_member_count': members.length + 2,
      'm.invited_member_count': 0,
    }),
  );
  client.rooms.add(room);
  _state(room, 'm.bridge', {
    'bridgebot': _bot,
    'protocol': {'id': 'instagram'},
    'com.beeper.room_type.v2': dm ? 'dm' : 'group',
  }, key: 'fixture');
  _member(room, _owner, 'Me');
  _member(room, _bot, 'bridge bot');
  for (final entry in members.entries) {
    _member(room, entry.key, 'Fictional', entry.value);
  }
  return room;
}

String _instagram(Room _) => 'Instagram';

void main() {
  test('the other person of a one-to-one chat, cached until their member '
      'state changes', () {
    final client = _Client();
    final dm = _room(
      client,
      '!dm:example.invalid',
      dm: true,
      members: {
        _peer: ['instagram:fictional.one', 'slack-internal:U1'],
      },
    );
    final index = ChatHandleIndex();
    const expected = [
      SearchHandle(display: '@fictional.one', network: 'Instagram'),
    ];
    expect(index.handlesOf(dm, network: _instagram), expected);
    expect(index.handlesOf(dm, network: _instagram), expected);
    expect(index.computations, 1);

    // The bridge renamed the account: the new member event replaces it.
    _member(dm, _peer, 'Fictional', ['instagram:fictional.two']);
    expect(index.handlesOf(dm, network: _instagram), const [
      SearchHandle(display: '@fictional.two', network: 'Instagram'),
    ]);
    expect(index.computations, 2);
  });

  test('group members are never indexed', () {
    final client = _Client();
    final group = _room(
      client,
      '!group:example.invalid',
      dm: false,
      members: {
        _peer: ['instagram:fictional.one'],
        _groupMember: ['instagram:fictional.member'],
      },
    );
    expect(directPeerOf(group), isNull);
    expect(ChatHandleIndex().handlesOf(group, network: _instagram), isEmpty);
  });

  test('missing people are read from the store only, never fetched', () async {
    final store = _Store({
      _peer: {'displayname': 'Fictional'},
    });
    final client = _Client(store);
    // The SDK loads members lazily: the person is known from the room
    // summary but not in memory yet.
    final dm = _room(
      client,
      '!dm:example.invalid',
      dm: true,
      heroes: [_peer],
    );
    expect(directPeerOf(dm), _peer);
    expect(dm.getState(EventTypes.RoomMember, _peer), isNull);
    final group = _room(client, '!group:example.invalid', dm: false);

    expect(await ChatHandleIndex.loadMissingPeers([dm, group]), isTrue);
    expect(store.reads, [_peer]);
    expect(dm.getState(EventTypes.RoomMember, _peer), isNotNull);
    // Loaded people are not read again.
    expect(await ChatHandleIndex.loadMissingPeers([dm]), isFalse);
    expect(store.reads, [_peer]);
  });

  test('a failing store leaves the search by name', () async {
    final client = _Client();
    final dm = _room(
      client,
      '!dm:example.invalid',
      dm: true,
      heroes: [_peer],
    );
    expect(directPeerOf(dm), _peer);
    expect(await ChatHandleIndex.loadMissingPeers([dm]), isFalse);
    expect(ChatHandleIndex().handlesOf(dm, network: _instagram), isEmpty);
  });
}

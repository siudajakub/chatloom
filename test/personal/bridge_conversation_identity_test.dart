// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/personal/inbox_projection.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart'
    show ConversationRef, PersonGroup;

const _owner = '@owner:example.invalid';
const _bot = '@bridge:example.invalid';
const _person = '@person:example.invalid';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

class _Client extends Client {
  _Client() : super('synthetic identity', database: _NoDatabase());
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
      eventId: '\$fixture-$type-$key',
      senderId: _bot,
      originServerTs: DateTime.utc(2026),
    ),
  );
}

Room _room({
  String protocol = 'whatsapp',
  String eventType = 'm.bridge',
  String? title,
  String? kind,
  bool complete = true,
  List<String> heroes = const [_bot],
}) {
  final client = _Client();
  final room = Room(
    id: '!fixture:example.invalid',
    client: client,
    membership: Membership.join,
    summary: RoomSummary.fromJson({
      'm.heroes': heroes.toList(),
      'm.joined_member_count': complete ? 3 : 20,
      'm.invited_member_count': 0,
    }),
  );
  client.rooms.add(room);
  _state(room, eventType, {
    'bridgebot': _bot,
    'protocol': {'id': protocol},
    'channel': {'displayname': ?title},
    'com.beeper.room_type.v2': ?kind,
  }, key: 'fixture-bridge');
  for (final entry in {
    _owner: 'Me',
    _bot: '$protocol bridge bot',
    _person: 'Alicja',
  }.entries) {
    _state(room, EventTypes.RoomMember, {
      'membership': 'join',
      'displayname': entry.value,
      if (entry.key == _person) 'avatar_url': 'mxc://example.invalid/alice',
    }, key: entry.key);
  }
  return room;
}

void main() {
  for (final protocol in [
    'whatsapp',
    'instagram',
    'facebook',
    'messenger',
    'telegram',
    'slack',
    'signal',
    'discord',
    'imessage',
    'future-network',
  ]) {
    test('$protocol contact replaces bridge-only heroes without m.direct', () {
      final room = _room(protocol: protocol);
      expect(room.getLocalizedDisplayname(), 'Alicja');
      expect(room.isDirectChatForDisplay, isTrue);
      expect(room.isDirectChat, isFalse);
      expect(room.directChatMatrixIDForDisplay, _person);
      expect(room.avatar, Uri.parse('mxc://example.invalid/alice'));
      expect(room.summary.mHeroes, [_bot]);
    });
  }
  for (final type in ['m.bridge', 'uk.half-shot.bridge', 'com.beeper.bridge']) {
    test('$type channel title works before members load', () {
      final room = _room(
        eventType: type,
        title: 'Alicja',
        kind: 'dm',
        complete: false,
      );
      room.states.remove(EventTypes.RoomMember);
      expect(room.getLocalizedDisplayname(), 'Alicja');
      expect(room.isDirectChatForDisplay, isTrue);
    });
  }
  test('real room name and private nickname retain precedence', () {
    final room = _room(title: 'Bridge title');
    _state(room, EventTypes.RoomName, {'name': 'Custom room name'});
    expect(room.getLocalizedDisplayname(), 'Custom room name');
    final personal = PersonalClient.of(room.client);
    addTearDown(personal.dispose);
    personal.values['nickname:${room.id}'] = {'name': 'Private nickname'};
    final projection = InboxProjection(personal);
    expect(projection.displayName(room), 'Private nickname');
    expect(projection.rooms([room], query: 'private nickname'), [room]);
  });
  test('search and DM/group filters use corrected presentation', () {
    final room = _room();
    final personal = PersonalClient.of(room.client);
    addTearDown(personal.dispose);
    final projection = InboxProjection(personal);
    expect(projection.displayName(room), 'Alicja');
    expect(projection.rooms([room], query: 'alicja'), [room]);
    expect(projection.rooms([room], filter: InboxFilter.direct), [room]);
    expect(projection.rooms([room], filter: InboxFilter.groups), isEmpty);
  });
  test('legacy dm with two people stays a group', () {
    final room = _room(heroes: [_bot, _person, '@second:example.invalid']);
    _state(room, EventTypes.RoomMember, {
      'membership': 'join',
      'displayname': 'Bartek',
    }, key: '@second:example.invalid');
    room.summary.mJoinedMemberCount = 4;
    _state(room, 'm.bridge', {
      'bridgebot': _bot,
      'protocol': {'id': 'instagram'},
      'com.beeper.room_type': 'dm',
    }, key: 'fixture-bridge');
    expect(room.isDirectChatForDisplay, isFalse);
    expect(room.getLocalizedDisplayname(), contains('Alicja'));
    expect(room.getLocalizedDisplayname(), isNot(contains('bridge bot')));
  });
  for (final kind in ['group', 'group_dm', 'channel', 'space']) {
    test('$kind cannot collapse to one cached participant', () {
      final room = _room(kind: kind, complete: false);
      (room.client as _Client).direct[_person] = [room.id];
      expect(room.isDirectChatForDisplay, isFalse);
      expect(room.getLocalizedDisplayname(), 'Group with Alicja');
      expect(room.avatar, isNull);
    });
  }
  test('incomplete legacy group is never guessed to be a DM', () {
    final room = _room(complete: false);
    expect(room.isDirectChatForDisplay, isFalse);
    expect(room.getLocalizedDisplayname(), 'Group with Alicja');
  });
  test('functional service members are excluded', () {
    final room = _room(
      kind: 'dm',
      heroes: [_bot, '@helper:example.invalid', _person],
    );
    _state(room, 'io.element.functional_members', {
      'service_members': ['@helper:example.invalid', 42],
    });
    expect(room.getLocalizedDisplayname(), 'Alicja');
  });
  test('m.direct contact wins over bot heroes with incomplete state', () {
    final room = _room(complete: false);
    (room.client as _Client).direct[_person] = [room.id];
    expect(room.getLocalizedDisplayname(), 'Alicja');
  });
  test('channel avatar and room avatar take precedence', () {
    final room = _room();
    _state(room, 'm.bridge', {
      'bridgebot': _bot,
      'protocol': {'id': 'signal'},
      'channel': {'avatar_url': 'mxc://example.invalid/channel'},
    }, key: 'fixture-bridge');
    expect(room.avatar, Uri.parse('mxc://example.invalid/channel'));
    _state(room, EventTypes.RoomAvatar, {
      'url': 'mxc://example.invalid/custom',
    });
    expect(room.avatar, Uri.parse('mxc://example.invalid/custom'));
  });
  test('malformed bridge state does not crash ordinary Matrix naming', () {
    final room = _room(heroes: [_person]);
    _state(room, 'm.bridge', {
      'bridgebot': 42,
      'protocol': [],
      'channel': 'bad',
    }, key: 'fixture-bridge');
    expect(room.getLocalizedDisplayname(), 'Group with Alicja');
    expect(room.isDirectChatForDisplay, isFalse);
  });
  test('ordinary Matrix DM stays unchanged and heroes are not mutated', () {
    final room = _room(heroes: []);
    room.states.remove('m.bridge');
    (room.client as _Client).direct[_person] = [room.id];
    expect(room.getLocalizedDisplayname(), 'Alicja');
    expect(room.summary.mHeroes, isEmpty);
  });
  test('merged person avatar falls back to a source network with a photo', () {
    final client = _Client();
    Room source(String id, {String? avatar}) {
      final room = Room(id: id, client: client, membership: Membership.join);
      client.rooms.add(room);
      if (avatar != null) {
        _state(room, EventTypes.RoomAvatar, {'url': avatar});
      }
      return room;
    }

    final whatsapp = source('!whatsapp:example.invalid');
    source('!telegram:example.invalid', avatar: 'mxc://example.invalid/tg');
    final personal = PersonalClient.of(client);
    addTearDown(personal.dispose);
    final group = PersonGroup(
      id: 'alicja',
      name: 'Alicja',
      defaultRoomId: whatsapp.id,
      members: const [
        ConversationRef(accountId: _owner, roomId: '!whatsapp:example.invalid'),
        ConversationRef(accountId: _owner, roomId: '!telegram:example.invalid'),
      ],
    );
    final projection = InboxProjection(personal);
    expect(whatsapp.avatar, isNull);
    expect(
      projection.avatarForGroup(group),
      Uri.parse('mxc://example.invalid/tg'),
    );
    expect(projection.avatarFor(whatsapp), isNull);
  });
}

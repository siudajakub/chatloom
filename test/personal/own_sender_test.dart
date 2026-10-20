// SPDX-License-Identifier: AGPL-3.0-or-later
// Fictional offline fixtures; no account, storage or network.
//
// Own-ghost hardening: bridge declarations count only when sent by the joined
// bridge bot in a joined room, weak (DM-structure) evidence stays in its room
// and never suppresses a notification or a mention.
import 'package:chatloom/personal/notification_eligibility.dart';
import 'package:chatloom/personal/own_sender.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

const _owner = '@owner:example.invalid';
const _tgBot = '@telegrambot:bridge.invalid';
const _waBot = '@whatsappbot:bridge.invalid';
const _ownTg = '@telegram_100:bridge.invalid';
const _contactTg = '@telegram_200:bridge.invalid';
const _ownLid = '@whatsapp_lid-777:bridge.invalid';
const _mallory = '@mallory:example.invalid';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

class _Client extends Client {
  _Client() : super('own sender fixture', database: _NoDatabase());
  @override
  String get userID => _owner;
  @override
  Map<String, List<String>> get directChats => const {};
}

var _sequence = 0;

void _state(
  Room room,
  String type,
  Map<String, dynamic> content,
  String key, {
  required String sender,
}) => room.setState(
  Event(
    room: room,
    type: type,
    stateKey: key,
    content: content,
    eventId: '\$state-${_sequence++}',
    senderId: sender,
    originServerTs: DateTime.utc(2026),
  ),
);

Room _portal(
  _Client client,
  String id, {
  required String bot,
  required String protocol,
  required Map<String, dynamic> channel,
  required String type,
  Map<String, String> members = const {},
  String? bridgeSender,
  bool botJoined = true,
}) {
  final room = Room(id: id, client: client, membership: Membership.join);
  client.rooms.add(room);
  _state(
    room,
    'm.bridge',
    {
      'bridgebot': bot,
      'protocol': {'id': protocol},
      'channel': channel,
      'com.beeper.room_type.v2': type,
    },
    'fixture',
    sender: bridgeSender ?? bot,
  );
  for (final entry in {
    _owner: 'Owner',
    if (botJoined) bot: 'Bridge bot',
    ...members,
  }.entries) {
    _state(
      room,
      EventTypes.RoomMember,
      {'membership': 'join', 'displayname': entry.value},
      entry.key,
      sender: entry.key,
    );
  }
  return room;
}

Event _message(Room room, String sender, {bool mention = false}) => Event(
  room: room,
  eventId: '\$event-${_sequence++}',
  senderId: sender,
  type: EventTypes.Message,
  originServerTs: DateTime.utc(2026, 10, 18),
  content: {
    'msgtype': 'm.text',
    'body': 'Synthetic fixture',
    if (mention)
      'm.mentions': {
        'user_ids': [_owner],
      },
  },
);

void main() {
  late _Client client;
  setUp(() => client = _Client());
  tearDown(() => OwnSenderResolver.of(client).dispose());

  test('receiver ghost declared by the joined bot is strongly own', () async {
    final dm = _portal(
      client,
      '!tg-dm:example.invalid',
      bot: _tgBot,
      protocol: 'telegram',
      channel: {'id': '200', 'fi.mau.receiver': '100'},
      type: 'dm',
      members: {_contactTg: 'Anna', _ownTg: 'excellent P'},
    );
    final own = OwnSenderResolver.of(client);
    final ghostMessage = _message(dm, _ownTg);
    expect(own.isOwnEvent(ghostMessage), isTrue);
    expect(own.isStronglyOwnEvent(ghostMessage), isTrue);
    expect(own.isOwnEvent(_message(dm, _contactTg)), isFalse);
    expect(
      await personalNotificationEligible(
        ghostMessage,
        ConversationMetadata(entityId: 'fixture'),
      ),
      isFalse,
    );
  });

  test(
    'a room member declaring a bridge cannot mark a contact as own',
    () async {
      // The contact's real DM, bridged by the genuine bot.
      final dm = _portal(
        client,
        '!tg-dm:example.invalid',
        bot: _tgBot,
        protocol: 'telegram',
        channel: {'id': '200', 'fi.mau.receiver': '100'},
        type: 'dm',
        members: {_contactTg: 'Anna'},
      );
      // A room where somebody with state power claims the contact is "own".
      _portal(
        client,
        '!attacker:example.invalid',
        bot: _tgBot,
        protocol: 'telegram',
        channel: {'id': '-1001', 'fi.mau.receiver': '200'},
        type: 'group_dm',
        bridgeSender: _mallory,
        members: {_mallory: 'Mallory'},
      );
      final own = OwnSenderResolver.of(client);
      final contactMessage = _message(dm, _contactTg, mention: true);
      expect(own.isOwnEvent(contactMessage), isFalse);
      expect(own.identity.ownGhostIds, {_ownTg});
      expect(
        await personalNotificationEligible(
          contactMessage,
          ConversationMetadata(entityId: 'fixture'),
        ),
        isTrue,
      );
    },
  );

  test('a declaration whose bridge bot is not joined is ignored', () {
    final dm = _portal(
      client,
      '!stale:example.invalid',
      bot: _tgBot,
      protocol: 'telegram',
      channel: {'id': '200', 'fi.mau.receiver': '100'},
      type: 'dm',
      botJoined: false,
      members: {_contactTg: 'Anna', _ownTg: 'excellent P'},
    );
    final own = OwnSenderResolver.of(client);
    expect(own.isOwnEvent(_message(dm, _ownTg)), isFalse);
    expect(own.identity.ownGhostIds, isEmpty);
  });

  group('weak (DM-structure) evidence', () {
    late Room dmA, dmB, group;
    setUp(() {
      Room dm(String id, String partner) => _portal(
        client,
        id,
        bot: _waBot,
        protocol: 'whatsapp',
        channel: {'id': '$partner@s.whatsapp.net'},
        type: 'dm',
        members: {
          '@whatsapp_$partner:bridge.invalid': 'Partner $partner',
          _ownLid: 'Someone',
        },
      );
      dmA = dm('!wa-a:example.invalid', '48201');
      dmB = dm('!wa-b:example.invalid', '48202');
      group = _portal(
        client,
        '!wa-group:example.invalid',
        bot: _waBot,
        protocol: 'whatsapp',
        channel: {'id': '1203@g.us'},
        type: 'group_dm',
      );
    });

    test('labels previews only in the DMs it came from', () {
      final own = OwnSenderResolver.of(client);
      expect(
        own.identity.evidenceFor(_ownLid, roomId: dmA.id),
        OwnIdentityEvidence.dmStructure,
      );
      expect(own.isOwnEvent(_message(dmA, _ownLid)), isTrue);
      expect(own.isOwnEvent(_message(dmB, _ownLid)), isTrue);
      expect(own.isOwnEvent(_message(group, _ownLid)), isFalse);
      expect(own.isOwnSender(_ownLid), isFalse, reason: 'no room, no scope');
    });

    test('never suppresses a notification or a mention', () async {
      final own = OwnSenderResolver.of(client);
      final message = _message(dmA, _ownLid);
      expect(own.isStronglyOwnEvent(message), isFalse);
      expect(
        await personalNotificationEligible(
          message,
          ConversationMetadata(entityId: 'fixture'),
        ),
        isTrue,
      );
      expect(
        await personalNotificationEligible(
          _message(dmA, _ownLid, mention: true),
          ConversationMetadata(entityId: 'fixture'),
          notificationMode: PersonalNotificationMode.mentionsOnly,
        ),
        isTrue,
      );
    });
  });
}

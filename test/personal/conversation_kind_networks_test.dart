// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline and table-driven: the state each bridge writes into a portal room
// and where ChatLoom shows that room. Fixtures follow the bridge sources:
// mautrix-go bridgev2 v0.31/v0.32 (`Portal.getBridgeInfo`: v2 `dm` /
// `group_dm` / `space`, nothing for groups and channels; room creation sends
// `m.bridge`, `uk.half-shot.bridge`, `com.beeper.room_features` and
// `io.element.functional_members` as the bridge bot) and each connector's
// `chatinfo.go` (members per chat type). Fictional ids only; no account,
// store or network.
import 'package:chatloom/personal/conversation_classification.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart'
    show PersonGroup, personalRoomMarker, personalSchemaVersion;

const _owner = '@owner:example.invalid';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

/// Bridges mark DMs in `m.direct` only through double puppeting; many
/// fixtures here leave it empty on purpose.
class _Client extends Client {
  _Client() : super('synthetic conversation kinds', database: _NoDatabase());
  @override
  String get userID => _owner;
  final direct = <String, List<String>>{};
  @override
  Map<String, List<String>> get directChats => direct;
}

/// What the bridge declares in `com.beeper.room_type(.v2)`.
enum _Kind {
  /// `RoomTypeDM`: v2 `dm`, legacy `dm`.
  dm,

  /// `RoomTypeGroupDM`: v2 `group_dm`, legacy `dm`.
  groupDm,

  /// `RoomTypeDefault` (groups, channels, broadcasts): no key at all.
  undeclared,
}

class _Case {
  /// `protocol.id` = the bridge's `BeeperBridgeType`.
  final String protocol;
  final String name;
  final _Kind kind;

  /// Remote users other than the owner with a loaded join.
  final int contacts;

  /// The owner's own remote ghost is a member (note-to-self split members,
  /// or messages sent from the native app without double puppeting).
  final bool ownGhost;

  /// Listed in `m.direct` (bridgev2 marks DMs through the double puppet; a
  /// stale entry may point at a group).
  final bool direct;

  /// `m.joined_member_count` is larger than the loaded members.
  final bool lazyMembers;

  /// Child of a community / forum / workspace space.
  final bool spaceChild;
  final bool isGroup;
  const _Case(
    this.protocol,
    this.name,
    this.kind, {
    required this.contacts,
    required this.isGroup,
    this.ownGhost = false,
    this.direct = false,
    this.lazyMembers = false,
    this.spaceChild = false,
  });
  @override
  String toString() => '$protocol: $name';
}

const _cases = [
  // mautrix-telegram v26.10 (deployed fork): chatinfo.go getDMChatInfo /
  // wrapChatInfo.
  _Case('telegram', 'private chat', _Kind.dm, contacts: 1, isGroup: false),
  _Case(
    'telegram',
    'private chat in m.direct',
    _Kind.dm,
    contacts: 1,
    direct: true,
    isGroup: false,
  ),
  _Case('telegram', 'chat with a bot', _Kind.dm, contacts: 1, isGroup: false),
  // Own user twice in the member map = the owner's double puppet only.
  _Case('telegram', 'Saved Messages', _Kind.dm, contacts: 0, isGroup: false),
  _Case(
    'telegram',
    'basic group',
    _Kind.undeclared,
    contacts: 3,
    isGroup: true,
  ),
  // Regressions: one remote member next to owner and bot looked like a DM.
  _Case(
    'telegram',
    'basic group with one other member',
    _Kind.undeclared,
    contacts: 1,
    isGroup: true,
  ),
  _Case(
    'telegram',
    'broadcast channel (only the channel ghost is synced)',
    _Kind.undeclared,
    contacts: 1,
    isGroup: true,
  ),
  _Case(
    'telegram',
    'supergroup with hidden members, one sender synced',
    _Kind.undeclared,
    contacts: 1,
    isGroup: true,
  ),
  _Case(
    'telegram',
    'large supergroup, members lazily loaded',
    _Kind.undeclared,
    contacts: 1,
    lazyMembers: true,
    isGroup: true,
  ),
  _Case(
    'telegram',
    'forum topic',
    _Kind.undeclared,
    contacts: 1,
    spaceChild: true,
    isGroup: true,
  ),
  _Case(
    'telegram',
    'group with a stale m.direct entry',
    _Kind.undeclared,
    contacts: 1,
    direct: true,
    isGroup: true,
  ),
  _Case(
    'telegram',
    'group seen through the own ghost',
    _Kind.undeclared,
    contacts: 0,
    ownGhost: true,
    isGroup: true,
  ),
  // mautrix-whatsapp: wrapDMInfo / wrapGroupInfo / wrapStatusBroadcastInfo /
  // wrapNewsletterInfo (newsletter posts are sent by the bridge bot).
  _Case('whatsapp', 'private chat', _Kind.dm, contacts: 1, isGroup: false),
  _Case(
    'whatsapp',
    'chat with yourself',
    _Kind.dm,
    contacts: 0,
    ownGhost: true,
    isGroup: false,
  ),
  _Case(
    'whatsapp',
    'group with one other member',
    _Kind.undeclared,
    contacts: 1,
    isGroup: true,
  ),
  _Case(
    'whatsapp',
    'status broadcast with one poster',
    _Kind.undeclared,
    contacts: 1,
    isGroup: true,
  ),
  _Case(
    'whatsapp',
    'channel (newsletter)',
    _Kind.undeclared,
    contacts: 0,
    isGroup: true,
  ),
  _Case(
    'whatsapp',
    'community announcement group',
    _Kind.undeclared,
    contacts: 2,
    spaceChild: true,
    isGroup: true,
  ),
  // mautrix-meta, Messenger mode (protocol facebookgo).
  _Case(
    'facebookgo',
    'one-to-one thread',
    _Kind.dm,
    contacts: 1,
    isGroup: false,
  ),
  _Case(
    'facebookgo',
    'encrypted one-to-one thread',
    _Kind.dm,
    contacts: 1,
    direct: true,
    isGroup: false,
  ),
  _Case(
    'facebookgo',
    'group thread, one participant synced so far',
    _Kind.undeclared,
    contacts: 1,
    isGroup: true,
  ),
  _Case(
    'facebookgo',
    'encrypted group',
    _Kind.undeclared,
    contacts: 2,
    isGroup: true,
  ),
  // mautrix-meta, Instagram mode (protocol instagramgo).
  _Case('instagramgo', 'direct thread', _Kind.dm, contacts: 1, isGroup: false),
  _Case(
    'instagramgo',
    'group thread with one remaining user',
    _Kind.undeclared,
    contacts: 1,
    isGroup: true,
  ),
  // mautrix-signal.
  _Case('signal', 'private chat', _Kind.dm, contacts: 1, isGroup: false),
  _Case(
    'signal',
    'private chat before the contact ACI is known',
    _Kind.dm,
    contacts: 0,
    isGroup: false,
  ),
  _Case(
    'signal',
    'group v2 with one other member',
    _Kind.undeclared,
    contacts: 1,
    isGroup: true,
  ),
  // mautrix-slack (protocol slackgo).
  _Case('slackgo', 'direct message', _Kind.dm, contacts: 1, isGroup: false),
  _Case('slackgo', 'group DM', _Kind.groupDm, contacts: 2, isGroup: true),
  _Case(
    'slackgo',
    'channel with one other member',
    _Kind.undeclared,
    contacts: 1,
    spaceChild: true,
    isGroup: true,
  ),
  // mautrix-linkedin.
  _Case('linkedin', 'conversation', _Kind.dm, contacts: 1, isGroup: false),
  _Case(
    'linkedin',
    'group conversation with one other member',
    _Kind.undeclared,
    contacts: 1,
    isGroup: true,
  ),
];

String _botFor(String protocol) => '@sh-${protocol}bot:example.invalid';

void _setState(
  Room room,
  String type,
  Map<String, dynamic> content, {
  required String sender,
  String key = '',
}) => room.setState(
  Event(
    room: room,
    type: type,
    stateKey: key,
    content: content,
    senderId: sender,
    eventId: '\$fixture-${room.id}-$type-$key',
    originServerTs: DateTime.utc(2026, 10, 21),
  ),
);

/// A bridgev2 portal room as the bridge creates it.
Room _portal(
  _Client client,
  _Case c,
  int index, {
  bool roomFeatures = true,
  String? bot,
}) {
  bot ??= _botFor(c.protocol);
  final room = Room(
    id: '!portal-$index:example.invalid',
    client: client,
    membership: Membership.join,
  );
  client.rooms.add(room);
  void state(String type, Map<String, dynamic> content, {String key = ''}) =>
      _setState(room, type, content, sender: bot!, key: key);
  state(EventTypes.RoomCreate, {'creator': bot});
  const key = 'fixture-bridge-id';
  final info = <String, dynamic>{
    'bridgebot': bot,
    'creator': bot,
    'protocol': {'id': c.protocol, 'displayname': 'Fixture network'},
    'channel': {
      'id': 'fixture-chat-$index',
      'displayname': 'Fictional chat $index',
      'fi.mau.receiver': 'fixture-login',
    },
    if (c.kind == _Kind.dm) ...{
      'com.beeper.room_type': 'dm',
      'com.beeper.room_type.v2': 'dm',
    },
    if (c.kind == _Kind.groupDm) ...{
      'com.beeper.room_type': 'dm',
      'com.beeper.room_type.v2': 'group_dm',
    },
  };
  state('m.bridge', info, key: key);
  state('uk.half-shot.bridge', info, key: key);
  if (roomFeatures) {
    state('com.beeper.room_features', {'id': 'fixture-features'}, key: key);
  }
  state('io.element.functional_members', {
    'service_members': [bot],
  });
  if (c.kind != _Kind.dm) {
    state(EventTypes.RoomName, {'name': 'Fictional chat $index'});
  }
  if (c.spaceChild) {
    state(EventTypes.SpaceParent, {
      'via': ['example.invalid'],
    }, key: '!fixture-space:example.invalid');
  }
  final contacts = [
    for (var i = 0; i < c.contacts; i++)
      '@${c.protocol}_contact-$index-$i:example.invalid',
  ];
  final members = [
    _owner,
    bot,
    if (c.ownGhost) '@${c.protocol}_fixture-login:example.invalid',
    ...contacts,
  ];
  for (final member in members) {
    _setState(
      room,
      EventTypes.RoomMember,
      {'membership': 'join', 'displayname': 'Fictional member'},
      sender: member,
      key: member,
    );
  }
  room.summary
    ..mJoinedMemberCount = members.length + (c.lazyMembers ? 40 : 0)
    ..mInvitedMemberCount = 0
    ..mHeroes = members.where((id) => id != _owner).take(5).toList();
  if (c.direct) {
    final partner = contacts.isEmpty ? bot : contacts.first;
    client.direct[partner] = [...?client.direct[partner], room.id];
  }
  room.lastEvent = Event(
    room: room,
    type: EventTypes.Message,
    eventId: '\$last-$index',
    senderId: contacts.isEmpty ? bot : contacts.first,
    originServerTs: DateTime.utc(2026, 10, 21, 12, index % 60),
    content: {'msgtype': MessageTypes.Text, 'body': 'Fictional'},
  );
  return room;
}

/// A plain Matrix room (no bridge info) with the owner and [members]
/// (user id → membership). Each member event is sent by the member itself
/// unless [senders] names someone else; [extra] adds member event content.
/// Counts and heroes are left out unless given, as some servers do.
Room _matrixRoom(
  _Client client,
  String name, {
  Map<String, String> members = const {},
  Map<String, Map<String, dynamic>> extra = const {},
  Map<String, String> senders = const {},
  int? joined,
  int? invited,
  List<String>? heroes,
  Membership membership = Membership.join,
}) {
  final room = Room(
    id: '!$name:example.invalid',
    client: client,
    membership: membership,
  );
  client.rooms.add(room);
  final all = {_owner: membership.name, ...members};
  for (final MapEntry(key: user, value: state) in all.entries) {
    _setState(
      room,
      EventTypes.RoomMember,
      {'membership': state, ...?extra[user]},
      sender: senders[user] ?? user,
      key: user,
    );
  }
  room.summary
    ..mJoinedMemberCount = joined
    ..mInvitedMemberCount = invited
    ..mHeroes = heroes;
  return room;
}

Event _textFrom(Room room, String sender) => Event(
  room: room,
  type: EventTypes.Message,
  eventId: '\$text-${room.id}',
  senderId: sender,
  originServerTs: DateTime.utc(2026, 10, 21, 12),
  content: {'msgtype': MessageTypes.Text, 'body': 'Fictional'},
);

void main() {
  late _Client client;
  late PersonalClient personal;
  late Map<_Case, Room> rooms;

  setUp(() {
    client = _Client();
    rooms = {for (final (i, c) in _cases.indexed) c: _portal(client, c, i)};
    personal = PersonalClient.of(client);
  });
  tearDown(() => personal.dispose());

  group('every network: bridge declaration decides DM vs group', () {
    for (final c in _cases) {
      test('$c', () {
        final room = rooms[c]!;
        final kind = ConversationClassifier(client.rooms).classify(room);
        expect(kind.isGroup, c.isGroup, reason: 'classifier');
        expect(room.isDirectChatForDisplay, !c.isGroup, reason: 'SDK view');
        expect(kind.technical, isFalse, reason: 'portals are conversations');
        // LinkedIn has no canonical network (label) yet; it shows as Other.
        expect(
          kind.network,
          c.protocol == 'linkedin' ? 'other' : isNot(anyOf('matrix', 'other')),
        );
        if (c.isGroup) {
          expect(room.directChatMatrixIDForDisplay, isNull);
          expect(InboxProjection.mergeable(room), isFalse);
        }
      });
    }
  });

  test('Groups excludes Telegram by default while People keeps its DMs', () {
    final projection = InboxProjection(personal);
    final people = projection.rooms(client.rooms, filter: InboxFilter.direct);
    final groups = projection.rooms(client.rooms, filter: InboxFilter.groups);
    for (final c in _cases) {
      final room = rooms[c]!;
      expect(people.contains(room), !c.isGroup, reason: 'People: $c');
      expect(
        groups.contains(room),
        c.isGroup && c.protocol != 'telegram',
        reason: 'Groups: $c',
      );
    }
    expect(
      projection.rooms(client.rooms, filter: InboxFilter.technical),
      isEmpty,
    );
  });

  test('Groups visibility is independent of placement and notifications', () {
    final projection = InboxProjection(personal);
    final before = {
      for (final room in client.rooms)
        room.id: (
          projection.placementFor(room),
          projection.notificationModeFor(room),
        ),
    };
    // A legacy placement preference must still inherit the new default.
    personal.values['network-policy:telegram'] = {'groupPlacement': 'groups'};
    expect(
      projection
          .rooms(client.rooms, filter: InboxFilter.groups)
          .any(
            (room) =>
                projection.classifier.classify(room).network == 'telegram',
          ),
      isFalse,
    );
    personal.values['network-policy:telegram']!['showInGroups'] = true;
    final groups = projection.rooms(client.rooms, filter: InboxFilter.groups);
    for (final c in _cases) {
      final room = rooms[c]!;
      expect(groups.contains(room), c.isGroup, reason: '$c');
      expect((
        projection.placementFor(room),
        projection.notificationModeFor(room),
      ), before[room.id]);
    }
    personal.values['network-policy:whatsapp'] = {'showInGroups': false};
    final hidden = projection.rooms(client.rooms, filter: InboxFilter.groups);
    for (final c in _cases.where((c) => c.protocol == 'whatsapp')) {
      expect(hidden, isNot(contains(rooms[c])));
    }
  });

  test('main list: no Telegram group or channel; other networks keep their '
      'groups by default', () {
    final main = InboxProjection(personal).rooms(client.rooms);
    for (final c in _cases) {
      final expected = !c.isGroup || c.protocol != 'telegram';
      expect(main.contains(rooms[c]), expected, reason: '$c');
    }
    // The per-network rule still moves every group of a network.
    personal.values['network-policy:whatsapp'] = {'groupPlacement': 'groups'};
    final moved = InboxProjection(personal).rooms(client.rooms);
    for (final c in _cases.where((c) => c.protocol == 'whatsapp')) {
      expect(moved.contains(rooms[c]), !c.isGroup, reason: '$c');
    }
  });

  test('a pinned, previously misclassified Telegram channel keeps its pin', () {
    final channel =
        rooms[_cases.firstWhere(
          (c) => c.name.startsWith('broadcast channel'),
        )]!;
    final dm = rooms[_cases.first]!;
    personal.values['org:${channel.id}'] = {'pinOrder': 0};
    personal.values['org:${dm.id}'] = {'pinOrder': 1};
    final projection = InboxProjection(personal);
    expect(projection.metadataFor(channel).isPinned, isTrue);
    expect(
      projection.rooms(client.rooms, filter: InboxFilter.groups),
      isNot(contains(channel)),
      reason: 'pinning does not bypass the network visibility choice',
    );
    personal.values['network-policy:telegram'] = {'showInGroups': true};
    final groups = projection.rooms(client.rooms, filter: InboxFilter.groups);
    expect(groups.first, channel, reason: 'pinned first in Groups');
    final main = projection.rooms(client.rooms);
    // A pinned group also stays pinned on the main list.
    expect(main.first, channel, reason: 'pinned first on the main list');
    expect(main, contains(dm));
  });

  test('merges: bridged DMs merge, a reclassified group drops out but the '
      'saved person stays stored', () {
    Room of(String protocol, String name) =>
        rooms[_cases.firstWhere(
          (c) => c.protocol == protocol && c.name == name,
        )]!;
    final telegram = of('telegram', 'private chat');
    final whatsapp = of('whatsapp', 'private chat');
    final channel = of(
      'telegram',
      'broadcast channel (only the channel ghost is synced)',
    );
    expect(InboxProjection.mergeable(telegram), isTrue);
    expect(InboxProjection.mergeable(whatsapp), isTrue);
    personal.values['person:fixture-valid'] = PersonGroup(
      id: 'fixture-valid',
      name: 'Fictional person',
      defaultRoomId: telegram.id,
      members: [personal.ref(telegram), personal.ref(whatsapp)],
    ).toJson().cast<String, dynamic>();
    personal.values['person:fixture-stale'] = PersonGroup(
      id: 'fixture-stale',
      name: 'Fictional channel person',
      defaultRoomId: channel.id,
      members: [
        personal.ref(channel),
        personal.ref(of('signal', 'private chat')),
      ],
    ).toJson().cast<String, dynamic>();
    final projection = InboxProjection(personal);
    expect(projection.groupFor(telegram)?.id, 'fixture-valid');
    expect(projection.groupFor(whatsapp)?.id, 'fixture-valid');
    expect(projection.groupFor(channel), isNull);
    final main = projection.rooms(client.rooms);
    expect(main.where((r) => r == telegram || r == whatsapp), hasLength(1));
    expect(
      projection.rooms(client.rooms, filter: InboxFilter.groups),
      isNot(contains(channel)),
    );
    personal.values['network-policy:telegram'] = {'showInGroups': true};
    expect(
      projection.rooms(client.rooms, filter: InboxFilter.groups),
      contains(channel),
    );
    expect(personal.values, contains('person:fixture-stale'));
  });

  test('bridge management room (no bridge info) stays technical', () {
    final control = Room(
      id: '!control:example.invalid',
      client: client,
      membership: Membership.join,
    );
    client.rooms.add(control);
    const bot = '@sh-telegrambot:example.invalid';
    for (final member in [_owner, bot]) {
      _setState(
        control,
        EventTypes.RoomMember,
        {'membership': 'join'},
        sender: member,
        key: member,
      );
    }
    control.summary
      ..mJoinedMemberCount = 2
      ..mInvitedMemberCount = 0
      ..mHeroes = [bot];
    final kind = ConversationClassifier(client.rooms).classify(control);
    expect(kind.technical, isTrue);
    expect(
      InboxProjection(
        personal,
      ).rooms(client.rooms, filter: InboxFilter.technical),
      [control],
    );
  });

  group('Matrix rooms that are no conversation go to Technical', () {
    const person = '@x:matrix.org';

    ConversationClassification kind(Room room) =>
        ConversationClassifier(client.rooms).classify(room);

    /// Technical only, never on the main list or under Matrix.
    void expectTechnical(Room room) {
      final classification = kind(room);
      expect(classification.technical, isTrue);
      expect(classification.network, 'matrix');
      final projection = InboxProjection(personal);
      expect(
        projection.rooms(client.rooms, filter: InboxFilter.technical),
        contains(room),
      );
      expect(projection.rooms(client.rooms), isNot(contains(room)));
    }

    void expectChat(Room room) {
      final classification = kind(room);
      expect(classification.technical, isFalse);
      expect(classification.network, 'matrix');
      expect(InboxProjection(personal).rooms(client.rooms), contains(room));
    }

    test('DM with a Beeper bridge bot that bridges no loaded portal', () {
      for (final (i, bot) in [
        '@whatsappbot:beeper.local', // Beeper cloud bridge, replaced
        '@sh-signalbot:beeper.local', // self-hosted, no portal yet
      ].indexed) {
        final control = _matrixRoom(
          client,
          'control-$i',
          members: {bot: 'join'},
          joined: 2,
          invited: 0,
          heroes: [bot],
        );
        expectTechnical(control);
      }
    });

    test('a bot account elsewhere needs its own bridge-bot join', () {
      const bot = '@legacybot:example.invalid';
      final control = _matrixRoom(
        client,
        'flagged',
        members: {bot: 'join'},
        extra: {
          bot: {'com.beeper.bridge.is_bridge_bot': true},
        },
        joined: 2,
        invited: 0,
        heroes: [bot],
      );
      expectTechnical(control);
      // The flag on someone's member event sent by another, non-bot account.
      final forged = _matrixRoom(
        client,
        'forged-flag',
        members: {person: 'join'},
        extra: {
          person: {'com.beeper.bridge.is_bridge_bot': true},
        },
        senders: {person: '@mallory:example.invalid'},
        joined: 2,
        invited: 0,
        heroes: [person],
      );
      expectChat(forged);
      // A look-alike bot id outside Beeper's bridge server proves nothing.
      final lookalike = _matrixRoom(
        client,
        'lookalike',
        members: {'@whatsappbot:matrix.org': 'join'},
        joined: 2,
        invited: 0,
        heroes: ['@whatsappbot:matrix.org'],
      );
      expectChat(lookalike);
    });

    test('bot DM without member counts', () {
      const bot = '@sh-telegrambot:example.invalid'; // bridges the portals
      final control = _matrixRoom(
        client,
        'uncounted',
        members: {bot: 'join'},
        heroes: [bot],
      );
      client.direct[bot] = [control.id];
      expectTechnical(control);
      // A person among the heroes keeps it a chat. (Classifier only from
      // here: the person's member event is not loaded, and a display name
      // would ask the store for it.)
      final mixed = _matrixRoom(
        client,
        'uncounted-mixed',
        members: {bot: 'join'},
        heroes: [bot, person],
      );
      expect(kind(mixed).technical, isFalse);
      // So does a person as the m.direct partner.
      final partner = _matrixRoom(
        client,
        'uncounted-partner',
        members: {bot: 'join'},
        heroes: [bot],
      );
      client.direct[person] = [partner.id];
      expect(kind(partner).technical, isFalse);
    });

    test('a room the account is alone in with nothing to read', () {
      final empty = _matrixRoom(
        client,
        'orphan',
        members: {person: 'leave'},
        joined: 1,
        invited: 0,
        heroes: [],
      );
      expect(empty.lastEvent, isNull);
      expectTechnical(empty);
      // The other side's leave as the last event is no message either.
      final left = _matrixRoom(
        client,
        'orphan-left',
        members: {person: 'leave'},
        joined: 1,
        invited: 0,
        heroes: [person],
      );
      left.lastEvent = Event(
        room: left,
        type: EventTypes.RoomMember,
        stateKey: person,
        eventId: '\$leave',
        senderId: person,
        originServerTs: DateTime.utc(2026, 10, 21),
        content: {'membership': 'leave'},
      );
      expectTechnical(left);
      // A server that leaves out a zero invited count.
      final noInvitedCount = _matrixRoom(
        client,
        'orphan-joined-count-only',
        members: {person: 'leave'},
        joined: 1,
        heroes: [],
      );
      expectTechnical(noInvitedCount);
      // Without counts only members known to have left make it an orphan.
      final uncounted = _matrixRoom(
        client,
        'orphan-uncounted',
        members: {person: 'leave'},
        heroes: [person],
      );
      expectTechnical(uncounted);
      // A bare room (nothing loaded, no counts) proves nothing.
      final bare = _matrixRoom(client, 'bare');
      expectChat(bare);
    });

    test('an orphan with a message stays a Matrix chat', () {
      final room = _matrixRoom(
        client,
        'orphan-with-text',
        members: {person: 'leave'},
        joined: 1,
        invited: 0,
        heroes: [person],
      );
      final classifier = ConversationClassifier(client.rooms);
      expect(classifier.classify(room).technical, isTrue);
      room.lastEvent = _textFrom(room, person);
      // The memo notices the new last event.
      expect(classifier.classify(room).technical, isFalse);
      expectChat(room);
    });

    test('a person on Matrix stays a Matrix chat', () {
      final dm = _matrixRoom(
        client,
        'person',
        members: {person: 'join'},
        joined: 2,
        invited: 0,
        heroes: [person],
      );
      client.direct[person] = [dm.id];
      expectChat(dm);
      // A DM the account started, still waiting for the person to accept.
      final pending = _matrixRoom(
        client,
        'person-invited',
        members: {person: 'invite'},
        joined: 1,
        invited: 1,
        heroes: [person],
      );
      expectChat(pending);
      // Classifier only from here: the person's member event is not loaded
      // (lazy loading), and a display name would ask the store for it.
      // No message so far, but the counts still show the person.
      final lazy = _matrixRoom(
        client,
        'person-lazy',
        joined: 2,
        invited: 0,
        heroes: [person],
      );
      expect(kind(lazy).technical, isFalse);
      expect(kind(lazy).network, 'matrix');
      // A pending DM without counts and without the invite loaded.
      final pendingUncounted = _matrixRoom(
        client,
        'person-invited-uncounted',
        heroes: [person],
      );
      client.direct[person] = [dm.id, pendingUncounted.id];
      expect(kind(pendingUncounted).technical, isFalse);
    });

    test('invites, the journal and portals are never orphans', () {
      final invite = _matrixRoom(
        client,
        'invite',
        membership: Membership.invite,
      );
      expect(kind(invite).technical, isFalse);
      final journal = _matrixRoom(client, 'journal', joined: 1, invited: 0);
      _setState(journal, personalRoomMarker, {
        'schema': personalSchemaVersion,
      }, sender: _owner);
      expect(kind(journal).technical, isFalse);
      // A portal everyone else left, with no message, bridged by a Beeper
      // bot: still the network's conversation.
      final portal = _portal(
        client,
        const _Case(
          'whatsapp',
          'abandoned',
          _Kind.dm,
          contacts: 0,
          isGroup: false,
        ),
        900,
        bot: '@sh-whatsappbot:beeper.local',
      );
      portal.lastEvent = null;
      portal.summary
        ..mJoinedMemberCount = null
        ..mInvitedMemberCount = null;
      final classification = kind(portal);
      expect(classification.technical, isFalse);
      expect(classification.network, 'whatsapp');
      for (final c in _cases) {
        expect(kind(rooms[c]!).technical, isFalse, reason: '$c');
      }
    });
  });

  group('evidence that a bridge declares room kinds', () {
    const groupCase = _Case(
      'telegram',
      'group',
      _Kind.undeclared,
      contacts: 1,
      isGroup: true,
    );
    const dmCase = _Case(
      'telegram',
      'dm',
      _Kind.dm,
      contacts: 1,
      isGroup: false,
    );

    test('room features of a bridgev2 portal suffice on their own', () {
      final fresh = _Client();
      final group = _portal(fresh, groupCase, 0, bot: '@solo:example.invalid');
      expect(Room.bridgeBotsDeclaringRoomKinds(fresh), isEmpty);
      expect(group.isDirectChatForDisplay, isFalse);
    });

    test(
      'another room of the same bot suffices (legacy Go bridges, invites)',
      () {
        final fresh = _Client();
        const bot = '@discordbot:example.invalid';
        final group = _portal(
          fresh,
          groupCase,
          0,
          bot: bot,
          roomFeatures: false,
        );
        final classifier = ConversationClassifier(fresh.rooms);
        // Nothing declared yet: the legacy member heuristic still applies.
        expect(classifier.classify(group).isGroup, isFalse);
        _portal(fresh, dmCase, 1, bot: bot, roomFeatures: false);
        expect(Room.bridgeBotsDeclaringRoomKinds(fresh), {bot});
        // The memo notices, and the old classifier asks for a full rebuild.
        expect(classifier.covers(group), isFalse);
        expect(classifier.classify(group).isGroup, isTrue);
        expect(ConversationClassifier(fresh.rooms).covers(group), isTrue);
      },
    );

    test('a declaration from a non-bot member is no evidence', () {
      final fresh = _Client();
      const bot = '@legacybot:example.invalid';
      final group = _portal(fresh, groupCase, 0, bot: bot, roomFeatures: false);
      final forged = Room(
        id: '!forged:example.invalid',
        client: fresh,
        membership: Membership.join,
      );
      fresh.rooms.add(forged);
      _setState(
        forged,
        'm.bridge',
        {
          'bridgebot': bot,
          'protocol': {'id': 'telegram'},
          'com.beeper.room_type.v2': 'dm',
        },
        sender: '@someone:example.invalid',
        key: 'forged',
      );
      _setState(
        group,
        'com.beeper.room_features',
        {'id': 'forged'},
        sender: '@someone:example.invalid',
        key: 'fixture-bridge-id',
      );
      expect(Room.bridgeBotsDeclaringRoomKinds(fresh), isEmpty);
      expect(group.isDirectChatForDisplay, isTrue); // legacy heuristic
    });

    test('a bridge that never declares kinds keeps the member heuristic', () {
      final fresh = _Client();
      final legacy = _portal(
        fresh,
        groupCase,
        0,
        bot: '@legacybot:example.invalid',
        roomFeatures: false,
      );
      expect(legacy.isDirectChatForDisplay, isTrue);
      legacy.summary.mJoinedMemberCount = 30; // incomplete member list
      expect(legacy.isDirectChatForDisplay, isFalse);
    });
  });
}

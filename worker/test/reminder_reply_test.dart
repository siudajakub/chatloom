// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/matrix_transport.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/reminder_reply.dart';
import 'package:test/test.dart';

const own = '@self:example.invalid';
const ownGhost = '@telegram_100:bridge.invalid';
bool ownGhostOnly(String id) => id == ownGhost;
final since = DateTime.utc(2026, 10, 4, 12);

class NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Predicate fixture must not access storage');
}

final room = Room(
  id: '!fixture:example.invalid',
  client: Client('fixture-predicate', database: NoDatabase()),
);
int sequence = 0;
Event event({
  String sender = '@recipient:example.invalid',
  String type = EventTypes.Message,
  DateTime? at,
  bool edit = false,
  bool redacted = false,
  String msgtype = 'm.text',
  String? relType,
  bool inReplyTo = false,
}) => Event(
  eventId: '\$fixture-${sequence++}',
  room: room,
  senderId: sender,
  originServerTs: at ?? since.add(const Duration(seconds: 1)),
  type: type,
  content: {
    'msgtype': msgtype,
    'body': 'fixture',
    if (edit) 'm.relates_to': {'rel_type': 'm.replace', 'event_id': r'$old'},
    if (relType != null)
      'm.relates_to': {'rel_type': relType, 'event_id': r'$old'},
    if (inReplyTo)
      'm.relates_to': {
        'm.in_reply_to': {'event_id': r'$old'},
      },
  },
  unsigned: redacted
      ? {
          'redacted_because': {
            'event_id': r'$redaction',
            'type': 'm.room.redaction',
            'sender': own,
            'origin_server_ts': since.millisecondsSinceEpoch,
            'content': {},
          },
        }
      : null,
);

class History implements ReminderReplyHistory {
  final List<List<Event>> pages;
  int page = 0;
  int keyRequests = 0;
  bool gaps = false;
  bool stuck = false;
  bool databaseBoundary = false;
  History(this.pages);
  @override
  List<Event> get events =>
      pages.take(page + 1).expand((events) => events).toList();
  @override
  bool get canRequestHistory => page < pages.length - 1;
  @override
  bool get hasGaps => gaps;
  @override
  String get progressToken => '$page';
  @override
  Future<void> requestHistory() async {
    if (databaseBoundary) {
      databaseBoundary = false;
      return;
    }
    if (!stuck) page++;
  }

  @override
  void requestKeys() {
    keyRequests++;
  }
}

void main() {
  test(
    'received message and sticker count, own/edit/redaction/reaction/journal do not',
    () {
      expect(isRecipientReply(event(), own, since), isTrue);
      expect(
        isRecipientReply(event(type: EventTypes.Sticker), own, since),
        isTrue,
      );
      for (final excluded in [
        event(sender: own),
        event(edit: true),
        event(redacted: true),
        event(type: EventTypes.Reaction),
        event(type: personalEventType),
        event(at: since),
      ]) {
        expect(isRecipientReply(excluded, own, since), isFalse);
      }
    },
  );
  test(
    'pagination finds received response concealed by newer own burst',
    () async {
      final history = History([
        List.generate(
          30,
          (_) => event(sender: own, at: since.add(const Duration(minutes: 2))),
        ),
        [event(at: since.add(const Duration(minutes: 1)))],
        [event(sender: own, at: since)],
      ]);
      expect(await receivedReplySince(history, own, since), isTrue);
      expect(history.page, 1);
    },
  );
  test(
    'database exhaustion transition can be followed by server history',
    () async {
      final history = History([
        [event(sender: own)],
        [event()],
      ])..databaseBoundary = true;
      expect(await receivedReplySince(history, own, since), isTrue);
      expect(history.page, 1);
    },
  );
  test(
    'no reply only after continuous <=createdAt frontier, including equal timestamp',
    () async {
      final history = History([
        [event(sender: own)],
        [event(edit: true), event(redacted: true)],
        [event(at: since)],
      ]);
      expect(await receivedReplySince(history, own, since), isFalse);
      expect(history.page, 2);
    },
  );
  test(
    'missing recipient keys stay unresolved and request keys without false absence',
    () async {
      final history = History([
        [event(type: EventTypes.Encrypted), event(at: since)],
      ]);
      await expectLater(
        receivedReplySince(history, own, since),
        throwsA(
          isA<WorkerFailure>().having(
            (failure) => failure.code,
            'code',
            'waiting_keys',
          ),
        ),
      );
      expect(history.keyRequests, 1);
    },
  );
  test(
    'unavailable history and unresolved gaps do not mean no response',
    () async {
      final unavailable = History([
        [event(sender: own)],
      ]);
      await expectLater(
        receivedReplySince(unavailable, own, since),
        throwsA(
          isA<WorkerFailure>().having(
            (failure) => failure.code,
            'code',
            'history_unavailable',
          ),
        ),
      );
      final gap = History([
        [event(sender: own, at: since)],
      ])..gaps = true;
      await expectLater(
        receivedReplySince(gap, own, since),
        throwsA(isA<WorkerFailure>()),
      );
    },
  );
  test(
    'no pagination progress stays unresolved instead of infinite loop or false reminder',
    () async {
      final stuck = History([
        [event(sender: own)],
        [event(at: since)],
      ])..stuck = true;
      await expectLater(
        receivedReplySince(stuck, own, since),
        throwsA(isA<WorkerFailure>()),
      );
    },
  );
  test('own bridge ghost messages are never the recipient reply', () {
    final ghostMessage = event(sender: ownGhost);
    expect(isRecipientReply(ghostMessage, own, since), isTrue);
    expect(
      isRecipientReply(ghostMessage, own, since, isOwnSender: ownGhostOnly),
      isFalse,
    );
    expect(
      isRecipientReply(
        event(sender: ownGhost, type: EventTypes.Sticker),
        own,
        since,
        isOwnSender: ownGhostOnly,
      ),
      isFalse,
    );
    expect(
      isRecipientReply(event(), own, since, isOwnSender: ownGhostOnly),
      isTrue,
    );
  });

  test('a newer own-ghost burst does not hide or fake a reply', () async {
    final noReply = History([
      [event(sender: ownGhost), event(sender: ownGhost, at: since)],
    ]);
    expect(
      await receivedReplySince(noReply, own, since, isOwnSender: ownGhostOnly),
      isFalse,
    );
    final reply = History([
      [event(sender: ownGhost)],
      [event(at: since.add(const Duration(seconds: 2)))],
      [event(at: since)],
    ]);
    expect(
      await receivedReplySince(reply, own, since, isOwnSender: ownGhostOnly),
      isTrue,
    );
  });

  test('undecryptable own-ghost events do not wait for keys', () async {
    final history = History([
      [event(sender: ownGhost, type: EventTypes.Encrypted), event(at: since)],
    ]);
    expect(
      await receivedReplySince(history, own, since, isOwnSender: ownGhostOnly),
      isFalse,
    );
    expect(history.keyRequests, 0);
  });

  group('only real replies from the other party count', () {
    const bot = '@telegrambot:bridge.invalid';
    bool botOnly(String id) => id == bot;

    test('bot and bridge notices are not replies', () {
      expect(
        isRecipientReply(event(sender: bot), own, since, isBot: botOnly),
        isFalse,
      );
      expect(
        isRecipientReply(
          event(sender: bot, type: EventTypes.Sticker),
          own,
          since,
          isBot: botOnly,
        ),
        isFalse,
      );
      expect(isRecipientReply(event(msgtype: 'm.notice'), own, since), isFalse);
      // Without a bot predicate the same sender is an ordinary member.
      expect(isRecipientReply(event(sender: bot), own, since), isTrue);
    });

    test('reactions and edits are not replies, quoted replies are', () {
      expect(
        isRecipientReply(event(relType: 'm.annotation'), own, since),
        isFalse,
      );
      expect(
        isRecipientReply(event(relType: 'm.replace'), own, since),
        isFalse,
      );
      expect(isRecipientReply(event(inReplyTo: true), own, since), isTrue);
      expect(isRecipientReply(event(relType: 'm.thread'), own, since), isTrue);
      expect(isRecipientReply(event(msgtype: 'm.image'), own, since), isTrue);
    });

    test('only messages after the reminder was set count', () async {
      final history = History([
        [
          event(sender: own),
          event(at: since.subtract(const Duration(minutes: 1))),
        ],
      ]);
      expect(await receivedReplySince(history, own, since), isFalse);
    });

    test('a history of only bot notices and reactions is no reply', () async {
      final history = History([
        [
          event(sender: bot),
          event(msgtype: 'm.notice'),
          event(type: EventTypes.Reaction),
          event(relType: 'm.replace'),
          event(at: since),
        ],
      ]);
      expect(
        await receivedReplySince(history, own, since, isBot: botOnly),
        isFalse,
      );
    });

    test(
      'undecryptable reactions, edits and bot events do not wait for keys',
      () async {
        final history = History([
          [
            event(type: EventTypes.Encrypted, relType: 'm.annotation'),
            event(type: EventTypes.Encrypted, relType: 'm.replace'),
            event(type: EventTypes.Encrypted, sender: bot),
            event(at: since),
          ],
        ]);
        expect(
          await receivedReplySince(history, own, since, isBot: botOnly),
          isFalse,
        );
        expect(history.keyRequests, 0);
      },
    );

    test('an undecryptable quoted reply still waits for keys', () async {
      final history = History([
        [event(type: EventTypes.Encrypted, inReplyTo: true), event(at: since)],
      ]);
      await expectLater(
        receivedReplySince(history, own, since, isBot: botOnly),
        throwsA(
          isA<WorkerFailure>().having((f) => f.code, 'code', 'waiting_keys'),
        ),
      );
    });

    test('declared bridge bots of the room are the bot senders', () {
      final client = Client('fixture-bots', database: NoDatabase());
      final portal = Room(id: '!portal:example.invalid', client: client);
      expect(reminderBotSenders(portal), isEmpty);
      for (final (type, key, declared) in [
        ('m.bridge', 'a', bot),
        ('com.beeper.bridge', 'b', '@sh-whatsappbot:bridge.invalid'),
        ('uk.half-shot.bridge', 'c', ''),
      ]) {
        portal.setState(
          Event(
            eventId: '\$bridge-$key',
            room: portal,
            senderId: declared.isEmpty ? bot : declared,
            originServerTs: since,
            type: type,
            stateKey: key,
            content: {'bridgebot': declared},
          ),
        );
      }
      expect(reminderBotSenders(portal), {
        bot,
        '@sh-whatsappbot:bridge.invalid',
      });
    });
  });

  group('worker identity from room state', () {
    const bot = '@telegrambot:bridge.invalid';
    Room portal(
      Client client, {
      String sender = bot,
      bool botJoined = true,
      Membership membership = Membership.join,
    }) {
      final dm = Room(
        id: '!dm-${client.rooms.length}:example.invalid',
        client: client,
        membership: membership,
      );
      client.rooms.add(dm);
      dm.setState(
        Event(
          eventId: r'$bridge',
          room: dm,
          senderId: sender,
          originServerTs: since,
          type: 'm.bridge',
          stateKey: 'fixture',
          content: {
            'bridgebot': bot,
            'protocol': {'id': 'telegram'},
            'channel': {'id': '200', 'fi.mau.receiver': '100'},
            'com.beeper.room_type.v2': 'dm',
          },
        ),
      );
      if (botJoined) {
        dm.setState(
          Event(
            eventId: r'$bot-member',
            room: dm,
            senderId: bot,
            originServerTs: since,
            type: EventTypes.RoomMember,
            stateKey: bot,
            content: {'membership': 'join'},
          ),
        );
      }
      return dm;
    }

    test('recognises the receiver ghost declared by the joined bot', () {
      final client = Client('fixture-identity', database: NoDatabase());
      portal(client);
      final identity = ownRemoteIdentity(client);
      expect(identity.isOwn(ownGhost), isTrue);
      expect(identity.isStronglyOwn(ownGhost), isTrue);
      expect(identity.isOwn('@telegram_200:bridge.invalid'), isFalse);
    });

    test('ignores a declaration sent by somebody other than the bot', () {
      final client = Client('fixture-spoof', database: NoDatabase());
      portal(client, sender: '@mallory:example.invalid');
      expect(ownRemoteIdentity(client).isOwn(ownGhost), isFalse);
    });

    test('ignores a declaration whose bot is not joined', () {
      final client = Client('fixture-stale', database: NoDatabase());
      portal(client, botJoined: false);
      expect(ownRemoteIdentity(client).isOwn(ownGhost), isFalse);
    });

    test('ignores rooms the owner has not joined', () {
      final client = Client('fixture-invite', database: NoDatabase());
      portal(client, membership: Membership.invite);
      expect(ownRemoteIdentity(client).isOwn(ownGhost), isFalse);
    });
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
// Wave 5 push lane: one notification per merged person (FT-04), serialized
// notification updates (CC-22), read targets that are never a local echo
// (CC-12) and the quiet policy for bot chats (BR-10). Fictional offline
// fixtures only.
import 'dart:async';

import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/notification_eligibility.dart';
import 'package:chatloom/personal/notification_reply.dart';
import 'package:chatloom/personal/notification_threads.dart';
import 'package:chatloom/personal/read_targets.dart';
import 'package:chatloom/utils/notification_client_routing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

import '../notion/conversation_test_support.dart';

void main() {
  late ConversationClient client;
  late ConversationRoom whatsapp, telegram, other;
  late ConversationPersonal personal;
  late PersonGroup person;

  setUp(() {
    NotificationThreads.debugReset();
    client = ConversationClient();
    whatsapp = ConversationRoom(client, '!whatsapp:example.invalid');
    telegram = ConversationRoom(
      client,
      '!telegram:example.invalid',
      network: 'telegram',
    );
    other = ConversationRoom(client, '!other:example.invalid');
    personal = ConversationPersonal(client);
    person = PersonGroup(
      id: 'fictional-person',
      name: 'Fictional person',
      members: [personal.ref(whatsapp), personal.ref(telegram)],
      defaultRoomId: whatsapp.id,
    );
    personal.values['person:${person.id}'] = person
        .toJson()
        .cast<String, dynamic>();
  });

  tearDown(() => personal.dispose());

  group('one notification per merged person', () {
    test('both networks of a person share one id, thread and key; a single '
        'chat keeps its own', () {
      final projection = InboxProjection(personal);
      final a = notificationThreadOf(client.clientName, whatsapp, projection);
      final b = notificationThreadOf(client.clientName, telegram, projection);
      expect(a.group?.id, person.id);
      expect(a.id, b.id);
      expect(a.id, personNotificationId(client.clientName, person.id));
      expect(a.threadIdentifier, b.threadIdentifier);
      expect(a.roomId, whatsapp.id);
      expect(b.roomId, telegram.id);
      final single = notificationThreadOf(client.clientName, other, projection);
      expect(single.group, isNull);
      expect(single.id, messageNotificationId(client.clientName, other.id));
      expect(single.cancelIds, {single.id});
    });

    test('cancelling a person removes its shared notification and every '
        'per-network one posted before the merge', () {
      final thread = notificationThreadOf(
        client.clientName,
        telegram,
        InboxProjection(personal),
      );
      expect(thread.cancelIds, {
        personNotificationId(client.clientName, person.id),
        messageNotificationId(client.clientName, whatsapp.id),
        messageNotificationId(client.clientName, telegram.id),
      });
    });

    test('saved merges count for cleanup even when the merge is no longer '
        'valid, and an unloaded store falls back to the room ids', () {
      // A left source keeps the person merged (merge-person FT-01) ...
      whatsapp.membership = Membership.leave;
      expect(InboxProjection(personal).groupFor(telegram)?.id, person.id);
      // ... a joined source that is now a group chat does not (wave-3
      // group safety): the merge is invalid, its notification may still be
      // in the shade.
      whatsapp.membership = Membership.join;
      whatsapp.state('m.bridge', {
        'protocol': {'id': 'whatsapp'},
        'bridgebot': '@bridge:example.invalid',
        'com.beeper.room_type.v2': 'group',
      }, key: 'fixture');
      expect(InboxProjection(personal).groupFor(telegram), isNull);
      expect(
        notificationIdsForRooms(client.clientName, [
          telegram.id,
        ], personal: personal),
        {
          messageNotificationId(client.clientName, telegram.id),
          personNotificationId(client.clientName, person.id),
        },
      );
      expect(notificationIdsForRooms(client.clientName, [telegram.id]), {
        messageNotificationId(client.clientName, telegram.id),
      });
    });

    test('a person id never equals a room id of the same account', () {
      expect(
        personNotificationId(client.clientName, person.id),
        isNot(messageNotificationId(client.clientName, person.id)),
      );
    });

    test('a reply to a person goes where its composer would send: today the '
        'network of the notified message', () {
      expect(
        notificationReplyRoom(personal, telegram, eventId: r'$fictional'),
        same(telegram),
      );
      expect(
        notificationReplyRoom(personal, whatsapp, eventId: r'$fictional'),
        same(whatsapp),
      );
      expect(notificationReplyRoom(personal, other), same(other));
    });
  });

  group('serialized notification updates', () {
    test('updates of one notification run one at a time, in arrival order, '
        'and a failed one does not block the next', () async {
      final log = <String>[];
      final gate = Completer<void>();
      final first = NotificationThreads.serialize(1, () async {
        log.add('first start');
        await gate.future;
        log.add('first end');
        throw StateError('Synthetic show failure');
      });
      final second = NotificationThreads.serialize(1, () async {
        log.add('second');
        return 2;
      });
      final otherChat = NotificationThreads.serialize(2, () async {
        log.add('other chat');
      });
      await otherChat;
      await Future<void>.delayed(Duration.zero);
      expect(log, ['first start', 'other chat']);
      gate.complete();
      await expectLater(first, throwsStateError);
      expect(await second, 2);
      expect(log, ['first start', 'other chat', 'first end', 'second']);
    });

    test('an older message handled last keeps the newer one as the tap '
        'target', () {
      final at = DateTime.utc(2026, 10, 21, 12);
      final newer = NotificationNewest(at, telegram.id, r'$newer');
      final older = NotificationNewest(
        at.subtract(const Duration(minutes: 1)),
        whatsapp.id,
        r'$older',
      );
      expect(NotificationThreads.newest(7, newer), same(newer));
      expect(NotificationThreads.newest(7, older), same(newer));
      NotificationThreads.forget([7]);
      expect(NotificationThreads.newest(7, older), same(older));
    });
  });

  group('read targets', () {
    test('a local echo or a missing preview is never a read target; the '
        'newest server event of the loaded timeline is', () {
      final synced = whatsapp.message(r'$synced', 'Fictional', minute: 10);
      final echo = whatsapp.message(
        'local-echo',
        'Fictional',
        outgoing: true,
        minute: 11,
        status: EventStatus.error,
      );
      whatsapp.lastEvent = echo;
      expect(conversationReadTarget(whatsapp), isNull);
      expect(
        conversationReadTarget(whatsapp, loaded: [echo, synced]),
        same(synced),
      );
      telegram.lastEvent = null;
      expect(
        conversationReadTargets([
          whatsapp,
          telegram,
        ], loaded: (room) => room == whatsapp ? [echo, synced] : const []),
        [(whatsapp, r'$synced')],
      );
    });

    test('a cutoff skips messages the notification did not show', () {
      final early = telegram.message(r'$early', 'Fictional', minute: 5);
      final late = telegram.message(r'$late', 'Fictional', minute: 30);
      telegram.lastEvent = late;
      expect(
        conversationReadTarget(
          telegram,
          loaded: [late, early],
          notAfter: DateTime.utc(2026, 10, 16, 16, 20),
        ),
        same(early),
      );
    });
  });

  group('bot and service chats', () {
    final now = DateTime.utc(2026, 10, 21, 12);
    test('notify quietly unless the user just wrote there', () {
      expect(
        personalNotificationQuiet(
          technical: false,
          fromService: false,
          now: now,
        ),
        isFalse,
      );
      expect(
        personalNotificationQuiet(
          technical: true,
          fromService: false,
          now: now,
        ),
        isTrue,
      );
      expect(
        personalNotificationQuiet(
          technical: false,
          fromService: true,
          now: now,
        ),
        isTrue,
      );
      expect(
        personalNotificationQuiet(
          technical: true,
          fromService: true,
          now: now,
          lastOwnMessage: now.subtract(const Duration(minutes: 3)),
        ),
        isFalse,
        reason: 'A sign-in prompt the user asked for alerts',
      );
      expect(
        personalNotificationQuiet(
          technical: true,
          fromService: true,
          now: now,
          lastOwnMessage: now.subtract(const Duration(minutes: 11)),
        ),
        isTrue,
      );
    });
  });
}

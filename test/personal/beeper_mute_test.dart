// SPDX-License-Identifier: AGPL-3.0-or-later
// Beeper's own room mute (`com.beeper.mute`): bbctl's Slack bridge mutes
// every new channel for good, so Slack channels never alerted nor showed
// unread. Fictional offline fixtures and a fake homeserver only.
import 'package:chatloom/personal/beeper_mute.dart';
import 'package:chatloom/personal/push_rule_mirror.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import '../notion/conversation_test_support.dart';

class _Client extends ConversationClient {
  final calls = <String>[];
  Object? failure;

  @override
  bool isLogged() => true;

  @override
  Future<void> setAccountDataPerRoom(
    String userId,
    String roomId,
    String type,
    Map<String, Object?> body,
  ) async {
    if (failure != null) throw failure!;
    calls.add('$roomId $type ${body.keys.join(',')}');
    // The server echoes the write in the next sync.
    getRoomById(roomId)!.roomAccountData[type] = BasicEvent(
      type: type,
      content: body,
    );
  }
}

void _mute(Room room, Object? until) => room.roomAccountData[beeperMuteType] =
    BasicEvent(type: beeperMuteType, content: {'muted_until': until});

void main() {
  final now = DateTime.utc(2026, 11, 2, 12);

  group('beeperMuted', () {
    test('reads -1 as for good, an end in ms, 0 or none as unmuted', () {
      final client = _Client();
      final room = ConversationRoom(client, '!a:example.invalid');
      expect(beeperMuted(room, now: now), isFalse);
      _mute(room, -1);
      expect(beeperMuted(room, now: now), isTrue);
      _mute(room, 0);
      expect(beeperMuted(room, now: now), isFalse);
      _mute(room, now.add(const Duration(hours: 1)).millisecondsSinceEpoch);
      expect(beeperMuted(room, now: now), isTrue);
      _mute(
        room,
        now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
      );
      expect(beeperMuted(room, now: now), isFalse);
      _mute(room, 'forever');
      expect(beeperMuted(room, now: now), isFalse);
    });

    test('an active Beeper mute is the account rule "Muted"', () {
      final client = _Client();
      final room = ConversationRoom(client, '!a:example.invalid');
      expect(accountPushRuleState(room), PushRuleState.notify);
      _mute(room, -1);
      expect(accountPushRuleState(room), PushRuleState.dontNotify);
    });

    test('a Beeper-muted chat with new messages is unread without a count', () {
      final client = _Client();
      final room = ConversationRoom(client, '!a:example.invalid');
      room.lastEvent = room.message(r'$m1', 'synthetic');
      expect(room.notificationCount, 0);
      expect(personalRoomUnread(room), isFalse);
      _mute(room, -1);
      expect(room.hasNewMessages, isTrue);
      expect(personalRoomUnread(room), isTrue);
    });

    test('restored fully-read muted chat stays read before receipts load', () {
      final room = ConversationRoom(_Client(), '!a:example.invalid');
      _mute(room, -1);
      room.lastEvent = room.message(r'$read', 'synthetic');
      room.roomAccountData['m.fully_read'] = BasicEvent(
        type: 'm.fully_read',
        content: {'event_id': r'$read'},
      );
      expect(room.hasNewMessages, isTrue);
      expect(personalRoomUnread(room), isFalse);

      room.lastEvent = room.message(r'$new', 'new synthetic', minute: 41);
      expect(personalRoomUnread(room), isTrue);
    });
  });

  group('release', () {
    test('picks only Slack chats muted for good and never released', () {
      final client = _Client();
      final channel = ConversationRoom(
        client,
        '!channel:example.invalid',
        network: 'slack',
      );
      final timed = ConversationRoom(
        client,
        '!timed:example.invalid',
        network: 'slack',
      );
      final released = ConversationRoom(
        client,
        '!released:example.invalid',
        network: 'slack',
      );
      final whatsapp = ConversationRoom(client, '!wa:example.invalid');
      ConversationRoom(client, '!plain:example.invalid', network: 'slack');
      _mute(channel, -1);
      _mute(timed, now.add(const Duration(days: 365)).millisecondsSinceEpoch);
      _mute(released, -1);
      released.roomAccountData[beeperMuteReleasedType] = BasicEvent(
        type: beeperMuteReleasedType,
        content: const {},
      );
      _mute(whatsapp, -1);
      expect(beeperMuteReleaseCandidates(client).map((r) => r.id), [
        channel.id,
      ]);
    });

    test('lifts the mute first, then marks the room, once', () async {
      final client = _Client();
      final channel = ConversationRoom(
        client,
        '!channel:example.invalid',
        network: 'slack',
      );
      _mute(channel, -1);
      final release = BeeperMuteRelease(client);
      expect(await release.run(), 1);
      expect(client.calls, [
        '${channel.id} $beeperMuteType muted_until',
        '${channel.id} $beeperMuteReleasedType released_at',
      ]);
      expect(beeperMuted(channel), isFalse);
      // A mute the user sets later in another Beeper client stays.
      _mute(channel, -1);
      expect(await release.run(), 0);
      expect(beeperMuted(channel), isTrue);
      release.dispose();
    });

    test('a failed write is retried on a later pass', () async {
      final client = _Client()..failure = Exception('offline');
      final channel = ConversationRoom(
        client,
        '!channel:example.invalid',
        network: 'slack',
      );
      _mute(channel, -1);
      final release = BeeperMuteRelease(client);
      expect(await release.run(), 0);
      expect(release.pending, isEmpty);
      release.dispose();
      client.failure = null;
      final again = BeeperMuteRelease(client);
      expect(await again.run(), 1);
      expect(beeperMuted(channel), isFalse);
      again.dispose();
    });

    test('a notifying account rule lifts the Beeper mute', () async {
      final client = _Client();
      final room = ConversationRoom(client, '!a:example.invalid');
      _mute(room, -1);
      await setAccountPushRuleState(room, PushRuleState.notify);
      expect(client.calls, ['${room.id} $beeperMuteType muted_until']);
      expect(accountPushRuleState(room), PushRuleState.notify);
    });
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
// Wave 5 send-path regressions (CC-01, CC-02, ST-12). Offline: an in-memory
// private store, fictional rooms and a fake transport; nothing is sent.
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:io';

import 'package:chatloom/pages/chat/events/message_delivery_status.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/composer_commands.dart';
import 'package:chatloom/personal/immediate_outbox.dart';
import 'package:chatloom/personal/media/stale_recordings.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/storage/personal_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import '../notion/conversation_test_support.dart';

class _Store implements PersonalStore {
  final records = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, Map<String, dynamic>>> readPrefix(String prefix) async => {
    for (final entry in records.entries)
      if (entry.key.startsWith(prefix)) entry.key: entry.value,
  };
  @override
  Future<Map<String, dynamic>?> get(String key) async => records[key];
  @override
  Future<void> put(String key, Map<String, dynamic> value) async =>
      records[key] = value;
  @override
  Future<void> delete(String key) async => records.remove(key);
  @override
  Future<void> close() async {}
}

class _Client extends ConversationClient {
  @override
  String? get deviceID => 'FIXTUREDEVICE';
}

/// A source room whose server answers per attempt: `null` accepts, an
/// exception fails the send (a lost connection, unconfirmed).
class _Room extends ConversationRoom {
  final transactions = <String>[];
  final parsed = <bool>[];
  final failures = <Object>[];
  _Room(Client client) : super(client, '!outbox:example.invalid');

  @override
  Future<String?> sendTextEvent(
    String message, {
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    bool parseMarkdown = true,
    bool parseCommands = true,
    String msgtype = MessageTypes.Text,
    String? threadRootEventId,
    String? threadLastEventId,
    StringBuffer? commandStdout,
    bool addMentions = true,
    bool displayPendingEvent = true,
  }) async {
    transactions.add(txid!);
    parsed.add(parseCommands);
    if (failures.isNotEmpty) throw failures.removeAt(0);
    return '\$event-${transactions.length}';
  }
}

void main() {
  group('composer commands (CC-01)', () {
    test('only formatting commands stay registered', () {
      final client = ConversationClient();
      expect(client.commands.keys, containsAll(['logout', 'leave', 'ban']));
      restrictComposerCommands(client);
      expect(client.commands.keys.toSet(), composerCommands);
      for (final name in [
        'logout',
        'logoutall',
        'leave',
        'clearcache',
        'discardsession',
        'kick',
        'ban',
        'join',
        'dm',
        'roomupgrade',
        'ignore',
        'sendraw',
      ]) {
        expect(client.commands, isNot(contains(name)), reason: name);
      }
    });

    test('a typed /word is a message unless it is a formatting command', () {
      final client = ConversationClient();
      restrictComposerCommands(client);
      expect(composerCommandOf(client, '/me waves'), 'me');
      expect(composerCommandOf(client, '/ME waves'), 'me');
      expect(composerCommandOf(client, '/plain *literal*'), 'plain');
      expect(composerCommandOf(client, '/html <b>x</b>'), 'html');
      expect(composerCommandOf(client, '/me'), 'me');
      for (final text in [
        '/logout',
        '/leave now',
        '/clearcache',
        '/start',
        '/help',
        // The SDK would read "me\nhi" or "me's" as an unknown command and
        // drop the message silently: these are messages.
        '/me\nhi',
        "/me's turn",
        'hello /me',
        '/',
      ]) {
        expect(composerCommandOf(client, text), isNull, reason: text);
      }
    });

    test('a removed command typed anyway never runs', () async {
      final client = ConversationClient();
      restrictComposerCommands(client);
      final room = ConversationRoom(client, '!commands:example.invalid');
      // Room.sendTextEvent parses commands by default; nothing is left that
      // could sign out, leave or clear data.
      // A registered /logout would call Client.logout() here, which fails
      // offline and then clears the (fixture) database: it would throw.
      expect(
        await client.parseAndRunCommand(room, '/logout'),
        isNull,
        reason: 'unknown to the client: nothing runs',
      );
      expect(await client.parseAndRunCommand(room, '/clearcache'), isNull);
    });
  });

  group('text outbox (CC-02)', () {
    late _Store store;
    late _Client client;
    late _Room room;

    PersonalClient personalOf(Client client) =>
        PersonalClient.forTesting(client, openStore: () async => store);

    setUp(() {
      store = _Store();
      client = _Client();
      room = _Room(client);
    });

    test(
      'a successful bubble Retry completes its attempt, so the same text '
      'sent days later is a new message',
      () async {
        var personal = personalOf(client);
        room.failures.add(TimeoutException('fictional connection loss'));
        String? durableId;
        final first = await personal.sendImmediate(
          room,
          'ok',
          onDurable: (attempt) {
            durableId = attempt.actionId;
            // What the composer does once its draft is saved.
            unawaited(personal.markImmediateConsumed(attempt.actionId));
          },
        );
        expect(first.state, ImmediateSendState.unknown);
        expect(durableId, first.actionId);

        final retried = await personal.retryImmediate(first.actionId);
        expect(retried.state, ImmediateSendState.accepted);
        expect(room.transactions, [first.transactionId, first.transactionId]);
        expect(
          (await personal.immediateState(first.actionId))?.state,
          ImmediateSendState.accepted,
        );

        // Restart, then the same text again: sent, with a new transaction.
        personal.dispose();
        personal = personalOf(client);
        var cleared = false;
        final later = await personal.sendImmediate(
          room,
          'ok',
          onDurable: (_) => cleared = true,
        );
        expect(cleared, isTrue, reason: 'the composer is freed, not stuck');
        expect(later.state, ImmediateSendState.accepted);
        expect(later.actionId, isNot(first.actionId));
        expect(room.transactions, hasLength(3));
        expect(room.transactions.last, isNot(first.transactionId));
        expect(room.parsed, everyElement(isFalse));
        personal.dispose();
      },
    );

    test(
      'an unconfirmed attempt whose draft was cleared is never resumed by '
      'an identical new message',
      () async {
        var personal = personalOf(client);
        room.failures.add(TimeoutException('fictional connection loss'));
        final first = await personal.sendImmediate(
          room,
          'see you',
          onDurable: (attempt) =>
              unawaited(personal.markImmediateConsumed(attempt.actionId)),
        );
        expect(first.state, ImmediateSendState.unknown);
        await pumpEventQueue();
        personal.dispose();

        personal = personalOf(client);
        final again = await personal.sendImmediate(room, 'see you');
        expect(again.actionId, isNot(first.actionId));
        expect(room.transactions.last, isNot(first.transactionId));
        // The old bubble still retries its own attempt.
        final retried = await personal.retryImmediate(first.actionId);
        expect(retried.transactionId, first.transactionId);
        personal.dispose();
      },
    );

    test(
      'a crash before the draft was saved resumes the same attempt from '
      'the restored draft (never a duplicate)',
      () async {
        var personal = personalOf(client);
        room.failures.add(TimeoutException('fictional connection loss'));
        // No markImmediateConsumed: the draft still holds the text.
        final first = await personal.sendImmediate(room, 'draft text');
        expect(first.state, ImmediateSendState.unknown);
        personal.dispose();

        personal = personalOf(client);
        final resumed = await personal.sendImmediate(room, 'draft text');
        expect(resumed.actionId, first.actionId);
        expect(resumed.transactionId, first.transactionId);
        personal.dispose();
      },
    );

    test('a Retry that cannot start says why in plain words', () {
      for (final code in [
        null,
        'storageUnavailable',
        'actionUnavailable',
        'actionCompleted',
        'requestMismatch',
        'bridge_unavailable',
        'rejected',
      ]) {
        final text = MessageDeliveryActions.retryFailureText(code);
        expect(text, isNotEmpty);
        expect(text, isNot(contains('_')), reason: '$code leaked');
      }
    });
  });

  test('voice leftovers of dead processes are removed at start (CC-18)', () async {
    final temporary = await Directory.systemTemp.createTemp('voice_sweep_');
    addTearDown(() => temporary.delete(recursive: true));
    const uuid = '79d8a043-06f2-442b-990f-e58d5496253c';
    final live = voiceRecordingName(uuid, 'ogg');
    expect(live, 'voice_${pid}_$uuid.ogg');
    final names = {
      live: true, // this process: kept
      'voice_2147483646_$uuid.ogg': false, // a dead process: removed
      'voice_$uuid.m4a': false, // an earlier version: removed
      'voice_note.txt': true, // not ours: kept
      'voice_${uuid}_copy.ogg': true, // not the pattern: kept
    };
    for (final name in names.keys) {
      await File('${temporary.path}/$name').writeAsString('fixture');
    }
    await Directory('${temporary.path}/voice_$uuid.ogg').create();
    expect(await removeStaleVoiceRecordings(temporary), 2);
    for (final entry in names.entries) {
      expect(
        File('${temporary.path}/${entry.key}').existsSync(),
        entry.value,
        reason: entry.key,
      );
    }
    expect(
      Directory('${temporary.path}/voice_$uuid.ogg').existsSync(),
      isTrue,
      reason: 'only regular files',
    );
  });

  group('GIF capability gate (ST-12)', () {
    late ConversationClient client;
    late ConversationRoom room;
    setUp(() {
      client = ConversationClient();
      PersonalPrivacy.bind(client);
      room = ConversationRoom(client, '!meta:example.invalid', network: 'meta');
      room.state(bridgeFeaturesEventType, {
        'file': {
          'm.video': {
            'mime_types': {'video/mp4': 2},
          },
          'fi.mau.gif': {
            'mime_types': {'image/gif': 2},
          },
        },
      }, key: 'fixture');
    });
    tearDown(() => PersonalPrivacy.forget(client));

    Map<String, dynamic> video({bool gif = false}) => {
      'msgtype': MessageTypes.Video,
      'body': 'clip.mp4',
      'info': {
        'mimetype': 'video/mp4',
        'size': 1000,
        if (gif) 'fi.mau.gif': true,
      },
    };

    test('an MP4 GIF is checked against the GIF declaration', () async {
      await client.authorizeOutgoingEvent!(room, EventTypes.Message, video());
      await expectLater(
        client.authorizeOutgoingEvent!(
          room,
          EventTypes.Message,
          video(gif: true),
        ),
        throwsA(isA<PersonalCapabilityUnavailable>()),
      );
    });
  });
}

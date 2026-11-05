// SPDX-License-Identifier: AGPL-3.0-or-later
// Fictional offline fixtures: no recording, API, Matrix send or storage.
import 'dart:async';

import 'package:chatloom/pages/chat/composer_dictation.dart';
import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'conversation_test_support.dart';

class _Host
    implements ConversationComposerHost, ComposerDictationSendReceiptHost {
  _Host(this.room);
  @override
  Room room;
  @override
  Client get sendingClient => room.client;
  @override
  final sendController = TextEditingController();
  @override
  Event? replyEvent;
  @override
  Event? editEvent;
  @override
  String? activeThreadId;
  @override
  String? threadLastEventId;
  @override
  bool composerEnabled = true;
  @override
  int durableComposerSends = 0;
  int sends = 0;
  Future<void> Function()? performSend;
  @override
  Future<void> send() async {
    sends++;
    await performSend?.call();
  }

  @override
  void onInputBarChanged(String text) {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected composer fixture access');
}

void main() {
  late ConversationClient client;
  late _Host host;
  late ConversationComposerHost current;
  late Client active;
  late ComposerDictationSession session;
  var here = true;

  setUp(() {
    PersonalPrivacy.surfaceUnlocked = true;
    PersonalPrivacy.surfaceForeground = true;
    client = ConversationClient();
    host = _Host(ConversationRoom(client, '!dictation:example.invalid'));
    current = host;
    active = client;
    here = true;
  });
  tearDown(() {
    session.dispose();
    host.sendController.dispose();
    PersonalPrivacy.surfaceUnlocked = true;
    PersonalPrivacy.surfaceForeground = true;
  });
  void open() => session = ComposerDictationSession(
    host: host,
    currentHost: () => current,
    activeClient: () => active,
    mounted: () => here,
  );

  test(
    'only confirmed text goes through the existing durable send path',
    () async {
      open();
      host.performSend = () async {
        expect(host.sendController.text, 'Reviewed transcript');
        host.durableComposerSends++;
        host.sendController.clear();
      };
      expect(await session.send('Reviewed transcript'), isTrue);
      expect(host.sends, 1);
      expect(host.sendController.text, isEmpty);
      expect(await session.send('Reviewed transcript'), isFalse);
      expect(host.sends, 1);
    },
  );

  test(
    'a failed preparation restores original whitespace and can retry',
    () async {
      host.sendController.text = '  ';
      open();
      expect(await session.send('Kept in the dialog'), isFalse);
      expect(host.sendController.text, '  ');
      expect(session.valid, isTrue);
      expect(host.sends, 1);
    },
  );

  test(
    'external draft clearing is not mistaken for durable consumption',
    () async {
      open();
      host.performSend = () async => host.sendController.clear();
      expect(await session.send('Not sent'), isFalse);
      expect(host.durableComposerSends, 0);
      expect(session.valid, isFalse);
    },
  );

  test('a replacement draft on failure is never overwritten', () async {
    open();
    host.performSend = () async => host.sendController.text = 'New draft';
    expect(await session.send('Not sent'), isFalse);
    expect(host.sendController.text, 'New draft');
    expect(session.valid, isFalse);
  });

  test('a new draft after durable consumption survives', () async {
    open();
    host.performSend = () async {
      host.durableComposerSends++;
      host.sendController.clear();
      host.sendController.text = 'Next message';
    };
    expect(await session.send('Sent once'), isTrue);
    expect(host.sendController.text, 'Next message');
    expect(host.sends, 1);
  });

  test('draft changes revoke a session even when undone before Send', () async {
    open();
    host.sendController.text = 'Another draft';
    host.sendController.clear();
    expect(session.valid, isFalse);
    expect(await session.send('Transcript'), isFalse);
    expect(host.sends, 0);
  });

  test(
    'account and destination changes cannot revive a stale session',
    () async {
      open();
      active = ConversationClient('@other:example.invalid');
      expect(session.valid, isFalse);
      active = client;
      expect(session.valid, isFalse);
      expect(await session.send('Transcript'), isFalse);
      expect(host.sends, 0);
    },
  );

  test('reply or thread changes refuse a stale transcript', () async {
    open();
    host.activeThreadId = r'$new-thread';
    expect(await session.send('Transcript'), isFalse);
    expect(host.sends, 0);
    expect(host.sendController.text, isEmpty);
  });

  test(
    'locking then unlocking revokes the original permission to send',
    () async {
      open();
      PersonalPrivacy.surfaceUnlocked = false;
      PersonalPrivacy.surfaceUnlocked = true;
      expect(session.valid, isFalse);
      expect(await session.send('Transcript'), isFalse);
      expect(host.sends, 0);
    },
  );

  test('native permission backgrounding does not change the destination', () {
    open();
    PersonalPrivacy.surfaceForeground = false;
    PersonalPrivacy.surfaceForeground = true;
    expect(session.valid, isTrue);
  });

  test(
    'over-limit text is retained without a deferred split or send',
    () async {
      (host.room as ConversationRoom).state(bridgeFeaturesEventType, {
        'max_text_length': 8,
      }, key: 'fixture');
      open();
      expect(session.validateText('Too many characters'), contains('8'));
      expect(await session.send('Too many characters'), isFalse);
      expect(host.sends, 0);
      expect(host.sendController.text, isEmpty);
      expect(session.valid, isTrue);
    },
  );

  test('double tapping while trust is pending starts only one send', () async {
    open();
    final gate = Completer<void>();
    host.performSend = () async {
      await gate.future;
      host.durableComposerSends++;
      host.sendController.clear();
    };
    final first = session.send('One transcript');
    expect(await session.send('One transcript'), isFalse);
    expect(host.sends, 1);
    gate.complete();
    expect(await first, isTrue);
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
// Optimistic media sends: bubble first, upload in the background, order per
// chat, failures in the bubble. Fictional offline fixtures; the SDK send and
// the database are fakes, nothing leaves the test.
import 'dart:async';
import 'dart:typed_data';

import 'package:chatloom/personal/media/outgoing_media.dart';
import 'package:chatloom/personal/media/send_error_text.dart';
import 'package:chatloom/personal/round_video/telegram_round_service.dart';
import 'package:chatloom/personal/send_warmup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

import '../notion/conversation_test_support.dart';
import 'outgoing_media_support.dart';

typedef SentFile = ({
  String name,
  String? txid,
  Event? reply,
  Map<String, dynamic>? extra,
  int? shrink,
});

class MediaRoom extends ConversationRoom {
  final sent = <SentFile>[];
  final log = <String>[];
  final gates = <Completer<String?>>[];
  bool holdSends = false;
  Object? failure;
  final failures = <Object>[];
  MediaRoom(Client client) : super(client, '!fictional-media:example.invalid');

  @override
  Future<Event?> getEventById(String eventID) async {
    for (final event in sourceEvents) {
      if (event.eventId == eventID) return event;
    }
    return null;
  }

  @override
  Future<String?> sendFileEvent(
    MatrixFile file, {
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    int? shrinkImageMaxDimension,
    MatrixImageFile? thumbnail,
    Map<String, dynamic>? extraContent,
    String? threadRootEventId,
    String? threadLastEventId,
    bool displayPendingEvent = true,
  }) async {
    log.add('send:$txid');
    sent.add((
      name: file.name,
      txid: txid,
      reply: inReplyTo,
      extra: extraContent,
      shrink: shrinkImageMaxDimension,
    ));
    if (failures.isNotEmpty) throw failures.removeAt(0);
    if (failure != null) throw failure!;
    if (holdSends) {
      final gate = Completer<String?>();
      gates.add(gate);
      return gate.future;
    }
    return r'$accepted';
  }
}

class _MembersRoom extends ConversationRoom {
  bool encryptedRoom = true, complete = false;
  int requests = 0;
  _MembersRoom(Client client) : super(client, '!members:example.invalid');
  @override
  bool get encrypted => encryptedRoom;
  @override
  bool get participantListComplete => complete;
  @override
  Future<List<User>> requestParticipants([
    List<Membership> membershipFilter = const [
      Membership.join,
      Membership.invite,
      Membership.knock,
    ],
    bool suppressWarning = false,
    bool? cache,
    bool enforceFetchFromServer = false,
  ]) async {
    requests++;
    return const [];
  }
}

MatrixFile _file(String name) => MatrixFile(
  bytes: Uint8List.fromList([1, 2, 3]),
  name: name,
  mimeType: 'application/pdf',
);

void main() {
  late FakeEchoes echoes;
  setUp(() => OutgoingEcho.debugWriter = echoes = FakeEchoes());
  tearDown(() => OutgoingEcho.debugWriter = null);

  test('the bubble and its bytes exist before any upload starts', () async {
    final room = MediaRoom(ConversationClient())..holdSends = true;
    final reply = room.message(r'$original', 'Fictional original');
    final ticket = await OutgoingMedia.send(
      room,
      _file('report.pdf'),
      txid: 'txid-1',
      inReplyTo: reply,
      extraContent: {'body': 'Fictional caption'},
    );
    // Returned while the "network" is still held.
    expect(ticket.transactionId, 'txid-1');
    expect(echoes.log.take(2), [
      'file:cache://file/txid-1',
      'echo:txid-1:${EventStatus.sending.intValue}',
    ]);
    final echo = echoes.events['txid-1']!;
    expect(echo.senderId, room.client.userID);
    expect(echo.content['msgtype'], MessageTypes.File);
    expect(echo.content['body'], 'Fictional caption');
    // The quote shows while it uploads, and stays the same relation the
    // final event gets.
    expect(echo.content['m.relates_to'], {
      'm.in_reply_to': {'event_id': r'$original'},
    });
    expect(echo.unsigned?['transaction_id'], 'txid-1');
    expect(echo.unsigned?['in_reply_to'], r'$original');
    await pumpEventQueue();
    expect(room.sent.single.txid, 'txid-1');
    expect(room.sent.single.reply, same(reply));
    expect(
      room.sent.single.extra?['m.relates_to'],
      echo.content['m.relates_to'],
    );
    // The SDK must not age the echo into "error" during a long upload.
    expect(room.sendingQueueEventsByTxId, contains('txid-1'));
    room.gates.single.complete(r'$accepted');
    expect(await ticket.accepted, r'$accepted');
    expect(room.sendingQueueEventsByTxId, isNot(contains('txid-1')));
  });

  test(
    'sends of one chat leave in order; every bubble shows at once',
    () async {
      final room = MediaRoom(ConversationClient())..holdSends = true;
      final first = await OutgoingMedia.send(room, _file('a.pdf'), txid: 'a');
      final second = await OutgoingMedia.send(room, _file('b.pdf'), txid: 'b');
      expect(echoes.events.keys, ['a', 'b']);
      await pumpEventQueue();
      expect(room.log, ['send:a'], reason: 'b waits for a');
      room.gates.single.complete(r'$a');
      await first.accepted;
      await pumpEventQueue();
      expect(room.log, ['send:a', 'send:b']);
      room.gates.last.complete(r'$b');
      expect(await second.accepted, r'$b');
    },
  );

  test('a failure before the upload marks the bubble "Not sent"', () async {
    final room = MediaRoom(ConversationClient());
    final ticket = await OutgoingMedia.send(
      room,
      _file('clip.mp4'),
      txid: 'prep',
      prepare: () async => throw StateError('fictional encoder failure'),
    );
    await expectLater(ticket.accepted, throwsA(anything));
    expect(echoes.statusOf('prep'), EventStatus.error.intValue);
    expect(room.sent, isEmpty);
    expect(
      OutgoingMedia.failureOf('prep'),
      'The file could not be prepared for sending.',
    );
    expect(room.sendingQueueEventsByTxId, isNot(contains('prep')));
  });

  test('an upload the server refuses is reported in plain words', () async {
    final room = MediaRoom(ConversationClient())
      ..failure = FileTooBigMatrixException(30, 10);
    final ticket = await OutgoingMedia.send(
      room,
      _file('big.pdf'),
      txid: 'big',
    );
    await expectLater(ticket.accepted, throwsA(anything));
    expect(echoes.statusOf('big'), EventStatus.error.intValue);
    expect(OutgoingMedia.failureOf('big'), contains('too large'));
  });

  test('an accepted event is never downgraded to "Not sent"', () async {
    final room = MediaRoom(ConversationClient());
    await OutgoingMedia.send(room, _file('x.pdf'), txid: 'x');
    echoes.events['x'] = MatrixEvent(
      type: EventTypes.Message,
      content: const {'msgtype': MessageTypes.File, 'body': 'x.pdf'},
      eventId: 'x',
      senderId: room.client.userID!,
      originServerTs: DateTime.now(),
      unsigned: {
        messageSendingStatusKey: EventStatus.sent.intValue,
        'transaction_id': 'x',
      },
    );
    expect(await OutgoingEcho.setStatus(room, 'x', EventStatus.error), isFalse);
    expect(echoes.statusOf('x'), EventStatus.sent.intValue);
  });

  test('when the bubble cannot be stored nothing is sent', () async {
    final room = MediaRoom(ConversationClient());
    echoes.failWrites = StateError('fictional storage failure');
    await expectLater(
      OutgoingMedia.send(room, _file('y.pdf'), txid: 'y'),
      throwsStateError,
    );
    await pumpEventQueue();
    expect(room.sent, isEmpty);
    expect(room.sendingQueueEventsByTxId, isNot(contains('y')));
  });

  testWidgets('a rate limit is retried once with the same transaction', (
    tester,
  ) async {
    final room = MediaRoom(ConversationClient())
      ..failures.add(
        MatrixException(
          http.Response(
            '{"errcode":"M_LIMIT_EXCEEDED","error":"fixture",'
            '"retry_after_ms":0}',
            429,
          ),
        ),
      );
    final ticket = await OutgoingMedia.send(room, _file('z.pdf'), txid: 'z');
    await tester.pump(const Duration(seconds: 2));
    expect(await ticket.accepted, r'$accepted');
    expect(room.sent.map((s) => s.txid), ['z', 'z']);
  });

  test(
    'Retry resends the stored copy with its transaction and reply',
    () async {
      final room = MediaRoom(ConversationClient());
      final reply = room.message(r'$quoted', 'Fictional quoted');
      room.failures.add(StateError('fictional connection loss'));
      final first = await OutgoingMedia.send(
        room,
        _file('voice.ogg'),
        txid: 'voice-1',
        inReplyTo: reply,
        extraContent: {'org.matrix.msc3245.voice': <String, dynamic>{}},
      );
      await expectLater(first.accepted, throwsA(anything));
      expect(echoes.statusOf('voice-1'), EventStatus.error.intValue);
      final failed = Event.fromMatrixEvent(echoes.events['voice-1']!, room);

      final again = await OutgoingMedia.retry(failed);
      expect(echoes.statusOf('voice-1'), EventStatus.sending.intValue);
      expect(await again.accepted, r'$accepted');
      final resent = room.sent.last;
      expect(resent.txid, 'voice-1');
      expect(resent.name, 'voice.ogg');
      expect(resent.reply?.eventId, r'$quoted');
      expect(resent.extra?['org.matrix.msc3245.voice'], isNotNull);
    },
  );

  test(
    'Retry without this device\'s copy says so instead of guessing',
    () async {
      final room = MediaRoom(ConversationClient());
      final failed = Event(
        room: room,
        eventId: 'gone',
        type: EventTypes.Message,
        senderId: room.client.userID!,
        originServerTs: DateTime.now(),
        status: EventStatus.error,
        content: const {'msgtype': MessageTypes.File, 'body': 'gone.pdf'},
        unsigned: const {'transaction_id': 'gone'},
      );
      await expectLater(
        OutgoingMedia.retry(failed),
        throwsA(isA<OutgoingMediaUnavailable>()),
      );
      expect(room.sent, isEmpty);
    },
  );

  test('the member list is loaded when a chat opens, not on send', () async {
    final room = _MembersRoom(ConversationClient());
    warmUpSendPath(room);
    expect(room.requests, 1);
    room.complete = true;
    warmUpSendPath(room);
    room
      ..complete = false
      ..encryptedRoom = false;
    warmUpSendPath(room);
    expect(room.requests, 1, reason: 'complete or unencrypted: nothing');
    room
      ..encryptedRoom = true
      ..summary.mJoinedMemberCount = 500;
    warmUpSendPath(room);
    expect(room.requests, 1, reason: 'large groups load on demand');
  });

  test('failures are told in plain words, never the exception text', () {
    final secret = StateError('secret-canary internals');
    expect(sendErrorText(secret), isNot(contains('secret-canary')));
    expect(sendErrorText(secret, upload: true), contains('file'));
    expect(
      sendErrorText(FileTooBigMatrixException(30, 10)),
      contains('too large'),
    );
    expect(
      sendErrorText(TimeoutException('secret-canary')),
      'The server took too long to answer. Try again.',
    );
    expect(
      sendErrorText(
        MatrixException.fromJson({
          'errcode': 'M_UNKNOWN',
          'error': 'M_UNKNOWN',
        }),
      ),
      'Couldn’t send. Try again.',
    );
    expect(
      sendErrorText(StateError('x'), upload: true),
      'Couldn’t upload this file. Try again.',
    );
    expect(
      OutgoingMedia.describeFailure(secret),
      isNot(contains('secret-canary')),
    );
  });

  group('round bubble', () {
    const descriptor = RoundVideoDescriptor(
      sizeBytes: 1000,
      width: 384,
      height: 384,
      durationMs: 4000,
      videoCodec: 'h264',
      audioCodec: 'aac',
      cornersSanitized: true,
    );
    RoundSendTarget target({String? reply, String? thread}) => RoundSendTarget(
      accountId: '@owner:example.invalid',
      deviceId: 'DEVICE',
      roomId: '!r:example.invalid',
      network: 'telegram',
      replyEventId: reply,
      threadEventId: thread,
    );

    test('renders as a round of its final size, with the reply', () {
      final content = TelegramRoundService.roundEchoContent(
        target(reply: r'$q'),
        descriptor,
      );
      expect(RoundVideoDescriptor.fromContent(content), isNotNull);
      expect(content['info']['w'], 384);
      expect(content.containsKey('file'), isFalse, reason: 'nothing to fetch');
      expect(content['m.relates_to'], {
        'm.in_reply_to': {'event_id': r'$q'},
      });
      final threaded = TelegramRoundService.roundEchoContent(
        target(thread: r'$root'),
        descriptor,
      );
      expect(threaded['m.relates_to']['rel_type'], 'm.thread');
      expect(
        TelegramRoundService.roundEchoContent(
          target(),
          descriptor,
        ).containsKey('m.relates_to'),
        isFalse,
      );
    });

    test('the bubble finds its round attempt by transaction', () {
      final room = ConversationRoom(
        ConversationClient(),
        '!round:example.invalid',
      );
      Event own(String id, EventStatus status, {String? txid}) => Event(
        room: room,
        eventId: id,
        type: EventTypes.Message,
        senderId: room.client.userID!,
        originServerTs: DateTime.now(),
        status: status,
        content: const {'msgtype': 'm.video'},
        unsigned: txid == null ? null : {'transaction_id': txid},
      );
      expect(
        TelegramRoundService.actionOf(own('round-abc', EventStatus.sending)),
        'abc',
      );
      expect(
        TelegramRoundService.actionOf(
          own(r'$sent', EventStatus.synced, txid: 'round-abc'),
        ),
        'abc',
      );
      expect(
        TelegramRoundService.actionOf(own('immediate-x', EventStatus.error)),
        isNull,
      );
    });
  });
}

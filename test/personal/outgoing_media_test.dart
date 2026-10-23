// SPDX-License-Identifier: AGPL-3.0-or-later
// Optimistic media sends: bubble first, upload in the background, order per
// chat, failures in the bubble. Fictional offline fixtures; the SDK send and
// the database are fakes, nothing leaves the test.
import 'dart:async';
import 'dart:typed_data';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/media/outgoing_media.dart';
import 'package:chatloom/personal/media/send_error_text.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/round_video/telegram_round_service.dart';
import 'package:chatloom/personal/send_warmup.dart';
import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';
import 'outgoing_media_support.dart';

typedef SentFile = ({
  String name,
  String? txid,
  Event? reply,
  Map<String, dynamic>? extra,
  int? shrink,
  MatrixFile file,
  MatrixImageFile? thumbnail,
  String? threadRoot,
  String? threadLast,
});

class MediaRoom extends ConversationRoom {
  final readContexts = <Object?>[];
  final sent = <SentFile>[];
  final log = <String>[];
  final gates = <Completer<String?>>[];
  bool holdSends = false;
  Object? failure;
  final failures = <Object>[];

  /// Like the SDK: a failed upload marks its echo "Not sent" itself.
  bool markErrors = false;
  final events = <({Map<String, dynamic> content, String? txid})>[];
  MediaRoom(Client client) : super(client, '!fictional-media:example.invalid');

  @override
  Future<String?> sendEvent(
    Map<String, dynamic> content, {
    String type = EventTypes.Message,
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    String? threadRootEventId,
    String? threadLastEventId,
    bool displayPendingEvent = true,
    bool retryOnTransportFailure = true,
  }) async {
    log.add('event:$txid');
    events.add((content: content, txid: txid));
    return r'$resent';
  }

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
    readContexts.add(
      client.captureOutgoingContext?.call(this, EventTypes.Message),
    );
    log.add('send:$txid');
    sent.add((
      name: file.name,
      txid: txid,
      reply: inReplyTo,
      extra: extraContent,
      shrink: shrinkImageMaxDimension,
      file: file,
      thumbnail: thumbnail,
      threadRoot: threadRootEventId,
      threadLast: threadLastEventId,
    ));
    final error = failures.isNotEmpty ? failures.removeAt(0) : failure;
    if (error != null) {
      if (markErrors) {
        await OutgoingEcho.setStatus(this, txid!, EventStatus.error);
      }
      throw error;
    }
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

  test(
    'queued media and retries retain the original observed cutoff',
    () async {
      SharedPreferences.setMockInitialValues({});
      await AppSettings.init(loadWebConfigFile: false);
      await AppSettings.personalIncognito.setItem(true);
      final client = ConversationClient();
      final room = MediaRoom(client)..holdSends = true;
      PersonalPrivacy.bind(client);
      PersonalPrivacy.surfaceUnlocked = true;
      PersonalPrivacy.observe(room, r'$one');
      final first = await OutgoingMedia.send(
        room,
        _file('a.pdf'),
        txid: 'freeze-a',
      );
      final second = await OutgoingMedia.send(
        room,
        _file('b.pdf'),
        txid: 'freeze-b',
      );
      PersonalPrivacy.observe(room, r'$two');
      await pumpEventQueue();
      room.gates.first.complete(r'$a');
      await first.accepted;
      await pumpEventQueue();
      expect(room.readContexts, [r'$one', r'$one']);
      // The second send fails; its retry still uses the original cutoff.
      room.gates.last.completeError(StateError('fictional connection loss'));
      await expectLater(second.accepted, throwsA(anything));
      room.holdSends = false;
      final retry = await OutgoingMedia.retry(
        Event.fromMatrixEvent(echoes.events['freeze-b']!, room),
      );
      await retry.accepted;
      expect(room.readContexts.last, r'$one');
      PersonalPrivacy.forget(client);
    },
  );

  test('retry upgrades legacy Opus MIME and retains voice metadata', () async {
    final room = MediaRoom(ConversationClient())
      ..failures.add(StateError('fictional connection loss'));
    final bytes = Uint8List(47);
    bytes.setRange(0, 4, 'OggS'.codeUnits);
    bytes[26] = 1;
    bytes[27] = 19;
    bytes.setRange(28, 36, 'OpusHead'.codeUnits);
    final ticket = await OutgoingMedia.send(
      room,
      MatrixAudioFile(bytes: bytes, name: 'voice.ogg', mimeType: 'audio/ogg'),
      txid: 'legacy-voice',
      extraContent: {
        'info': {
          'mimetype': 'audio/ogg',
          'size': bytes.length,
          'duration': 2500,
        },
        'org.matrix.msc3245.voice': <String, dynamic>{},
        'org.matrix.msc1767.audio': {
          'duration': 2500,
          'waveform': [100, 200],
        },
      },
    );
    await expectLater(ticket.accepted, throwsA(anything));
    final retry = await OutgoingMedia.retry(
      Event.fromMatrixEvent(echoes.events['legacy-voice']!, room),
    );
    await retry.accepted;
    final extra = room.sent.last.extra!;
    expect(extra['info']['mimetype'], 'audio/ogg; codecs=opus');
    expect(extra['info']['duration'], 2500);
    expect(extra['org.matrix.msc3245.voice'], isEmpty);
    expect(extra['org.matrix.msc1767.audio']['waveform'], [100, 200]);
    expect(room.sent.last.txid, 'legacy-voice');
  });

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

  test(
    'Retry of a file already uploaded resends only its event (CC-04)',
    () async {
      final room = MediaRoom(ConversationClient());
      // The final send failed after the upload: the SDK left the complete
      // event (URL, keys, relation) in the echo, and now also the copy.
      final content = <String, dynamic>{
        'msgtype': MessageTypes.Image,
        'body': 'photo.jpg',
        'filename': 'photo.jpg',
        'info': {'mimetype': 'image/jpeg', 'size': 3, 'w': 4, 'h': 3},
        'file': {
          'url': 'mxc://example.invalid/uploaded',
          'v': 'v2',
          'iv': 'fixture',
        },
        'm.relates_to': {
          'm.in_reply_to': {'event_id': r'$quoted'},
        },
      };
      final copy = Uri(scheme: 'cache', host: 'file', path: 'put-1');
      echoes.files[copy] = Uint8List.fromList([1, 2, 3]);
      echoes.events['put-1'] = MatrixEvent(
        type: EventTypes.Message,
        content: content,
        eventId: 'put-1',
        senderId: room.client.userID!,
        originServerTs: DateTime.now(),
        unsigned: {
          messageSendingStatusKey: EventStatus.error.intValue,
          'transaction_id': 'put-1',
        },
      );
      final failed = Event.fromMatrixEvent(echoes.events['put-1']!, room);
      final again = await OutgoingMedia.retry(failed);
      expect(echoes.statusOf('put-1'), EventStatus.sending.intValue);
      expect(await again.accepted, r'$resent');
      expect(room.sent, isEmpty, reason: 'no second upload');
      expect(room.events.single.txid, 'put-1');
      expect(room.events.single.content, content);
      expect(echoes.files, isNot(contains(copy)), reason: 'copy dropped');
    },
  );

  test('Retry keeps the size, duration, reply and thread (CC-16)', () async {
    final room = MediaRoom(ConversationClient())
      ..failures.add(StateError('fictional connection loss'));
    final reply = room.message(r'$quoted', 'Fictional quoted');
    final first = await OutgoingMedia.send(
      room,
      MatrixVideoFile(
        bytes: Uint8List.fromList([1, 2, 3]),
        name: 'clip.mp4',
        mimeType: 'video/mp4',
        width: 640,
        height: 360,
        duration: 4000,
      ),
      txid: 'clip-1',
      inReplyTo: reply,
      threadRootEventId: r'$root',
      thumbnail: MatrixImageFile(
        bytes: Uint8List.fromList([9]),
        name: 'clip.jpg',
        mimeType: 'image/jpeg',
        width: 64,
        height: 36,
      ),
    );
    await expectLater(first.accepted, throwsA(anything));
    final failed = Event.fromMatrixEvent(echoes.events['clip-1']!, room);
    final again = await OutgoingMedia.retry(failed);
    expect(await again.accepted, r'$accepted');
    final resent = room.sent.last;
    expect(resent.file, isA<MatrixVideoFile>());
    final video = resent.file as MatrixVideoFile;
    expect((video.width, video.height, video.duration), (640, 360, 4000));
    expect(resent.thumbnail?.bytes, [9], reason: 'the stored thumbnail');
    expect(resent.reply?.eventId, r'$quoted');
    expect(resent.threadRoot, r'$root', reason: 'stays in its thread');
  });

  test('a file still too large after preparing says so (CC-16)', () async {
    final room = MediaRoom(ConversationClient());
    final ticket = await OutgoingMedia.send(
      room,
      _file('long.mp4'),
      txid: 'long',
      prepare: () async => throw FileTooBigMatrixException(30, 10),
    );
    await expectLater(ticket.accepted, throwsA(anything));
    expect(OutgoingMedia.failureOf('long'), contains('too large'));
    expect(room.sent, isEmpty);
  });

  test('Retry while the file still sends joins its job (CC-17)', () async {
    final room = MediaRoom(ConversationClient())..holdSends = true;
    final ticket = await OutgoingMedia.send(room, _file('a.pdf'), txid: 'j');
    await pumpEventQueue();
    final echo = Event.fromMatrixEvent(echoes.events['j']!, room);
    expect(OutgoingMedia.isActive(echo), isTrue);
    final again = await OutgoingMedia.retry(echo);
    final twice = await OutgoingMedia.retry(echo);
    expect(identical(again.accepted, ticket.accepted), isTrue);
    expect(identical(twice.accepted, ticket.accepted), isTrue);
    room.gates.single.complete(r'$j');
    expect(await ticket.accepted, r'$j');
    expect(room.sent, hasLength(1), reason: 'never a second job');
    expect(OutgoingMedia.isActive(echo), isFalse);
  });

  testWidgets('a rate-limit wait keeps the bubble "Sending" (CC-17)', (
    tester,
  ) async {
    final room = MediaRoom(ConversationClient())
      ..markErrors = true
      ..failures.add(
        MatrixException(
          http.Response(
            '{"errcode":"M_LIMIT_EXCEEDED","error":"fixture",'
            '"retry_after_ms":0}',
            429,
          ),
        ),
      );
    final ticket = await OutgoingMedia.send(room, _file('r.pdf'), txid: 'r');
    await tester.pump();
    await tester.pump();
    // The SDK said "Not sent"; the job still owns the file and waits.
    expect(echoes.statusOf('r'), EventStatus.sending.intValue);
    final echo = Event.fromMatrixEvent(echoes.events['r']!, room);
    expect(OutgoingMedia.isActive(echo), isTrue);
    await tester.pump(const Duration(seconds: 2));
    expect(await ticket.accepted, r'$accepted');
  });

  test('a file deleted while queued is never sent (CC-17)', () async {
    final room = MediaRoom(ConversationClient())..holdSends = true;
    final first = await OutgoingMedia.send(room, _file('a.pdf'), txid: 'q1');
    final second = await OutgoingMedia.send(room, _file('b.pdf'), txid: 'q2');
    await pumpEventQueue();
    final queued = Event.fromMatrixEvent(echoes.events['q2']!, room);
    await OutgoingMedia.discard(queued);
    room.gates.single.complete(r'$q1');
    expect(await first.accepted, r'$q1');
    await expectLater(second.accepted, throwsA(anything));
    expect(room.log, ['send:q1'], reason: 'the deleted file never left');
    expect(echoes.statusOf('q2'), EventStatus.sending.intValue);
    expect(OutgoingMedia.failureOf('q2'), isNull);
    expect(
      echoes.files,
      isNot(contains(Uri(scheme: 'cache', host: 'file', path: 'q2'))),
    );
  });

  test(
    'a file too large for the cache can still be retried this session',
    () async {
      echoes.maxFileSize = 2;
      final room = MediaRoom(ConversationClient())
        ..failures.add(StateError('fictional connection loss'));
      final first = await OutgoingMedia.send(room, _file('big.pdf'), txid: 'b');
      await expectLater(first.accepted, throwsA(anything));
      expect(
        echoes.files,
        isEmpty,
        reason: 'the encrypted cache skipped it, like real large files',
      );
      final failed = Event.fromMatrixEvent(echoes.events['b']!, room);
      final again = await OutgoingMedia.retry(failed);
      expect(await again.accepted, r'$accepted');
      expect(room.sent.last.file.bytes, [1, 2, 3]);
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

  testWidgets('the member list waits for the chat-open slide (PF-04)', (
    tester,
  ) async {
    final room = _MembersRoom(ConversationClient());
    final slide = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 200),
    );
    addTearDown(slide.dispose);
    unawaited(slide.forward());
    warmUpSendPath(room, route: slide);
    expect(room.requests, 0, reason: 'not during the slide');
    // The first frame starts the slide; it ends 200 ms later, before the
    // 500 ms bound.
    await tester.pump(const Duration(milliseconds: 100));
    expect(room.requests, 0);
    await tester.pump(const Duration(milliseconds: 300));
    expect(slide.status, AnimationStatus.completed);
    expect(room.requests, 1);
    // A route that is not moving starts at once.
    warmUpSendPath(room, route: slide);
    expect(room.requests, 2);
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

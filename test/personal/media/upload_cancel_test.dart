// SPDX-License-Identifier: AGPL-3.0-or-later
// Cancelling an upload (MD-17) and videos read only when prepared (MD-05).
// Fictional offline fixtures: the SDK send, the HTTP client and the
// database are fakes; nothing leaves the test.
import 'dart:async';
import 'dart:typed_data';

import 'package:chatloom/personal/media/outgoing_media.dart';
import 'package:chatloom/personal/media/upload_progress.dart';
import 'package:chatloom/utils/resize_video.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import '../../notion/conversation_test_support.dart';
import '../outgoing_media_support.dart';

class _Room extends ConversationRoom {
  final sent = <MatrixFile>[];
  final gates = <Completer<String?>>[];
  bool hold = false;
  _Room(Client client) : super(client, '!fictional-cancel:example.invalid');

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
    sent.add(file);
    if (!hold) return r'$accepted';
    final gate = Completer<String?>();
    gates.add(gate);
    final id = await gate.future;
    // Like the SDK: a cancelled send stops before its event.
    if (client.fileSendCancelled?.call(txid!) ?? false) return null;
    return id;
  }
}

/// Holds the request body like a slow socket until aborted.
class _HangingClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final trigger = request is http.Abortable ? request.abortTrigger : null;
    await (trigger ?? Completer<void>().future);
    throw http.RequestAbortedException(request.url);
  }
}

void main() {
  late FakeEchoes echoes;
  setUp(() {
    OutgoingEcho.debugWriter = echoes = FakeEchoes();
    UploadProgress.debugClear();
  });
  tearDown(() => OutgoingEcho.debugWriter = null);

  test('an aborted send stops its running upload request', () async {
    final socket = _HangingClient();
    final client = UploadProgressClient(socket);
    final request =
        http.Request(
            'POST',
            Uri.parse('https://example.invalid/_matrix/media/v3/upload'),
          )
          ..headers['content-type'] = 'application/octet-stream'
          ..bodyBytes = Uint8List(1024);
    final upload = UploadProgress.track('abort-me', () => client.send(request));
    await pumpEventQueue();
    expect(socket.requests.single, isA<http.Abortable>());
    UploadProgress.abort('abort-me');
    await expectLater(upload, throwsA(isA<http.RequestAbortedException>()));
  });

  test('an upload cancelled before it starts fails at once', () async {
    final socket = _HangingClient();
    final client = UploadProgressClient(socket);
    UploadProgress.abort('early');
    final request =
        http.Request(
            'POST',
            Uri.parse('https://example.invalid/_matrix/media/v3/upload'),
          )
          ..headers['content-type'] = 'application/octet-stream'
          ..bodyBytes = Uint8List(10);
    await expectLater(
      UploadProgress.track('early', () => client.send(request)),
      throwsA(isA<http.RequestAbortedException>()),
    );
  });

  test(
    'cancelling during the upload sends nothing and is no failure',
    () async {
      final room = _Room(ConversationClient())..hold = true;
      final ticket = await OutgoingMedia.send(
        room,
        MatrixFile(
          bytes: Uint8List.fromList([1, 2, 3]),
          name: 'fictional.pdf',
          mimeType: 'application/pdf',
        ),
        txid: 'c1',
      );
      await pumpEventQueue();
      final echo = Event.fromMatrixEvent(echoes.events['c1']!, room);
      expect(OutgoingMedia.isActive(echo), isTrue);
      await OutgoingMedia.discard(echo);
      expect(room.client.fileSendCancelled!('c1'), isTrue);
      expect(UploadProgress.isAborted('c1'), isTrue);
      room.gates.single.complete(r'$would-have-been-sent');
      Object? error;
      try {
        await ticket.accepted;
      } catch (e) {
        error = e;
      }
      expect(error, isNotNull);
      expect(OutgoingMedia.isDiscard(error!), isTrue);
      expect(OutgoingMedia.failureOf('c1'), isNull);
      expect(echoes.statusOf('c1'), isNot(EventStatus.error.intValue));
      expect(OutgoingMedia.isActive(echo), isFalse);
    },
  );

  test('cancelling while a video is prepared stops it before upload', () async {
    final room = _Room(ConversationClient());
    final preparing = Completer<void>();
    var cancelled = 0;
    final ticket = await OutgoingMedia.send(
      room,
      PendingVideoFile(
        name: 'fictional.mp4',
        mimeType: 'video/mp4',
        declaredSize: 300 * 1000 * 1000,
      ),
      txid: 'v1',
      prepare: () async {
        await preparing.future;
        throw const VideoPrepareCancelled();
      },
      cancelPrepare: () async {
        cancelled++;
        preparing.complete();
      },
    );
    await pumpEventQueue();
    final echo = Event.fromMatrixEvent(echoes.events['v1']!, room);
    await OutgoingMedia.discard(echo);
    expect(cancelled, 1);
    await expectLater(ticket.accepted, throwsA(anything));
    expect(room.sent, isEmpty);
    expect(OutgoingMedia.failureOf('v1'), isNull);
  });

  test(
    'a video is read only when prepared; Retry prepares it again (MD-05)',
    () async {
      final room = _Room(ConversationClient());
      var runs = 0;
      final ticket = await OutgoingMedia.send(
        room,
        PendingVideoFile(
          name: 'fictional.mp4',
          mimeType: 'video/mp4',
          declaredSize: 300 * 1000 * 1000,
        ),
        txid: 'v2',
        prepare: () async {
          runs++;
          if (runs == 1) throw StateError('fictional codec failure');
          return (
            MatrixVideoFile(
              bytes: Uint8List.fromList([9, 9]),
              name: 'fictional.mp4',
              mimeType: 'video/mp4',
              width: 720,
              height: 1280,
              duration: 1000,
            ),
            null,
          );
        },
      );
      // The bubble shows the declared size; no bytes were stored for it.
      final shown = echoes.events['v2']!;
      expect((shown.content['info'] as Map)['size'], 300 * 1000 * 1000);
      expect(echoes.log.where((l) => l.startsWith('file:')), isEmpty);
      await expectLater(ticket.accepted, throwsA(anything));
      expect(room.sent, isEmpty);
      final failed = Event.fromMatrixEvent(echoes.events['v2']!, room);
      final again = await OutgoingMedia.retry(failed);
      expect(await again.accepted, r'$accepted');
      expect(runs, 2);
      expect(room.sent.single.bytes, [9, 9]);
      expect((room.sent.single as MatrixVideoFile).height, 1280);
    },
  );

  test(
    'a document stays a document on Retry, even with an image type',
    () async {
      final room = _Room(ConversationClient())..hold = true;
      final ticket = await OutgoingMedia.send(
        room,
        MatrixDocumentFile(
          bytes: Uint8List.fromList([0xFF, 0xD8, 0xFF]),
          name: 'original.jpg',
          mimeType: 'image/jpeg',
        ),
        txid: 'd1',
      );
      expect(echoes.events['d1']!.content['msgtype'], MessageTypes.File);
      await pumpEventQueue();
      room.gates.single.completeError(StateError('fictional connection loss'));
      await expectLater(ticket.accepted, throwsA(anything));
      room.hold = false;
      final failed = Event.fromMatrixEvent(echoes.events['d1']!, room);
      final again = await OutgoingMedia.retry(failed);
      expect(await again.accepted, r'$accepted');
      expect(room.sent.last.msgType, MessageTypes.File);
    },
  );
}

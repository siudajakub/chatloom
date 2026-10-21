// SPDX-License-Identifier: AGPL-3.0-or-later
// Upload progress counted next to the socket. Fictional offline requests:
// the inner client is a fake that consumes the body; nothing is sent.
import 'dart:async';
import 'dart:typed_data';

import 'package:chatloom/personal/media/upload_progress.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Reads request bodies like a socket: chunk by chunk, pausing after each
/// chunk until [release] is called (when [throttled]).
class _SocketClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  final bodies = <List<int>>[];
  final chunkCounts = <int>[];
  bool throttled = false;
  final _gates = <Completer<void>>[];

  /// Lets every paused request read its next chunk.
  void release() {
    final gates = List.of(_gates);
    _gates.clear();
    for (final gate in gates) {
      gate.complete();
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final body = <int>[];
    var chunks = 0;
    final done = Completer<void>();
    late StreamSubscription<List<int>> subscription;
    subscription = request.finalize().listen(
      (chunk) {
        body.addAll(chunk);
        chunks++;
        if (throttled) {
          subscription.pause();
          final gate = Completer<void>();
          _gates.add(gate);
          gate.future.then((_) => subscription.resume());
        }
      },
      onDone: done.complete,
      onError: done.completeError,
    );
    await done.future;
    await subscription.cancel();
    bodies.add(body);
    chunkCounts.add(chunks);
    return http.StreamedResponse(
      Stream.value('{"content_uri":"mxc://example.invalid/x"}'.codeUnits),
      200,
    );
  }
}

http.Request _upload(
  Uint8List body, {
  String path = '/_matrix/media/v3/upload',
}) {
  final request =
      http.Request('POST', Uri.parse('https://example.invalid$path'))
        ..headers['content-type'] = 'application/octet-stream'
        ..bodyBytes = body;
  return request;
}

void main() {
  setUp(UploadProgress.debugClear);

  test(
    'outside a tracked send every request passes through unchanged',
    () async {
      final socket = _SocketClient();
      final client = UploadProgressClient(socket);
      final request = _upload(Uint8List(300 * 1024));
      await client.send(request);
      expect(socket.requests.single, same(request));
    },
  );

  test(
    'a tracked media upload reports its bytes as the socket reads them',
    () async {
      final socket = _SocketClient();
      final client = UploadProgressClient(socket);
      final body = Uint8List.fromList(
        List<int>.generate(300 * 1024, (i) => i % 251),
      );
      final seen = <double?>[];
      final progress = UploadProgress.of('txid-a');
      void listener() => seen.add(progress.value);
      progress.addListener(listener);
      addTearDown(() => progress.removeListener(listener));

      await UploadProgress.track('txid-a', () => client.send(_upload(body)));

      final sent = socket.requests.single;
      expect(sent.headers['content-type'], 'application/octet-stream');
      expect(sent.contentLength, body.length);
      expect(socket.bodies.single, body, reason: 'same bytes, same order');
      // 300 KiB in 64 KiB slices.
      expect(socket.chunkCounts.single, 5);
      expect(seen.first, 0);
      expect(seen.last, 1);
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i]! >= seen[i - 1]!, isTrue, reason: 'never goes back');
      }
      expect(seen.length, greaterThanOrEqualTo(5));
    },
  );

  test('progress follows the socket, never ahead of what it read', () async {
    final socket = _SocketClient()..throttled = true;
    final client = UploadProgressClient(socket);
    final body = Uint8List(4 * 64 * 1024);
    final sending = UploadProgress.track(
      'txid-slow',
      () => client.send(_upload(body)),
    );
    // Let the socket read the first slice, then hold it.
    await pumpEventQueue();
    expect(UploadProgress.valueOf('txid-slow'), closeTo(.25, .001));
    socket.release();
    await pumpEventQueue();
    expect(UploadProgress.valueOf('txid-slow'), closeTo(.5, .001));
    for (var i = 0; i < 3; i++) {
      socket.release();
      await pumpEventQueue();
    }
    await sending;
    expect(UploadProgress.valueOf('txid-slow'), 1);
    UploadProgress.reset('txid-slow');
    expect(UploadProgress.valueOf('txid-slow'), isNull);
  });

  test('other requests of a tracked send pass through', () async {
    final socket = _SocketClient();
    final client = UploadProgressClient(socket);
    final put = http.Request(
      'PUT',
      Uri.parse(
        'https://example.invalid/_matrix/client/v3/rooms/!r:x/send/m.room.message/t1',
      ),
    )..body = '{}';
    await UploadProgress.track('txid-b', () => client.send(put));
    expect(socket.requests.single, same(put));
    expect(UploadProgress.valueOf('txid-b'), isNull);
  });

  test('file and thumbnail uploading together count as one send', () async {
    final socket = _SocketClient()..throttled = true;
    final client = UploadProgressClient(socket);
    final both = UploadProgress.track(
      'txid-c',
      () => Future.wait([
        client.send(_upload(Uint8List(3 * 64 * 1024))),
        client.send(_upload(Uint8List(64 * 1024))),
      ]),
    );
    await pumpEventQueue();
    // First slice of each: (64 + 64) / (192 + 64) KiB.
    expect(UploadProgress.valueOf('txid-c'), closeTo(.5, .001));
    for (var i = 0; i < 4; i++) {
      socket.release();
      await pumpEventQueue();
    }
    await both;
    expect(UploadProgress.valueOf('txid-c'), 1);
  });

  test('UploadProgressClient recognises only media uploads', () {
    bool upload(String method, String path) =>
        UploadProgressClient.isMediaUpload(
          http.Request(method, Uri.parse('https://example.invalid$path')),
        );
    expect(upload('POST', '/_matrix/media/v3/upload'), isTrue);
    expect(
      upload('PUT', '/_matrix/media/v3/upload/example.invalid/abc'),
      isTrue,
    );
    expect(upload('GET', '/_matrix/media/v3/upload'), isFalse);
    expect(upload('POST', '/_matrix/client/v3/keys/upload'), isFalse);
    expect(upload('GET', '/_matrix/client/v1/media/download/x/y'), isFalse);
  });
}

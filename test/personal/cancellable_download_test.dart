// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline: a fake HTTP client streams synthetic bytes; nothing is sent.
import 'dart:async';
import 'dart:typed_data';

import 'package:chatloom/personal/media/cancellable_download.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

/// Streams the response chunks the test pushes; records the request.
class _StreamingClient extends http.BaseClient {
  _StreamingClient({this.statusCode = 200});

  final int statusCode;
  final body = StreamController<List<int>>();
  http.BaseRequest? request;
  var aborted = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    this.request = request;
    if (request is http.Abortable) {
      unawaited(
        request.abortTrigger?.then((_) {
          aborted = true;
          if (!body.isClosed) {
            body.addError(http.RequestAbortedException(request.url));
            unawaited(body.close());
          }
        }),
      );
    }
    return http.StreamedResponse(body.stream, statusCode);
  }
}

class _Database implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

/// Hands the transfer to the caller's download callback, like the SDK does
/// for an attachment that is not in its cache.
class _VideoEvent extends Event {
  _VideoEvent(Room room)
    : super(
        room: room,
        eventId: r'$cancellable-video',
        type: EventTypes.Message,
        senderId: '@fixture:example.invalid',
        originServerTs: DateTime.utc(2026),
        content: {
          'msgtype': MessageTypes.Video,
          'body': 'clip.mp4',
          'url': 'mxc://example.invalid/clip',
        },
      );

  @override
  Future<MatrixFile> downloadAndDecryptAttachment({
    bool getThumbnail = false,
    Future<Uint8List> Function(Uri)? downloadCallback,
    bool fromLocalStoreOnly = false,
    bool skipScanner = false,
    bool cacheAttachment = true,
    void Function(int)? onDownloadProgress,
  }) async {
    final bytes = await downloadCallback!(_uri);
    return MatrixFile(bytes: bytes, name: 'clip.mp4', mimeType: 'video/mp4');
  }
}

Never _throwStatus(http.BaseResponse response, Uint8List body) =>
    throw StateError('status ${response.statusCode}');

final _uri = Uri.parse('https://example.invalid/_matrix/client/v1/media/x');

void main() {
  test('downloads with the bearer token and reports progress', () async {
    final client = _StreamingClient();
    final progress = <int>[];
    final future = abortableGet(
      client,
      _uri,
      token: MediaDownloadToken(),
      accessToken: 'synthetic',
      onError: _throwStatus,
      onDownloadProgress: progress.add,
    );
    await pumpEventQueue();
    client.body.add([1, 2]);
    client.body.add([3]);
    await client.body.close();
    expect(await future, [1, 2, 3]);
    expect(progress, [2, 3]);
    expect(client.request, isA<http.Abortable>());
    expect(client.request!.headers['authorization'], 'Bearer synthetic');
  });

  test(
    'cancel aborts the request and fails with MediaDownloadCancelled',
    () async {
      final client = _StreamingClient();
      final token = MediaDownloadToken();
      final future = abortableGet(
        client,
        _uri,
        token: token,
        accessToken: null,
        onError: _throwStatus,
      );
      await pumpEventQueue();
      client.body.add([1, 2, 3]);
      await pumpEventQueue();
      token.cancel();
      await expectLater(future, throwsA(isA<MediaDownloadCancelled>()));
      expect(client.aborted, isTrue);
      expect(token.cancelled, isTrue);
    },
  );

  test('a cancelled token never sends', () async {
    final client = _StreamingClient();
    final token = MediaDownloadToken()..cancel();
    await expectLater(
      abortableGet(
        client,
        _uri,
        token: token,
        accessToken: null,
        onError: _throwStatus,
      ),
      throwsA(isA<MediaDownloadCancelled>()),
    );
    expect(client.request, isNull);
  });

  test('an error status goes to onError like the SDK', () async {
    final client = _StreamingClient(statusCode: 404);
    final future = abortableGet(
      client,
      _uri,
      token: MediaDownloadToken(),
      accessToken: null,
      onError: _throwStatus,
    );
    await pumpEventQueue();
    await client.body.close();
    await expectLater(future, throwsA(isA<StateError>()));
  });

  test('a throwing progress callback stops the read', () async {
    final client = _StreamingClient();
    final future = abortableGet(
      client,
      _uri,
      token: MediaDownloadToken(),
      accessToken: null,
      onError: _throwStatus,
      onDownloadProgress: (_) => throw const MediaDownloadCancelled(),
    );
    await pumpEventQueue();
    client.body.add([1]);
    await expectLater(future, throwsA(isA<MediaDownloadCancelled>()));
  });

  test('an attachment download stops when its token is cancelled', () async {
    final transport = _StreamingClient();
    final client = Client(
      'cancellable download',
      database: _Database(),
      httpClient: transport,
    );
    final event = _VideoEvent(
      Room(id: '!fixture:example.invalid', client: client),
    );
    final token = MediaDownloadToken();
    final received = <int>[];
    final future = downloadAttachmentCancellable(
      event,
      token: token,
      onDownloadProgress: received.add,
    );
    await pumpEventQueue();
    transport.body.add([1, 2, 3, 4]);
    await pumpEventQueue();
    expect(received, [4]);
    token.cancel();
    await expectLater(future, throwsA(isA<MediaDownloadCancelled>()));
    expect(transport.aborted, isTrue);
  });

  test('an attachment download completes with the decrypted file', () async {
    final transport = _StreamingClient();
    final client = Client(
      'cancellable download done',
      database: _Database(),
      httpClient: transport,
    );
    final event = _VideoEvent(
      Room(id: '!fixture:example.invalid', client: client),
    );
    final future = downloadAttachmentCancellable(
      event,
      token: MediaDownloadToken(),
    );
    await pumpEventQueue();
    transport.body.add([9, 8]);
    await transport.body.close();
    final file = await future;
    expect(file.bytes, [9, 8]);
    expect(file.mimeType, 'video/mp4');
  });
}

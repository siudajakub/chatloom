// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

/// Thrown by [downloadAttachmentCancellable] after [MediaDownloadToken.cancel].
class MediaDownloadCancelled implements Exception {
  const MediaDownloadCancelled();

  @override
  String toString() => 'MediaDownloadCancelled';
}

/// Cancels one attachment download: the HTTP request is aborted (no more
/// bytes over mobile data) and the download future fails with
/// [MediaDownloadCancelled]. Single use.
class MediaDownloadToken {
  final _abort = Completer<void>();

  bool get cancelled => _abort.isCompleted;

  /// The `http.AbortableRequest.abortTrigger`.
  Future<void> get onAbort => _abort.future;

  void cancel() {
    if (!_abort.isCompleted) _abort.complete();
  }
}

/// [Event.downloadAndDecryptAttachment] that [token] can stop (Telegram: the
/// "×" on the progress ring, closing the viewer or swiping to another page).
/// The SDK still checks access, decrypts, verifies the hash and keeps its
/// encrypted file cache; only the transfer itself is ours. With a content
/// scanner the SDK keeps its own transfer: a plain one stops at the next
/// chunk, a scanned encrypted one runs out and its result is discarded.
Future<MatrixFile> downloadAttachmentCancellable(
  Event event, {
  required MediaDownloadToken token,
  void Function(int bytes)? onDownloadProgress,
}) async {
  void progress(int bytes) {
    if (token.cancelled) throw const MediaDownloadCancelled();
    onDownloadProgress?.call(bytes);
  }

  final client = event.room.client;
  try {
    final file = await event.downloadAndDecryptAttachment(
      onDownloadProgress: progress,
      downloadCallback: client.contentScannerConfig != null
          ? null
          : (uri) => abortableGet(
              client.httpClient,
              uri,
              token: token,
              accessToken: client.accessToken,
              onError: client.unexpectedResponse,
              onDownloadProgress: progress,
            ),
    );
    if (token.cancelled) throw const MediaDownloadCancelled();
    return file;
  } on http.RequestAbortedException {
    throw const MediaDownloadCancelled();
  }
}

/// The SDK's attachment GET (bearer token, error on 4xx/5xx) as an
/// [http.AbortableRequest] tied to [token], reporting received bytes.
Future<Uint8List> abortableGet(
  http.Client httpClient,
  Uri uri, {
  required MediaDownloadToken token,
  required String? accessToken,
  required Never Function(http.BaseResponse response, Uint8List body) onError,
  void Function(int bytes)? onDownloadProgress,
}) async {
  if (token.cancelled) throw const MediaDownloadCancelled();
  final request = http.AbortableRequest(
    'GET',
    uri,
    abortTrigger: token.onAbort,
  );
  if (accessToken != null) {
    request.headers['authorization'] = 'Bearer $accessToken';
  }
  final response = await httpClient.send(request);
  if (response.statusCode >= 400) {
    onError(response, await response.stream.toBytes());
  }
  final builder = BytesBuilder(copy: false);
  final done = Completer<Uint8List>();
  late final StreamSubscription<List<int>> subscription;
  void fail(Object error, [StackTrace? stack]) {
    if (done.isCompleted) return;
    unawaited(subscription.cancel());
    done.completeError(error, stack);
  }

  subscription = response.stream.listen(
    (chunk) {
      if (done.isCompleted) return;
      if (token.cancelled) return fail(const MediaDownloadCancelled());
      builder.add(chunk);
      try {
        onDownloadProgress?.call(builder.length);
      } catch (error, stack) {
        fail(error, stack);
      }
    },
    onError: (Object error, StackTrace stack) => fail(
      error is http.RequestAbortedException
          ? const MediaDownloadCancelled()
          : error,
      stack,
    ),
    onDone: () {
      if (!done.isCompleted) done.complete(builder.takeBytes());
    },
    cancelOnError: true,
  );
  // A client that cannot abort still stops reading at once.
  unawaited(token.onAbort.then((_) => fail(const MediaDownloadCancelled())));
  return done.future;
}

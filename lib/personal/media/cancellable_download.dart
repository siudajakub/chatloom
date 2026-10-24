// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import 'video_file_cache.dart';

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
///
/// Large encrypted videos ([VideoFileCache.appliesTo]) are read from and
/// kept in the [VideoFileCache] as the downloaded **ciphertext**: the SDK
/// verifies the hash and decrypts a cached copy exactly like a download. A
/// cached copy that fails that check is dropped and downloaded again.
/// [videoCache] overrides the shared cache (tests).
Future<MatrixFile> downloadAttachmentCancellable(
  Event event, {
  required MediaDownloadToken token,
  void Function(int bytes)? onDownloadProgress,
  Future<VideoFileCache?> Function()? videoCache,
}) async {
  void progress(int bytes) {
    if (token.cancelled) throw const MediaDownloadCancelled();
    onDownloadProgress?.call(bytes);
  }

  final client = event.room.client;
  final mxc = event.attachmentMxcUrl;
  final account = client.userID;
  final cache =
      client.contentScannerConfig == null &&
          mxc != null &&
          account != null &&
          VideoFileCache.appliesTo(event)
      ? await (videoCache ?? VideoFileCache.shared)()
      : null;
  final key = cache == null ? null : VideoFileCache.keyFor(account!, mxc!);

  var fromCache = false;
  Future<MatrixFile> attempt({required bool useCached}) async {
    Uint8List? downloaded;
    fromCache = false;
    final file = await event.downloadAndDecryptAttachment(
      onDownloadProgress: progress,
      downloadCallback: client.contentScannerConfig != null
          ? null
          : (uri) async {
              if (useCached && cache != null) {
                final cached = await _readCached(cache, key!);
                if (cached != null) {
                  fromCache = true;
                  progress(cached.lengthInBytes);
                  return cached;
                }
              }
              return downloaded = await abortableGet(
                client.httpClient,
                uri,
                token: token,
                accessToken: client.accessToken,
                onError: client.unexpectedResponse,
                onDownloadProgress: progress,
              );
            },
    );
    if (token.cancelled) throw const MediaDownloadCancelled();
    // Only bytes the SDK has just verified (hash) and decrypted are kept,
    // and they are the ciphertext it downloaded, never [file]'s bytes.
    final ciphertext = downloaded;
    if (cache != null && ciphertext != null && !fromCache) {
      unawaited(_storeCached(cache, key!, ciphertext));
    }
    return file;
  }

  try {
    try {
      return await attempt(useCached: true);
    } on MediaDownloadCancelled {
      rethrow;
    } on http.RequestAbortedException {
      rethrow;
    } catch (_) {
      if (cache == null || !fromCache || token.cancelled) rethrow;
      // A damaged or stale cached copy fails the SDK's hash check: drop it
      // and download once more.
      await _removeCached(cache, key!);
      return await attempt(useCached: false);
    }
  } on http.RequestAbortedException {
    throw const MediaDownloadCancelled();
  }
}

Future<Uint8List?> _readCached(VideoFileCache cache, String key) async {
  try {
    return await cache.read(key);
  } catch (error) {
    Logs().w('video_cache_read_failed', error.runtimeType.toString());
    return null;
  }
}

Future<void> _storeCached(
  VideoFileCache cache,
  String key,
  Uint8List ciphertext,
) async {
  try {
    await cache.write(key, ciphertext);
  } catch (error) {
    Logs().w('video_cache_write_failed', error.runtimeType.toString());
  }
}

Future<void> _removeCached(VideoFileCache cache, String key) async {
  try {
    await cache.remove(key);
  } catch (_) {}
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

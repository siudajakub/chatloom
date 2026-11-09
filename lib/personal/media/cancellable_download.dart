// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

import 'encrypted_media_cache.dart';
import 'protected_matrix_database.dart';
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
/// Large encrypted videos and shared reels ([VideoFileCache.appliesTo]) are
/// kept in the [VideoFileCache] as the downloaded **ciphertext**: the SDK
/// verifies the hash and decrypts a cached copy exactly like a download. A
/// cached copy that fails that check is dropped and downloaded again.
/// Unencrypted-room reels stay exclusively in the authenticated SQLCipher
/// cache under a one-day key, never in the ciphertext-only disk cache.
/// [videoCache] overrides the shared cache (tests).
Future<MatrixFile> downloadAttachmentCancellable(
  Event event, {
  required MediaDownloadToken token,
  void Function(int bytes)? onDownloadProgress,
  Future<VideoFileCache?> Function()? videoCache,
}) async {
  VideoFileCache? activeVideoCache;
  int? videoGeneration;
  final client = event.room.client;
  final mxc = event.attachmentMxcUrl;
  final account = client.userID;
  final homeserver = client.homeserver;
  final database = client.database;
  final protectedDatabase = database is ProtectedMatrixDatabase
      ? database
      : null;
  final cacheGeneration = protectedDatabase?.mediaCacheGeneration;
  final canPersist = RoundMediaPolicy.fromContent(event.content).canPersist;

  void checkCancellation() {
    if (token.cancelled ||
        event.redacted ||
        !identical(event.room.client, client) ||
        client.userID != account ||
        client.homeserver != homeserver ||
        !identical(client.database, database) ||
        event.attachmentMxcUrl != mxc ||
        (canPersist &&
            !RoundMediaPolicy.fromContent(event.content).canPersist) ||
        (protectedDatabase != null &&
            protectedDatabase.mediaCacheGeneration != cacheGeneration) ||
        (activeVideoCache != null &&
            activeVideoCache.generation != videoGeneration)) {
      throw const MediaDownloadCancelled();
    }
  }

  void progress(int bytes) {
    checkCancellation();
    onDownloadProgress?.call(bytes);
  }

  checkCancellation();
  // Link adapters own their validated URL/account-bound cache separately.
  final reel =
      event.content['chatloom.local_media'] != true &&
      VideoFileCache.isReel(event);
  final cache =
      client.contentScannerConfig == null &&
          mxc != null &&
          account != null &&
          VideoFileCache.appliesTo(event)
      ? await (videoCache ?? VideoFileCache.shared)()
      : null;
  activeVideoCache = cache;
  videoGeneration = cache?.generation;
  final key = cache == null ? null : VideoFileCache.keyFor(account!, mxc!);
  checkCancellation();
  final sqlCache =
      reel &&
          !event.isAttachmentEncrypted &&
          !event.redacted &&
          canPersist &&
          client.contentScannerConfig == null &&
          account != null &&
          mxc != null &&
          database is ProtectedMatrixDatabase
      ? database
      : null;
  final sqlKey = sqlCache == null
      ? null
      : Uri(
          scheme: 'chatloom-media',
          host: 'instagram',
          path: '/native/${VideoFileCache.keyFor(account!, mxc!)}',
        );

  if (reel && mxc != null) {
    // Previous versions let the SDK keep small reels for thirty days. The
    // one-day ciphertext cache replaces those copies on explicit playback.
    // A failed cache cleanup must not prevent an authorized download.
    try {
      await database.deleteFile(mxc);
    } catch (error) {
      Logs().w('reel_legacy_cache_clear_failed', error.runtimeType.toString());
    }
  }

  var fromCache = false;
  Future<MatrixFile> attempt({required bool useCached}) async {
    Uint8List? downloaded;
    fromCache = false;
    checkCancellation();
    final file = await event.downloadAndDecryptAttachment(
      // Do not let a small reel fall back to the SDK's thirty-day cache.
      cacheAttachment: !reel,
      onDownloadProgress: progress,
      downloadCallback: client.contentScannerConfig != null
          ? null
          : (uri) async {
              if (useCached && cache != null) {
                final cached = await _readCached(cache, key!, reel: reel);
                if (cached != null) {
                  fromCache = true;
                  progress(cached.lengthInBytes);
                  return cached;
                }
              }
              if (useCached && sqlCache != null) {
                checkCancellation();
                final cached = await _readSqlCached(sqlCache, sqlKey!);
                checkCancellation();
                if (cached != null) {
                  fromCache = true;
                  progress(cached.lengthInBytes);
                  return cached;
                }
              }
              checkCancellation();
              final bytes = await abortableGet(
                client.httpClient,
                uri,
                token: token,
                accessToken: client.accessToken,
                onError: client.unexpectedResponse,
                onDownloadProgress: progress,
              );
              // The SDK may store the callback's result before returning
              // control to this wrapper. Revoke late transfers here too.
              checkCancellation();
              downloaded = bytes;
              return bytes;
            },
    );
    checkCancellation();
    // Keep bytes from the transfer rather than [file]: encrypted downloads
    // stay ciphertext on disk, while unencrypted reels stay in SQLCipher.
    final transferred = downloaded;
    if (cache != null && transferred != null && !fromCache) {
      // Finish the atomic store before playback can be reopened. Otherwise
      // an immediate second tap can miss a background partial write.
      await _storeCached(cache, key!, transferred, reel: reel);
      // The file cache serializes writes and clear, and discards writes from
      // an older generation. Deleting by key here could erase a newer retry.
    }
    if (sqlCache != null && transferred != null && !fromCache) {
      await _storeSqlCached(sqlCache, sqlKey!, transferred);
      // SQL stores already queued before Clear cache run before its delete.
      // Reject stale delivery below, without deleting a newer same-key row.
    }
    checkCancellation();
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
      if ((cache == null && sqlCache == null) ||
          !fromCache ||
          token.cancelled) {
        rethrow;
      }
      // A damaged or stale cached copy fails the SDK's hash check: drop it
      // and download once more.
      if (cache != null) await _removeCached(cache, key!, reel: reel);
      if (sqlCache != null) await _removeSqlCached(sqlCache, sqlKey!);
      return await attempt(useCached: false);
    }
  } on http.RequestAbortedException {
    throw const MediaDownloadCancelled();
  }
}

Future<Uint8List?> _readSqlCached(
  ProtectedMatrixDatabase cache,
  Uri key,
) async {
  try {
    final bytes = await cache.getFile(key);
    if (bytes != null &&
        (bytes.isEmpty ||
            bytes.lengthInBytes > EncryptedMediaCache.instagramMaxFileSize)) {
      await cache.deleteFile(key);
      return null;
    }
    return bytes;
  } catch (error) {
    Logs().w('reel_cache_read_failed', error.runtimeType.toString());
    return null;
  }
}

Future<void> _storeSqlCached(
  ProtectedMatrixDatabase cache,
  Uri key,
  Uint8List bytes,
) async {
  if (bytes.isEmpty ||
      bytes.lengthInBytes > EncryptedMediaCache.instagramMaxFileSize) {
    return;
  }
  try {
    await cache.storeFile(key, bytes, DateTime.now().millisecondsSinceEpoch);
  } catch (error) {
    Logs().w('reel_cache_write_failed', error.runtimeType.toString());
  }
}

Future<void> _removeSqlCached(ProtectedMatrixDatabase cache, Uri key) async {
  try {
    await cache.deleteFile(key);
  } catch (_) {}
}

Future<Uint8List?> _readCached(
  VideoFileCache cache,
  String key, {
  required bool reel,
}) async {
  try {
    return await cache.read(key, reel: reel);
  } catch (error) {
    Logs().w('video_cache_read_failed', error.runtimeType.toString());
    return null;
  }
}

Future<void> _storeCached(
  VideoFileCache cache,
  String key,
  Uint8List ciphertext, {
  required bool reel,
}) async {
  try {
    await cache.write(key, ciphertext, reel: reel);
  } catch (error) {
    Logs().w('video_cache_write_failed', error.runtimeType.toString());
  }
}

Future<void> _removeCached(
  VideoFileCache cache,
  String key, {
  required bool reel,
}) async {
  try {
    await cache.remove(key, reel: reel);
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

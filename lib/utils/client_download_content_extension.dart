// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:math' show max, min;
import 'dart:typed_data';
import 'dart:ui';

import 'package:chatloom/personal/media/protected_matrix_database.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

// Weakly owned by the account client; only unfinished work lives here. Sharing
// the complete read/download/store avoids racing a second SQL read and HTTP
// request when the same picture appears in several visible widgets.
typedef _MediaLoadKey = (
  Uri,
  bool,
  Duration,
  String?,
  Uri?,
  DatabaseApi,
  int,
  bool,
  int?,
);
final _mediaLoads = Expando<Map<_MediaLoadKey, _MediaLoad>>();

/// One visible consumer of a shared read. Cancelling the last consumer
/// aborts HTTP, including a response stalled before its first byte.
class MediaReadCancellation {
  final _signal = Completer<void>();
  Future<void> get onCancel => _signal.future;
  bool get cancelled => _signal.isCompleted;
  void cancel() {
    if (!_signal.isCompleted) _signal.complete();
  }
}

class _MediaLoad {
  final abort = Completer<void>();
  late final Future<Uint8List> future;
  int consumers = 0;
  bool settled = false;
}

/// A preview needs an explicit tap before fetching its original bytes.
class MediaDownloadDeferred implements Exception {
  const MediaDownloadDeferred();
}

/// Enforced while receiving chunks, before buffering an oversized response.
class MediaDownloadLimitExceeded implements Exception {
  final int limit;
  const MediaDownloadLimitExceeded(this.limit);
}

extension ClientDownloadContentExtension on Client {
  /// Downloads [mxc] (or its thumbnail), through the SQLCipher media cache
  /// unless [databaseCache] is false: callers with their own long-lived
  /// cache (sticker panel) skip it, so their reads never queue behind sync.
  Future<Uint8List> downloadMxcCached(
    Uri mxc, {
    num? width,
    num? height,
    bool isThumbnail = false,
    bool? animated,
    ThumbnailMethod? thumbnailMethod,
    bool rounded = false,
    bool databaseCache = true,
    bool allowNetwork = true,
    int? maxBytes,
    MediaReadCancellation? cancellation,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final account = userID;
    final server = homeserver;
    final cacheDatabase = database;
    final generation = cacheDatabase is ProtectedMatrixDatabase
        ? cacheDatabase.mediaCacheGeneration
        : 0;
    final token = accessToken;
    if (cancellation?.cancelled ?? false) {
      throw const MediaDownloadDeferred();
    }
    void ensureCurrent() {
      if (userID != account ||
          homeserver != server ||
          !identical(database, cacheDatabase) ||
          (cacheDatabase is ProtectedMatrixDatabase &&
              cacheDatabase.mediaCacheGeneration != generation)) {
        throw StateError('Media account changed during load');
      }
    }

    // To stay compatible with previous storeKeys:
    final cacheKey = isThumbnail
        // ignore: deprecated_member_use
        ? mxc.getThumbnail(
            this,
            width: width,
            height: height,
            animated: animated,
            method: thumbnailMethod,
          )
        : mxc;

    final pending = _mediaLoads[this] ??= {};
    final requestKey = (
      cacheKey,
      databaseCache,
      timeout,
      account,
      server,
      cacheDatabase,
      generation,
      allowNetwork,
      maxBytes,
    );
    final flight = pending.putIfAbsent(requestKey, () {
      final flight = _MediaLoad();
      final abort = flight.abort;
      late final Future<Uint8List> work;
      work =
          (() async {
            if (databaseCache) {
              final cachedData = await cacheDatabase.getFile(cacheKey);
              ensureCurrent();
              if (cachedData != null) return cachedData;
            }
            if (!allowNetwork || abort.isCompleted) {
              throw const MediaDownloadDeferred();
            }

            // Cold URI resolution may probe /versions. Its header wait uses
            // the same deadline as the actual image transfer.
            final response =
                await (() async {
                  final httpUri = isThumbnail
                      ? await mxc.getThumbnailUri(
                          this,
                          width: width,
                          height: height,
                          animated: animated,
                          method: thumbnailMethod,
                        )
                      : await mxc.getDownloadUri(this);
                  ensureCurrent();
                  // A late discovery reply must not start a second transfer
                  // after this flight timed out and its caller retried.
                  if (abort.isCompleted) {
                    throw TimeoutException('Media download timed out', timeout);
                  }
                  return _abortableGet(
                    httpClient,
                    httpUri,
                    token: token,
                    abortTrigger: abort.future,
                    maxBytes: maxBytes,
                    onLimit: () {
                      if (!abort.isCompleted) abort.complete();
                    },
                  );
                })().timeout(
                  timeout,
                  onTimeout: () {
                    if (!abort.isCompleted) abort.complete();
                    throw TimeoutException('Media download timed out', timeout);
                  },
                );
            ensureCurrent();
            if (abort.isCompleted) throw const MediaDownloadDeferred();
            if (response.statusCode != 200) {
              try {
                unexpectedResponse(response, response.bodyBytes);
              } on MatrixException catch (error) {
                // The SDK's JSON error parser omits the HTTP response.
                // Retain status so avatar/media retries respect HTTP 429
                // even when the bridge sends a nonstandard error code.
                error.response ??= response;
                rethrow;
              }
            }
            final bytes = response.bodyBytes;
            // Cache the source, never the circular notification rendition under
            // the same key used by ordinary images and encrypted attachments.
            if (databaseCache) {
              await cacheDatabase.storeFile(cacheKey, bytes, 0);
            }
            ensureCurrent();
            return bytes;
          })().whenComplete(() {
            flight.settled = true;
            if (identical(pending[requestKey], flight)) {
              pending.remove(requestKey);
            }
          });
      flight.future = work;
      return flight;
    });
    flight.consumers++;
    var released = false;
    void release() {
      if (released) return;
      released = true;
      if (--flight.consumers == 0 && !flight.settled) {
        if (!flight.abort.isCompleted) flight.abort.complete();
        if (identical(pending[requestKey], flight)) pending.remove(requestKey);
      }
    }

    final cancelled = cancellation?.onCancel.then<Uint8List>((_) {
      release();
      throw const MediaDownloadDeferred();
    });
    final imageData =
        await (cancelled == null
                ? flight.future
                : Future.any([flight.future, cancelled]))
            .whenComplete(release);
    ensureCurrent();

    if (rounded) {
      final circular = await convertToCircularImage(
        imageData,
        min(width ?? 64, height ?? 64).round(),
      );
      ensureCurrent();
      return circular;
    }

    return imageData;
  }

  /// Transport-only adapter for SDK attachment callbacks. The caller owns the
  /// deadline, and the SDK keeps authorization, ciphertext caching, hash
  /// verification and decryption. Never substitute it for scanner downloads.
  Future<Uint8List> downloadMediaBytes(
    Uri resolvedUri, {
    required Future<void> abortTrigger,
    required bool Function() cancelled,
    int? maxBytes,
  }) async {
    final account = (userID, homeserver, database);
    final cacheDatabase = database;
    final generation = cacheDatabase is ProtectedMatrixDatabase
        ? cacheDatabase.mediaCacheGeneration
        : 0;
    void guard() {
      if (cancelled()) throw TimeoutException('Media download timed out');
      if ((userID, homeserver, database) != account ||
          (cacheDatabase is ProtectedMatrixDatabase &&
              cacheDatabase.mediaCacheGeneration != generation)) {
        throw StateError('Media account changed during load');
      }
    }

    guard();
    final response = await _abortableGet(
      httpClient,
      resolvedUri,
      token: accessToken,
      abortTrigger: abortTrigger,
      maxBytes: maxBytes,
    );
    guard();
    if (response.statusCode >= 400) {
      try {
        unexpectedResponse(response, response.bodyBytes);
      } on MatrixException catch (error) {
        error.response ??= response;
        rethrow;
      }
    }
    return response.bodyBytes;
  }
}

Future<http.Response> _abortableGet(
  http.Client client,
  Uri uri, {
  required String? token,
  required Future<void> abortTrigger,
  int? maxBytes,
  void Function()? onLimit,
}) async {
  final request = http.AbortableRequest('GET', uri, abortTrigger: abortTrigger);
  if (token != null) request.headers['authorization'] = 'Bearer $token';
  final response = await client.send(request);
  if (maxBytes == null) return http.Response.fromStream(response);
  if (response.contentLength != null && response.contentLength! > maxBytes) {
    onLimit?.call();
    // Cancelling the body releases the underlying connection as well.
    await response.stream.listen((_) {}).cancel();
    throw MediaDownloadLimitExceeded(maxBytes);
  }
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in response.stream) {
    if (bytes.length + chunk.length > maxBytes) {
      onLimit?.call();
      throw MediaDownloadLimitExceeded(maxBytes);
    }
    bytes.add(chunk);
  }
  return http.Response.bytes(
    bytes.takeBytes(),
    response.statusCode,
    request: response.request,
    headers: response.headers,
    isRedirect: response.isRedirect,
    persistentConnection: response.persistentConnection,
    reasonPhrase: response.reasonPhrase,
  );
}

/// Center-cropped circular PNG with a cover-sized decode and disposed native
/// resources. Notification fallbacks share this path with cached renditions.
Future<Uint8List> convertToCircularImage(Uint8List imageBytes, int size) async {
  final codec = await instantiateImageCodecWithSize(
    await ImmutableBuffer.fromUint8List(imageBytes),
    getTargetSize: (width, height) {
      final scale = min(1.0, max(size / width, size / height));
      return TargetImageSize(
        width: max(1, (width * scale).ceil()),
        height: max(1, (height * scale).ceil()),
      );
    },
  );
  Image? originalImage;
  Picture? picture;
  Image? circularImage;
  try {
    originalImage = (await codec.getNextFrame()).image;

    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);

    final paint = Paint();
    final rect = Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble());

    final clipPath = Path()
      ..addOval(
        Rect.fromCircle(center: Offset(size / 2, size / 2), radius: size / 2),
      );

    canvas.clipPath(clipPath);

    final side = min(originalImage.width, originalImage.height).toDouble();
    canvas.drawImageRect(
      originalImage,
      Rect.fromLTWH(
        (originalImage.width - side) / 2,
        (originalImage.height - side) / 2,
        side,
        side,
      ),
      rect,
      paint,
    );

    picture = recorder.endRecording();
    circularImage = await picture.toImage(size, size);

    final byteData = await circularImage.toByteData(
      format: ImageByteFormat.png,
    );
    return byteData!.buffer.asUint8List();
  } finally {
    circularImage?.dispose();
    picture?.dispose();
    originalImage?.dispose();
    codec.dispose();
  }
}

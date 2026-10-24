// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Upload progress of own media sends, per Matrix transaction ID.
///
/// A send runs its uploads inside [track]. [UploadProgressClient] sits next
/// to the socket (below the retry client, which buffers whole bodies) and
/// counts the request body as the connection consumes it. Bubbles listen to
/// [of]: only the sending row rebuilds, at most once per percent.
///
/// Display only: nothing here decides what was sent or retried.
abstract final class UploadProgress {
  static final _zoneKey = Object();
  static final _values = <String, ValueNotifier<double?>>{};

  /// Sends the user cancelled (MD-17): their uploads stop at once.
  static final _aborted = <String>{};
  static final _trackers = <String, UploadTracker>{};

  /// Rows re-read [of] whenever their status changes, so dropping the
  /// oldest entry never leaves a live upload without a listener for long.
  static const maxEntries = 64;

  /// 0..1 while bytes go out, null before the first byte and after the end.
  static ValueListenable<double?> of(String transactionId) =>
      _notifier(transactionId);

  static double? valueOf(String transactionId) => _values[transactionId]?.value;

  static ValueNotifier<double?> _notifier(String transactionId) {
    final notifier =
        _values.remove(transactionId) ?? ValueNotifier<double?>(null);
    _values[transactionId] = notifier;
    while (_values.length > maxEntries) {
      _values.remove(_values.keys.first);
    }
    return notifier;
  }

  /// Runs [body]; media uploads it makes report to [transactionId].
  static Future<T> track<T>(String transactionId, Future<T> Function() body) {
    final tracker = UploadTracker._(_notifier(transactionId));
    if (_aborted.contains(transactionId)) tracker._abort();
    _trackers[transactionId] = tracker;
    return runZoned(body, zoneValues: {_zoneKey: tracker}).whenComplete(() {
      if (identical(_trackers[transactionId], tracker)) {
        _trackers.remove(transactionId);
      }
    });
  }

  /// Stops the uploads of [transactionId]: a running request is aborted
  /// (`http.Abortable`), a later one fails before its first byte.
  static void abort(String transactionId) {
    _aborted.add(transactionId);
    while (_aborted.length > maxEntries) {
      _aborted.remove(_aborted.first);
    }
    _trackers[transactionId]?._abort();
  }

  static bool isAborted(String transactionId) =>
      _aborted.contains(transactionId);

  /// Clears the value once a send ended (sent, failed or cancelled).
  static void reset(String transactionId) {
    _values[transactionId]?.value = null;
    _aborted.remove(transactionId);
  }

  /// The tracker of the current zone, for tests and the HTTP wrapper.
  static UploadTracker? get current {
    final tracker = Zone.current[_zoneKey];
    return tracker is UploadTracker ? tracker : null;
  }

  @visibleForTesting
  static void debugClear() {
    _values.clear();
    _aborted.clear();
    _trackers.clear();
  }
}

/// Sums every upload of one send (file and thumbnail run concurrently).
class UploadTracker {
  final ValueNotifier<double?> _notifier;
  final _parts = <Object, (int, int)>{};
  final _aborted = Completer<void>();
  UploadTracker._(this._notifier);

  /// Completes when the user cancelled this send.
  Future<void> get abortTrigger => _aborted.future;
  bool get aborted => _aborted.isCompleted;

  void _abort() {
    if (!_aborted.isCompleted) _aborted.complete();
  }

  void update(Object part, int sent, int total) {
    if (total <= 0) return;
    _parts[part] = (sent, total);
    var allSent = 0, allTotal = 0;
    for (final (s, t) in _parts.values) {
      allSent += s;
      allTotal += t;
    }
    final value = (allSent / allTotal).clamp(0.0, 1.0);
    final old = _notifier.value;
    if (old == null || value >= 1 || (value - old).abs() >= .01) {
      _notifier.value = value;
    }
  }
}

/// Reports media upload progress to the zone's [UploadTracker]; every other
/// request passes through untouched. Install it directly above the client
/// that writes to the socket: a buffering client above it (`RetryClient`)
/// would drain the body at once and report 100 % before anything was sent.
class UploadProgressClient extends http.BaseClient {
  final http.Client inner;

  /// Slice size: progress moves per slice, and the socket's backpressure
  /// pauses the slices.
  static const chunkSize = 64 * 1024;

  UploadProgressClient(this.inner);

  static bool isMediaUpload(http.BaseRequest request) {
    if (request.method != 'POST' && request.method != 'PUT') return false;
    final segments = request.url.pathSegments;
    return segments.length >= 4 &&
        segments[0] == '_matrix' &&
        segments[1] == 'media' &&
        segments.contains('upload');
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final tracker = UploadProgress.current;
    if (tracker == null ||
        !isMediaUpload(request) ||
        (request.contentLength ?? 0) <= 0) {
      return inner.send(request);
    }
    return inner.send(_CountingRequest(request, tracker));
  }

  @override
  void close() => inner.close();
}

class _CountingRequest extends http.BaseRequest with http.Abortable {
  final http.BaseRequest _source;
  final UploadTracker _tracker;

  _CountingRequest(this._source, this._tracker)
    : super(_source.method, _source.url) {
    headers.addAll(_source.headers);
    contentLength = _source.contentLength;
    followRedirects = _source.followRedirects;
    maxRedirects = _source.maxRedirects;
    persistentConnection = _source.persistentConnection;
  }

  @override
  Future<void>? get abortTrigger => _tracker.abortTrigger;

  @override
  http.ByteStream finalize() {
    super.finalize();
    final total = contentLength ?? 0;
    final part = Object();
    var sent = 0;
    _tracker.update(part, 0, total);
    return http.ByteStream(
      _slices(_source.finalize()).map((chunk) {
        // A client that ignores [abortTrigger] still stops here.
        if (_tracker.aborted) throw http.RequestAbortedException(url);
        sent += chunk.length;
        _tracker.update(part, sent, total);
        return chunk;
      }),
    );
  }

  /// Re-slices the body; an `async*` generator stops at `yield` while the
  /// consumer is paused, so slices follow the socket.
  static Stream<List<int>> _slices(Stream<List<int>> body) async* {
    await for (final chunk in body) {
      if (chunk.length <= UploadProgressClient.chunkSize) {
        yield chunk;
        continue;
      }
      for (var i = 0; i < chunk.length; i += UploadProgressClient.chunkSize) {
        final end = i + UploadProgressClient.chunkSize < chunk.length
            ? i + UploadProgressClient.chunkSize
            : chunk.length;
        yield chunk is Uint8List
            ? Uint8List.sublistView(chunk, i, end)
            : chunk.sublist(i, end);
      }
    }
  }
}

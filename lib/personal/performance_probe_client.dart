// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/performance_probe.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

/// Account-level timing points of [PersonalPerformanceProbe]:
///
/// * `sync.process`: sync response handed to the SDK → processed;
/// * `receive.row`: processing of a sync with a new incoming message → the
///   frame after the inbox published it (only while the inbox is shown);
/// * `inbox.publish`: one inbox refresh (selection over changed rooms).
///
/// Only durations are kept; never room, event or user identifiers.
abstract final class ClientPerformanceProbe {
  static final _watches = Expando<_SyncWatch>('performance sync watch');

  /// Starts watching [client]'s sync (idempotent; lives as long as it).
  static void watch(Client client) => _watches[client] ??= _SyncWatch(client);

  /// The inbox of [client] published a refresh that took [elapsed].
  static void inboxPublished(Client client, Duration elapsed) {
    PersonalPerformanceProbe.record('inbox.publish', elapsed);
    _watches[client]?.published();
  }
}

/// A receive older than this when the inbox publishes was waiting for a
/// covered inbox (phone layout, chat open), not for the app: not a sample.
const _receiveHorizon = Duration(seconds: 5);

class _SyncWatch {
  _SyncWatch(this.client) {
    client.onSyncStatus.stream.listen(_onStatus, onError: (_) {});
    client.onSync.stream.listen(_onSync, onError: (_) {});
  }

  final Client client;
  Stopwatch? _processing;
  Stopwatch? _receive;

  void _onStatus(SyncStatusUpdate update) {
    switch (update.status) {
      case SyncStatus.processing:
        _processing = Stopwatch()..start();
      case SyncStatus.finished:
        final processing = _processing;
        _processing = null;
        if (processing != null) {
          PersonalPerformanceProbe.record('sync.process', processing.elapsed);
        }
      case SyncStatus.error:
        _processing = null;
      default:
    }
  }

  void _onSync(SyncUpdate sync) {
    final own = client.userID;
    final incoming =
        sync.rooms?.join?.values.any(
          (room) =>
              room.timeline?.events?.any(
                (event) =>
                    event.senderId != own &&
                    (event.type == EventTypes.Message ||
                        event.type == EventTypes.Encrypted ||
                        event.type == EventTypes.Sticker),
              ) ??
              false,
        ) ??
        false;
    if (incoming) _receive ??= _processing ?? (Stopwatch()..start());
  }

  void published() {
    final receive = _receive;
    if (receive == null) return;
    _receive = null;
    if (receive.elapsed > _receiveHorizon) return;
    PersonalPerformanceProbe.afterFrame(
      () => PersonalPerformanceProbe.record('receive.row', receive.elapsed),
    );
  }
}

/// Times the Matrix requests whose latency the probe needs, after the
/// privacy guard decided to send them:
///
/// * `members.fetch`: `GET …/rooms/{room}/members` until the body is read
///   (how often the trust check and encryption hit the network);
/// * `send.http`: `PUT …/rooms/{room}/send/…` until the server answered.
///
/// Every other request passes through untouched.
class PerformanceTimingClient extends http.BaseClient {
  PerformanceTimingClient(this.inner);

  final http.Client inner;

  static String? operationOf(http.BaseRequest request) {
    final segments = request.url.pathSegments;
    if (segments.length < 6 ||
        segments[0] != '_matrix' ||
        segments[1] != 'client' ||
        segments[3] != 'rooms') {
      return null;
    }
    final operation = segments[5];
    if (operation == 'members' && request.method == 'GET') {
      return 'members.fetch';
    }
    if (operation == 'send' && request.method == 'PUT') return 'send.http';
    return null;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final operation = operationOf(request);
    if (operation == null) return inner.send(request);
    final watch = Stopwatch()..start();
    final response = await inner.send(request);
    if (operation == 'send.http') {
      PersonalPerformanceProbe.record(operation, watch.elapsed);
      return response;
    }
    var recorded = false;
    void done() {
      if (recorded) return;
      recorded = true;
      PersonalPerformanceProbe.record(operation, watch.elapsed);
    }

    return http.StreamedResponse(
      response.stream.transform(
        StreamTransformer.fromHandlers(
          handleDone: (sink) {
            done();
            sink.close();
          },
        ),
      ),
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => inner.close();
}

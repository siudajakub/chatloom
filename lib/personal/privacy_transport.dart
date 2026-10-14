// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'round_video/telegram_media_protocol.dart';

class PrivacySuppressed implements Exception {
  const PrivacySuppressed();
  @override
  String toString() => 'PrivacySuppressed';
}

final _readGrantKey = Object();
final _playedGrantKey = Object();
final _outgoingContextKey = Object();

class _PlayedGrant {
  final String roomId, eventId, sourceAccountId, requestId, origin;
  final bool explicit;
  final bool Function() isCurrent;
  final Stopwatch _age = Stopwatch()..start();
  bool dispatched = false;
  _PlayedGrant(
    this.roomId,
    this.eventId,
    this.sourceAccountId,
    this.requestId,
    this.origin,
    this.explicit,
    this.isCurrent,
  );

  bool permits(Map<String, dynamic> content, bool incognito) {
    final source = content['source'];
    return !dispatched &&
        isCurrent() &&
        _age.elapsed < const Duration(seconds: 20) &&
        (!incognito || explicit) &&
        source is Map &&
        content['version'] == 1 &&
        content['manual'] == true &&
        content['request_id'] == requestId &&
        content['explicit_grant'] == explicit &&
        content['incognito'] == incognito &&
        source['account_id'] == sourceAccountId &&
        source['room_id'] == roomId &&
        source['event_id'] == eventId;
  }
}

class _OutgoingPrivacyContext {
  final String roomId, type, txid, origin;
  final Map<String, dynamic> content;
  final bool Function()? isCurrent;
  final bool requireEncrypted;
  const _OutgoingPrivacyContext(
    this.roomId,
    this.type,
    this.txid,
    this.origin,
    this.content,
    this.isCurrent,
    this.requireEncrypted,
  );
}

Future<T> withMediaPlayedGrant<T>({
  required String roomId,
  required String eventId,
  required String sourceAccountId,
  required String requestId,
  required Uri server,
  required bool explicit,
  required bool Function() isCurrent,
  required Future<T> Function() action,
}) => runZoned(
  action,
  zoneValues: {
    _playedGrantKey: _PlayedGrant(
      roomId,
      eventId,
      sourceAccountId,
      requestId,
      server.origin,
      explicit,
      isCurrent,
    ),
  },
);

void authorizeMediaPlayed(Map<String, dynamic> content, bool incognito) {
  final grant = Zone.current[_playedGrantKey];
  if (grant is! _PlayedGrant || !grant.permits(content, incognito)) {
    throw const PrivacySuppressed();
  }
}

Future<T> withOutgoingPrivacyContext<T>({
  required String roomId,
  required String type,
  required String transactionId,
  required Uri server,
  required Map<String, dynamic> content,
  required Future<T> Function() action,
  bool Function()? isCurrent,
  bool requireEncrypted = false,
}) => runZoned(
  action,
  zoneValues: {
    _outgoingContextKey: _OutgoingPrivacyContext(
      roomId,
      type,
      transactionId,
      server.origin,
      jsonDecode(jsonEncode(content)) as Map<String, dynamic>,
      isCurrent,
      requireEncrypted,
    ),
  },
);

class _ReadGrant {
  final String roomId, eventId, origin;
  const _ReadGrant(this.roomId, this.eventId, this.origin);
}

Future<T> withReadGrant<T>(
  String roomId,
  String eventId,
  Uri server,
  Future<T> Function() action,
) => runZoned(
  action,
  zoneValues: {_readGrantKey: _ReadGrant(roomId, eventId, server.origin)},
);

/// Final request-time guard, shared by foreground and background clients.
class PrivacyHttpClient extends http.BaseClient {
  final http.Client inner;
  final bool Function() incognito;
  PrivacyHttpClient(this.inner, {required this.incognito});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final private = incognito();
    final segments = request.url.pathSegments;
    final matrix =
        segments.length >= 3 &&
        segments[0] == '_matrix' &&
        segments[1] == 'client';
    if (!matrix) return inner.send(request);
    final rooms = segments.length >= 5 && segments[3] == 'rooms' ? 3 : -1;
    if (rooms >= 0 && segments.length > rooms + 2) {
      final roomId = segments[rooms + 1];
      final operation = segments[rooms + 2];
      if (operation == 'send' && request.method != 'GET') {
        final context = Zone.current[_outgoingContextKey];
        if (context is _OutgoingPrivacyContext &&
            context.isCurrent?.call() == false) {
          throw const PrivacySuppressed();
        }
        final wireType = segments.length > rooms + 3 ? segments[rooms + 3] : '';
        final control =
            isTelegramMediaControl(wireType) ||
            (context is _OutgoingPrivacyContext &&
                isTelegramMediaControl(context.type));
        if ((control ||
                (context is _OutgoingPrivacyContext &&
                    context.requireEncrypted)) &&
            (context is! _OutgoingPrivacyContext ||
                wireType != 'm.room.encrypted' ||
                context.type == telegramMediaStateType ||
                segments.length != rooms + 5 ||
                context.roomId != roomId ||
                context.txid != segments.last ||
                context.origin != request.url.origin)) {
          throw const PrivacySuppressed();
        }
        final played =
            wireType == telegramMediaPlayedType ||
            (context is _OutgoingPrivacyContext &&
                context.type == telegramMediaPlayedType);
        if (played) {
          final grant = Zone.current[_playedGrantKey];
          if (context is! _OutgoingPrivacyContext ||
              grant is! _PlayedGrant ||
              segments.length != rooms + 5 ||
              context.roomId != roomId ||
              context.txid != segments.last ||
              context.origin != request.url.origin ||
              grant.origin != request.url.origin ||
              !grant.permits(context.content, private)) {
            throw const PrivacySuppressed();
          }
          grant.dispatched = true;
        }
      }
      if (!private) return inner.send(request);
      if (operation == 'read_markers' || operation == 'receipt') {
        final grant = Zone.current[_readGrantKey];
        if (grant is! _ReadGrant ||
            grant.roomId != roomId ||
            grant.origin != request.url.origin) {
          throw const PrivacySuppressed();
        }
        if (operation == 'receipt') {
          if (segments.length != rooms + 5 ||
              segments.last != grant.eventId ||
              !{
                'm.read',
                'm.read.private',
                'm.fully_read',
              }.contains(segments[rooms + 3])) {
            throw const PrivacySuppressed();
          }
        } else {
          final body = _body(request);
          if (body.isEmpty ||
              body.entries.any(
                (e) =>
                    !{
                      'm.read',
                      'm.read.private',
                      'm.fully_read',
                    }.contains(e.key) ||
                    e.value != grant.eventId,
              )) {
            throw const PrivacySuppressed();
          }
        }
      }
      if (operation == 'typing' && _body(request)['typing'] != false) {
        throw const PrivacySuppressed();
      }
    }
    if (!private) return inner.send(request);
    if (segments.length == 6 &&
        segments[3] == 'presence' &&
        segments[5] == 'status' &&
        request.method != 'GET' &&
        _body(request)['presence'] != 'offline') {
      throw const PrivacySuppressed();
    }
    if (segments.length == 4 &&
        segments[3] == 'sync' &&
        request.url.queryParameters['set_presence'] != 'offline') {
      if (request is! http.Request) throw const PrivacySuppressed();
      final replacement =
          http.Request(
              request.method,
              request.url.replace(
                queryParameters: {
                  ...request.url.queryParameters,
                  'set_presence': 'offline',
                },
              ),
            )
            ..headers.addAll(request.headers)
            ..bodyBytes = request.bodyBytes
            ..followRedirects = request.followRedirects
            ..maxRedirects = request.maxRedirects
            ..persistentConnection = request.persistentConnection;
      return inner.send(replacement);
    }
    return inner.send(request);
  }

  static Map<String, dynamic> _body(http.BaseRequest request) {
    if (request is! http.Request) throw const PrivacySuppressed();
    try {
      return Map<String, dynamic>.from(jsonDecode(request.body) as Map);
    } catch (_) {
      throw const PrivacySuppressed();
    }
  }

  @override
  void close() => inner.close();
}

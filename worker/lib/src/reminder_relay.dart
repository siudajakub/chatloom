// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'ports.dart';
import 'store.dart';

bool allowedReminderRelayUrl(Uri url) =>
    url.scheme == 'http' &&
    {'127.0.0.1', '::1', '[::1]'}.contains(url.host) &&
    url.hasPort &&
    url.port > 0 &&
    url.path == '/internal/reminder' &&
    url.userInfo.isEmpty &&
    !url.hasQuery &&
    !url.hasFragment;

class ReminderWakeHint {
  final String hintId;
  final DateTime emittedAt;
  ReminderWakeHint({required this.hintId, required this.emittedAt}) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hintId)) {
      throw const WorkerFailure('invalid_reminder_hint');
    }
  }
  Map<String, Object?> toJson() => {
    'hintId': hintId,
    'emittedAt': emittedAt.toUtc().toIso8601String(),
  };
  factory ReminderWakeHint.fromJson(Map<String, dynamic> body) =>
      ReminderWakeHint(
        hintId: body['hintId'] as String,
        emittedAt: DateTime.parse(body['emittedAt'] as String),
      );
  @override
  String toString() => 'ReminderWakeHint(redacted)';
}

abstract class ReminderWakeHintSink {
  Future<void> publish(ReminderWakeHint hint);
}

class ReminderRelayDeferred extends WorkerFailure {
  final Duration retryAfter;
  const ReminderRelayDeferred(this.retryAfter)
    : super('reminder_relay_deferred');
}

class HttpReminderWakeHintSink implements ReminderWakeHintSink {
  final Uri url;
  final String token;
  final Duration timeout;
  final http.Client Function() clientFactory;
  HttpReminderWakeHintSink({
    required this.url,
    required this.token,
    this.timeout = const Duration(seconds: 5),
    http.Client Function()? clientFactory,
  }) : clientFactory = clientFactory ?? http.Client.new {
    if (!allowedReminderRelayUrl(url)) {
      throw const WorkerFailure('invalid_reminder_relay_url');
    }
    if (token.isEmpty) {
      throw const WorkerFailure('reminder_relay_credential_missing');
    }
  }
  @override
  Future<void> publish(ReminderWakeHint hint) async {
    final client = clientFactory();
    try {
      final request = http.Request('POST', url)
        ..followRedirects = false
        ..headers['Authorization'] = 'Bearer $token'
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(hint.toJson());
      final response = await client.send(request).timeout(timeout);
      await response.stream.drain<void>().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final seconds = int.tryParse(response.headers['retry-after'] ?? '');
        throw ReminderRelayDeferred(
          Duration(seconds: seconds == null ? 30 : seconds.clamp(1, 3600)),
        );
      }
    } on WorkerFailure {
      rethrow;
    } catch (_) {
      throw const WorkerFailure('reminder_relay_deferred');
    } finally {
      client.close();
    }
  }
}

/// Called only after the encrypted result was accepted by the homeserver.
ReminderWakeHint? reminderHintForPublishedResult(Map<String, dynamic> body) {
  if (body['kind'] != 'reminder.result') return null;
  final payload = body['payload'];
  if (payload is! Map ||
      payload['kind'] != 'reminder' ||
      payload['state'] != 'done' ||
      payload['due'] != true) {
    return null;
  }
  return ReminderWakeHint(
    hintId: sha256
        .convert(utf8.encode('personal-reminder:${body['opId']}'))
        .toString(),
    emittedAt: DateTime.parse(body['createdAt'] as String),
  );
}

void acknowledgePublishedReminderResult(
  WorkerStore store,
  Map<String, dynamic> body, {
  String? eventId,
}) {
  store.transaction(() {
    if (eventId != null) store.recordTranscriptPublication(body, eventId);
    final hint = reminderHintForPublishedResult(body);
    if (hint != null) store.enqueueReminderHint(hint.hintId, hint.toJson());
    store.acknowledge(body['opId'] as String);
  });
}

class ReminderHintDelivery {
  final WorkerStore store;
  final ReminderWakeHintSink? sink;
  final DateTime Function() clock;
  DateTime? _nextAttempt;
  ReminderHintDelivery(this.store, this.sink, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;
  bool get configured => sink != null;
  Future<void> flush() async {
    if (sink == null ||
        (_nextAttempt != null && clock().isBefore(_nextAttempt!))) {
      return;
    }
    for (final body in store.reminderHints) {
      final hint = ReminderWakeHint.fromJson(body);
      try {
        await sink!.publish(hint);
        store.acknowledgeReminderHint(hint.hintId);
      } catch (e) {
        _nextAttempt = clock().add(
          e is ReminderRelayDeferred
              ? e.retryAfter
              : const Duration(seconds: 30),
        );
        return;
      }
    }
  }
}

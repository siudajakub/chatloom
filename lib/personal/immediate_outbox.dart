// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

enum ImmediateSendState { accepted, unknown, failed }

class ImmediateSendResult {
  final ImmediateSendState state;
  final String actionId;
  final String transactionId;
  final String? eventId;
  final String? errorCode;
  const ImmediateSendResult({
    required this.state,
    required this.actionId,
    required this.transactionId,
    this.eventId,
    this.errorCode,
  });

  @override
  String toString() => 'ImmediateSendResult(${state.name}, redacted)';
}

/// Use only for an explicit server rejection known not to have sent a message.
/// Timeouts, connection loss and unknown upstream errors are not rejections.
class ImmediateTransportRejected implements Exception {
  final String code;
  const ImmediateTransportRejected([this.code = 'rejected']);
  @override
  String toString() => 'ImmediateTransportRejected';
}

class ImmediateOutboxFailure implements Exception {
  final String code;
  const ImmediateOutboxFailure(this.code);
  @override
  String toString() => 'ImmediateOutboxFailure($code)';
}

typedef ImmediateGet = Future<Map<String, dynamic>?> Function(String key);
typedef ImmediatePut =
    Future<void> Function(String key, Map<String, dynamic> value);
typedef ImmediateDelete = Future<void> Function(String key);
typedef ImmediateTransport =
    Future<String?> Function(
      Map<String, dynamic> frozenPayload,
      String stableTransactionId,
    );

/// Durable immediate sender. The adapters MUST address an encrypted local store
/// and a single Matrix device. Never share this sender's transaction ID across
/// different Matrix devices without explicitly reconciling the original send.
///
/// The indexed record is authoritative. Its reverse pointer is persisted before
/// the record, and the record before network I/O, so an interrupted first write
/// cannot leave a submitted operation undiscoverable after process restart.
class ImmediateOutbox {
  final String deviceId;
  final ImmediateGet get;
  final ImmediatePut put;
  final ImmediateDelete delete;
  final ImmediateTransport sendToTransport;
  final String Function() _newActionId;
  final _tails = <String, Future<void>>{};
  final _submissions = <String, Future<ImmediateSendResult>>{};

  ImmediateOutbox({
    required this.deviceId,
    required this.get,
    required this.put,
    required this.delete,
    required this.sendToTransport,
    String Function()? newActionId,
  }) : _newActionId = newActionId ?? _randomId;

  Future<ImmediateSendResult> send(
    Map<String, dynamic> payload, {
    String? actionId,
  }) async {
    late final Map<String, dynamic> frozen;
    late final String canonical;
    try {
      frozen = _freeze(jsonDecode(jsonEncode(payload))) as Map<String, dynamic>;
      canonical = jsonEncode(_canonical(frozen));
    } catch (_) {
      return _failure(actionId ?? '', 'invalidPayload');
    }
    final indexKey =
        'immediate:index:${sha256.convert(utf8.encode(canonical))}';
    final existing = _submissions[indexKey];
    if (existing != null && actionId == null) return existing;
    final operation = _serialize(
      indexKey,
      () => _send(indexKey, canonical, frozen, actionId),
    );
    _submissions[indexKey] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_submissions[indexKey], operation)) {
        _submissions.remove(indexKey);
      }
    }
  }

  Future<ImmediateSendResult> _send(
    String indexKey,
    String canonical,
    Map<String, dynamic> frozen,
    String? requestedId,
  ) async {
    Map<String, dynamic>? record;
    var id = requestedId ?? '';
    var invokedTransport = false;
    try {
      if (requestedId != null) {
        final pointer = await get('immediate:action:$requestedId');
        if (pointer?['indexKey'] != indexKey) {
          return _failure(id, 'requestMismatch');
        }
      }
      record = await get(indexKey);
      if (requestedId != null && record?['actionId'] != requestedId) {
        return _failure(id, 'actionUnavailable');
      }
      if (record != null && record['canonical'] != canonical) {
        return _failure(id, 'requestMismatch');
      }
      if (record != null && record['state'] != 'completed') {
        id = record['actionId'] as String;
        if (record['deviceId'] != deviceId) {
          return _failure(id, 'differentDeviceNeedsReconciliation');
        }
        if (record['state'] == 'accepted') return _result(record);
      } else {
        if (requestedId != null) return _failure(id, 'actionCompleted');
        id = _newActionId();
        if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) {
          return _failure('', 'invalidActionId');
        }
        if (await get('immediate:action:$id') != null) {
          return _failure(id, 'actionIdAlreadyUsed');
        }
        record = {
          'schema': 1,
          'actionId': id,
          'transactionId': 'immediate-$id',
          'deviceId': deviceId,
          'canonical': canonical,
          'payload': frozen,
          'state': 'prepared',
        };
        await put('immediate:action:$id', {'indexKey': indexKey});
        await put(indexKey, record);
      }
      // Explicit same-device retry of unknown/in-flight uses the exact same
      // Matrix transaction ID. Never retry automatically in a background loop.
      record = {...record, 'state': 'inFlight'};
      await put(indexKey, record);
      invokedTransport = true;
      final eventId = await sendToTransport(
        frozen,
        record['transactionId'] as String,
      );
      if (eventId == null || !eventId.startsWith(r'$')) {
        record = {
          ...record,
          'state': 'unknown',
          'errorCode': 'noAcceptedEvent',
        };
      } else {
        record = {...record, 'state': 'accepted', 'eventId': eventId};
        record.remove('errorCode');
      }
      await put(indexKey, record);
      return _result(record);
    } on ImmediateTransportRejected {
      if (record == null) return _failure(id, 'rejected');
      record = {...record, 'state': 'failed', 'errorCode': 'rejected'};
      try {
        await put(indexKey, record);
      } catch (_) {}
      return _result(record);
    } catch (_) {
      if (invokedTransport && record != null) {
        // A successful response may have been received but not persisted. Keep
        // inFlight/unknown until an explicit same-ID retry reconciles it.
        record = {...record, 'state': 'unknown', 'errorCode': 'unconfirmed'};
        try {
          await put(indexKey, record);
        } catch (_) {}
        return _result(record);
      }
      return _failure(id, 'storageUnavailable');
    }
  }

  /// Call only after the encrypted composer clear has completed successfully.
  /// Persist completion before any cleanup so a crash cannot resurrect a send.
  Future<void> complete(String actionId) async {
    try {
      final pointer = await get('immediate:action:$actionId');
      final indexKey = pointer?['indexKey'];
      if (indexKey is! String) return;
      await _serialize(indexKey, () async {
        final record = await get(indexKey);
        if (record == null || record['actionId'] != actionId) return;
        if (record['deviceId'] != deviceId) {
          throw const ImmediateOutboxFailure(
            'differentDeviceNeedsReconciliation',
          );
        }
        if (record['state'] == 'completed') return;
        if (record['state'] != 'accepted') {
          throw const ImmediateOutboxFailure('notAccepted');
        }
        await put(indexKey, {...record, 'state': 'completed'});
      });
    } on ImmediateOutboxFailure {
      rethrow;
    } catch (_) {
      throw const ImmediateOutboxFailure('storageUnavailable');
    }
  }

  Future<T> _serialize<T>(String key, Future<T> Function() action) async {
    final previous = _tails[key] ?? Future<void>.value();
    final operation = previous.then((_) => action());
    final tail = operation.then<void>((_) {}, onError: (Object _) {});
    _tails[key] = tail;
    try {
      return await operation;
    } finally {
      if (identical(_tails[key], tail)) _tails.remove(key);
    }
  }

  static ImmediateSendResult _result(Map<String, dynamic> record) =>
      ImmediateSendResult(
        state: switch (record['state']) {
          'accepted' => ImmediateSendState.accepted,
          'failed' => ImmediateSendState.failed,
          _ => ImmediateSendState.unknown,
        },
        actionId: record['actionId'] as String,
        transactionId: record['transactionId'] as String,
        eventId: record['eventId'] as String?,
        errorCode: record['errorCode'] as String?,
      );

  static ImmediateSendResult _failure(String id, String code) =>
      ImmediateSendResult(
        state: ImmediateSendState.failed,
        actionId: id,
        transactionId: id.isEmpty ? '' : 'immediate-$id',
        errorCode: code,
      );

  static String _randomId() {
    final random = Random.secure();
    return base64UrlEncode(List<int>.generate(24, (_) => random.nextInt(256)));
  }

  static Object? _freeze(Object? value) {
    if (value is Map) {
      return Map<String, dynamic>.unmodifiable(
        value.map((key, item) => MapEntry(key as String, _freeze(item))),
      );
    }
    if (value is List) return List<dynamic>.unmodifiable(value.map(_freeze));
    return value;
  }

  static Object? _canonical(Object? value) {
    if (value is Map<String, dynamic>) {
      final keys = value.keys.toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }
}

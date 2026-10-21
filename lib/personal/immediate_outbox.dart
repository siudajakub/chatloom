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

/// A send whose record is durable in the encrypted outbox and whose network
/// transport has not started yet. Handed to [ImmediateOutbox.send]'s
/// `onDurable` so the composer can clear at once (Telegram/Messenger) while
/// the network result later updates the message's own bubble.
class ImmediateAttempt {
  final String actionId;
  final String transactionId;
  const ImmediateAttempt({required this.actionId, required this.transactionId});

  @override
  String toString() => 'ImmediateAttempt(redacted)';
}

typedef ImmediateDurable = void Function(ImmediateAttempt attempt);

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
///
/// Identical content is coalesced into one record until that record is
/// completed, so a draft restored after a crash resends with the same Matrix
/// transaction ID instead of duplicating. A `fresh` send is a new user intent:
/// it never joins a live record this instance created (the same "ok" typed
/// twice is two messages) and takes the next free slot of that content.
class ImmediateOutbox {
  final String deviceId;
  final ImmediateGet get;
  final ImmediatePut put;
  final ImmediateDelete delete;
  final ImmediateTransport sendToTransport;
  final String Function() _newActionId;
  final _tails = <String, Future<void>>{};
  final _submissions = <String, Future<ImmediateSendResult>>{};

  /// Live actions created by this instance (this process). Records of an
  /// earlier process are not in here and are resumed, never duplicated.
  final _created = <String>{};

  /// Live records of one content a fresh send may skip before giving up.
  static const maxSlots = 64;

  ImmediateOutbox({
    required this.deviceId,
    required this.get,
    required this.put,
    required this.delete,
    required this.sendToTransport,
    String Function()? newActionId,
  }) : _newActionId = newActionId ?? _randomId;

  /// Sends [payload] once. [onDurable] runs strictly after the record is
  /// persisted as in flight and before the transport is invoked; it never
  /// runs when storage fails (the caller keeps its text). It does not run
  /// when no transport is needed (an already accepted record is returned).
  Future<ImmediateSendResult> send(
    Map<String, dynamic> payload, {
    String? actionId,
    bool fresh = false,
    ImmediateDurable? onDurable,
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
    final coalesce = actionId == null && !fresh;
    final existing = coalesce ? _submissions[indexKey] : null;
    if (existing != null) return existing;
    final operation = _send(
      indexKey,
      canonical,
      frozen,
      actionId,
      fresh && actionId == null,
      onDurable,
    );
    if (!coalesce) return operation;
    _submissions[indexKey] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_submissions[indexKey], operation)) {
        _submissions.remove(indexKey);
      }
    }
  }

  /// Explicit same-device retry of [actionId] with its stored payload and
  /// the same Matrix transaction ID (a retry button, never a loop).
  Future<ImmediateSendResult> retry(
    String actionId, {
    ImmediateDurable? onDurable,
  }) async {
    Object? payload;
    try {
      final pointer = await get('immediate:action:$actionId');
      final key = pointer?['indexKey'];
      final record = key is String ? await get(key) : null;
      if (record?['actionId'] == actionId) payload = record!['payload'];
    } catch (_) {
      return _failure(actionId, 'storageUnavailable');
    }
    if (payload is! Map) return _failure(actionId, 'actionUnavailable');
    return send(
      Map<String, dynamic>.from(payload),
      actionId: actionId,
      onDurable: onDurable,
    );
  }

  /// The stored state of [actionId] (null when unknown), for status UI.
  Future<ImmediateSendResult?> lookup(String actionId) async {
    try {
      final pointer = await get('immediate:action:$actionId');
      final key = pointer?['indexKey'];
      final record = key is String ? await get(key) : null;
      if (record == null || record['actionId'] != actionId) return null;
      return ImmediateSendResult(
        state: switch (record['state']) {
          'accepted' || 'completed' => ImmediateSendState.accepted,
          'failed' || 'discarded' => ImmediateSendState.failed,
          _ => ImmediateSendState.unknown,
        },
        actionId: actionId,
        transactionId: record['transactionId'] as String,
        eventId: record['eventId'] as String?,
        errorCode: record['errorCode'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  static bool _terminal(Object? state) =>
      state == 'completed' || state == 'discarded';

  static bool _belongs(String key, String indexKey) =>
      key == indexKey || key.startsWith('$indexKey#');

  Future<ImmediateSendResult> _send(
    String indexKey,
    String canonical,
    Map<String, dynamic> frozen,
    String? requestedId,
    bool fresh,
    ImmediateDurable? onDurable,
  ) async {
    // Choosing (and creating) the record is serialized per content, so two
    // fresh sends of the same text never take the same slot. The transport
    // runs under the record's own key: different slots send concurrently.
    final slot = await _serialize(
      'alloc:$indexKey',
      () => _allocate(indexKey, canonical, frozen, requestedId, fresh),
    );
    if (slot is ImmediateSendResult) return slot;
    final (key, id) = slot as (String, String);
    return _serialize(key, () => _transmit(key, id, frozen, onDurable));
  }

  Future<Object> _allocate(
    String indexKey,
    String canonical,
    Map<String, dynamic> frozen,
    String? requestedId,
    bool fresh,
  ) async {
    var id = requestedId ?? '';
    try {
      if (requestedId != null) {
        final pointer = await get('immediate:action:$requestedId');
        final key = pointer?['indexKey'];
        if (key is! String || !_belongs(key, indexKey)) {
          return _failure(id, 'requestMismatch');
        }
        final record = await get(key);
        if (record?['actionId'] != requestedId) {
          return _failure(id, 'actionUnavailable');
        }
        if (record!['canonical'] != canonical) {
          return _failure(id, 'requestMismatch');
        }
        if (_terminal(record['state'])) return _failure(id, 'actionCompleted');
        if (record['deviceId'] != deviceId) {
          return _failure(id, 'differentDeviceNeedsReconciliation');
        }
        return (key, requestedId);
      }
      for (var slot = 0; slot < maxSlots; slot++) {
        final key = slot == 0 ? indexKey : '$indexKey#$slot';
        final record = await get(key);
        if (record != null && record['canonical'] != canonical) {
          return _failure(id, 'requestMismatch');
        }
        if (record != null && !_terminal(record['state'])) {
          final existing = record['actionId'] as String;
          // The same text sent again in this process is another message.
          if (fresh && _created.contains(existing)) continue;
          if (record['deviceId'] != deviceId) {
            return _failure(existing, 'differentDeviceNeedsReconciliation');
          }
          return (key, existing);
        }
        id = _newActionId();
        if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) {
          return _failure('', 'invalidActionId');
        }
        if (await get('immediate:action:$id') != null) {
          return _failure(id, 'actionIdAlreadyUsed');
        }
        await put('immediate:action:$id', {'indexKey': key});
        await put(key, {
          'schema': 1,
          'actionId': id,
          'transactionId': 'immediate-$id',
          'deviceId': deviceId,
          'canonical': canonical,
          'payload': frozen,
          'state': 'prepared',
        });
        _created.add(id);
        return (key, id);
      }
      return _failure('', 'tooManyPending');
    } catch (_) {
      return _failure(id, 'storageUnavailable');
    }
  }

  Future<ImmediateSendResult> _transmit(
    String key,
    String id,
    Map<String, dynamic> frozen,
    ImmediateDurable? onDurable,
  ) async {
    Map<String, dynamic>? record;
    var invokedTransport = false;
    try {
      record = await get(key);
      if (record == null || record['actionId'] != id) {
        return _failure(id, 'actionUnavailable');
      }
      if (_terminal(record['state'])) return _failure(id, 'actionCompleted');
      if (record['state'] == 'accepted') return _result(record);
      // Explicit same-device retry of unknown/in-flight uses the exact same
      // Matrix transaction ID. Never retry automatically in a background loop.
      record = {...record, 'state': 'inFlight'};
      await put(key, record);
      final transactionId = record['transactionId'] as String;
      if (onDurable != null) {
        try {
          onDurable(
            ImmediateAttempt(actionId: id, transactionId: transactionId),
          );
        } catch (_) {
          // A UI callback never decides whether a durable message is sent.
        }
      }
      invokedTransport = true;
      final eventId = await sendToTransport(frozen, transactionId);
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
      await put(key, record);
      return _result(record);
    } on ImmediateTransportRejected catch (error) {
      if (record == null) return _failure(id, 'rejected');
      record = {...record, 'state': 'failed', 'errorCode': error.code};
      try {
        await put(key, record);
      } catch (_) {}
      return _result(record);
    } catch (_) {
      if (invokedTransport && record != null) {
        // A successful response may have been received but not persisted. Keep
        // inFlight/unknown until an explicit same-ID retry reconciles it.
        record = {...record, 'state': 'unknown', 'errorCode': 'unconfirmed'};
        try {
          await put(key, record);
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
        if (_terminal(record['state'])) return;
        if (record['state'] != 'accepted') {
          throw const ImmediateOutboxFailure('notAccepted');
        }
        await put(indexKey, {...record, 'state': 'completed'});
      });
      _created.remove(actionId);
    } on ImmediateOutboxFailure {
      rethrow;
    } catch (_) {
      throw const ImmediateOutboxFailure('storageUnavailable');
    }
  }

  /// Retires an unsent attempt the user deleted from its bubble. Its content
  /// can then be sent again as a new message. An accepted attempt is
  /// completed instead: deleting a local echo never unsends a message.
  Future<void> discard(String actionId) async {
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
        if (_terminal(record['state'])) return;
        await put(indexKey, {
          ...record,
          'state': record['state'] == 'accepted' ? 'completed' : 'discarded',
        });
      });
      _created.remove(actionId);
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

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:personal_core/personal_core.dart';

import 'pending_media_store.dart';

enum ImmediateMediaState { staged, matrixAccepted, unknown, failed, cancelled }

enum RoundBridgeDelivery { unconfirmed, delivered, rejected }

class ImmediateMediaResult {
  final String actionId, transactionId;
  final ImmediateMediaState state;
  final RoundBridgeDelivery bridgeDelivery;
  final String? eventId, errorCode;
  const ImmediateMediaResult({
    required this.actionId,
    required this.transactionId,
    required this.state,
    this.bridgeDelivery = RoundBridgeDelivery.unconfirmed,
    this.eventId,
    this.errorCode,
  });
  @override
  String toString() =>
      'ImmediateMediaResult(${state.name}, '
      '${bridgeDelivery.name}, redacted)';
}

/// Only explicit pre-dispatch denial or a known server rejection is a rejection.
class ImmediateMediaRejected implements Exception {
  final String code;
  const ImmediateMediaRejected(this.code);
  @override
  String toString() => 'ImmediateMediaRejected($code)';
}

/// Produced exclusively by Matrix SDK crypto. The outbox never implements AES.
class RoundEncryptionResult {
  final Uint8List bytes;
  final Uint8List? thumbnailBytes;
  final Map<String, dynamic> fileDescriptor;
  final Map<String, dynamic>? thumbnailDescriptor;
  RoundEncryptionResult({
    required this.bytes,
    required this.fileDescriptor,
    this.thumbnailBytes,
    this.thumbnailDescriptor,
  });
}

typedef RoundMediaGuard =
    Future<void> Function(
      RoundSendTarget target,
      RoundVideoDescriptor descriptor,
    );
typedef RoundMediaEncrypt =
    Future<RoundEncryptionResult> Function(
      Uint8List bytes,
      Uint8List? thumbnailBytes,
    );
typedef RoundMediaUpload =
    Future<Uri> Function(
      RoundSendTarget target,
      Uint8List encryptedBytes,
      String part,
    );
typedef RoundMediaSend =
    Future<String?> Function(
      RoundSendTarget target,
      Map<String, dynamic> finalContent,
      String stableTransactionId,
    );

/// One durable operation owns bytes, SDK encryption, uploads, final event and txid.
/// Retry is explicit and bound to the original Matrix account/device/destination.
class ImmediateMediaOutbox {
  final String accountId, deviceId;
  final PendingMediaRepository store;
  final RoundMediaGuard guard;
  final RoundMediaEncrypt encrypt;
  final RoundMediaUpload upload;
  final RoundMediaSend sendEvent;
  final String Function() _newActionId;
  final _tails = <String, Future<void>>{};
  ImmediateMediaOutbox({
    required this.accountId,
    required this.deviceId,
    required this.store,
    required this.guard,
    required this.encrypt,
    required this.upload,
    required this.sendEvent,
    String Function()? newActionId,
  }) : _newActionId = newActionId ?? _randomId;

  Future<ImmediateMediaResult> stage({
    required RoundSendTarget target,
    required RoundVideoDescriptor descriptor,
    required RoundEncodingProfile profile,
    required Uint8List bytes,
    Uint8List? thumbnailBytes,
    String? actionId,
  }) {
    final frozenBytes = Uint8List.fromList(bytes).asUnmodifiableView();
    final frozenThumbnail = thumbnailBytes == null
        ? null
        : Uint8List.fromList(thumbnailBytes).asUnmodifiableView();
    final fingerprint = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              target.toJson(),
              descriptor.toJson(),
              sha256.convert(frozenBytes).toString(),
              frozenThumbnail == null
                  ? null
                  : sha256.convert(frozenThumbnail).toString(),
            ]),
          ),
        )
        .toString();
    return _serialize('stage:$fingerprint', () async {
      final validation = descriptor.outgoingError(profile);
      if (validation != null ||
          descriptor.sizeBytes != frozenBytes.length ||
          !target.valid ||
          target.accountId != accountId ||
          target.deviceId != deviceId) {
        return _failed(actionId ?? '', validation ?? 'invalidFrozenTarget');
      }
      try {
        if (actionId != null) {
          final old = await store.get(actionId);
          if (old == null ||
              old.metadata['fingerprint'] != fingerprint ||
              !_owns(old))
            return _failed(actionId, 'requestMismatch');
          return _result(old);
        }
        for (final old in await recoverSummaries()) {
          if (old.metadata['fingerprint'] == fingerprint &&
              !{'completed', 'cancelled'}.contains(old.metadata['state'])) {
            final matched = await store.get(old.actionId);
            if (matched == null || !_owns(matched))
              return _failed(old.actionId, 'actionUnavailable');
            return _result(matched);
          }
        }
        final id = _newActionId();
        final record = PendingMediaRecord(
          actionId: id,
          bytes: frozenBytes,
          thumbnailBytes: frozenThumbnail,
          metadata: {
            'schema': 1,
            'accountId': accountId,
            'deviceId': deviceId,
            'transactionId': 'round-$id',
            'target': target.toJson(),
            'descriptor': descriptor.toJson(),
            'fingerprint': fingerprint,
            'state': 'staged',
            'bridgeDelivery': 'unconfirmed',
            'bridgeRevision': 0,
          },
        );
        await store.stage(record);
        final verified = await store.get(id);
        if (verified == null ||
            verified.bytes.length != frozenBytes.length ||
            sha256.convert(verified.bytes).toString() !=
                sha256.convert(frozenBytes).toString()) {
          return _failed(id, 'stagingIntegrityFailure');
        }
        return _result(verified);
      } on ImmediateMediaRejected catch (e) {
        return _failed(actionId ?? '', e.code);
      } on PendingMediaFailure catch (e) {
        return _failed(actionId ?? '', e.code);
      } catch (_) {
        return _failed(actionId ?? '', 'storageUnavailable');
      }
    });
  }

  Future<List<PendingMediaRecord>> recover() =>
      store.list(accountId: accountId, deviceId: deviceId);

  Future<List<PendingMediaSummary>> recoverSummaries() async {
    final repository = store;
    if (repository is PendingMediaSummaryRepository) {
      return (repository as PendingMediaSummaryRepository).listSummaries(
        accountId: accountId,
        deviceId: deviceId,
      );
    }
    return (await recover())
        .map(
          (record) => PendingMediaSummary(
            actionId: record.actionId,
            metadata: record.metadata,
            storedBytes: record.storedBytes,
          ),
        )
        .toList(growable: false);
  }

  Future<ImmediateMediaResult> dispatch(
    String actionId,
  ) => _serialize(actionId, () async {
    PendingMediaRecord? record;
    var dispatchStarted = false;
    var wasUnknown = false;
    try {
      record = await store.get(actionId);
      if (record == null) return _failed(actionId, 'actionUnavailable');
      if (!_owns(record))
        return _failed(actionId, 'differentSessionNeedsReconciliation');
      if (record.metadata['schema'] != 1)
        return _failed(actionId, 'unsupportedSchema');
      wasUnknown = {'unknown', 'inFlight'}.contains(record.metadata['state']);
      if ({
        'matrixAccepted',
        'completed',
        'cancelled',
      }.contains(record.metadata['state'])) {
        return _result(record);
      }
      final target = RoundSendTarget.fromJson(
        Map<String, dynamic>.from(record.metadata['target'] as Map),
      );
      final descriptor = RoundVideoDescriptor.fromJson(
        Map<String, dynamic>.from(record.metadata['descriptor'] as Map),
      );
      if (!target.valid ||
          target.accountId != accountId ||
          target.deviceId != deviceId ||
          record.metadata['transactionId'] != 'round-$actionId') {
        return _failed(actionId, 'invalidFrozenTarget');
      }
      await guard(
        target,
        descriptor,
      ); // before upload, on every explicit retry.
      if (record.encryptedBytes == null) {
        final prepared = await encrypt(record.bytes, record.thumbnailBytes);
        if (!_encryptedDescriptor(prepared.fileDescriptor) ||
            prepared.bytes.length != record.bytes.length ||
            (record.thumbnailBytes != null &&
                (prepared.thumbnailBytes == null ||
                    prepared.thumbnailBytes!.length !=
                        record.thumbnailBytes!.length ||
                    !_encryptedDescriptor(prepared.thumbnailDescriptor)))) {
          throw const ImmediateMediaRejected('invalidSdkEncryption');
        }
        final fileDescriptor = {...prepared.fileDescriptor}..remove('url');
        final thumbnailDescriptor = prepared.thumbnailDescriptor == null
            ? null
            : ({...prepared.thumbnailDescriptor!}..remove('url'));
        record = PendingMediaRecord(
          actionId: actionId,
          bytes: record.bytes,
          thumbnailBytes: record.thumbnailBytes,
          encryptedBytes: prepared.bytes,
          encryptedThumbnailBytes: prepared.thumbnailBytes,
          metadata: {
            ...record.metadata,
            'state': 'encrypted',
            'fileDescriptor': fileDescriptor,
            'thumbnailDescriptor': thumbnailDescriptor,
          },
        );
        await store.put(record); // keys and cipher BLOB are atomic before I/O.
      }
      if (record.metadata['fileUrl'] == null) {
        final uri = await upload(target, record.encryptedBytes!, 'file');
        if (!_mxc(uri))
          throw const ImmediateMediaRejected('invalidUploadResult');
        record = record.withMetadata({
          ...record.metadata,
          'state': 'fileUploaded',
          'fileUrl': uri.toString(),
        });
        await store.put(record);
      }
      if (record.encryptedThumbnailBytes != null &&
          record.metadata['thumbnailUrl'] == null) {
        final uri = await upload(
          target,
          record.encryptedThumbnailBytes!,
          'thumbnail',
        );
        if (!_mxc(uri))
          throw const ImmediateMediaRejected('invalidUploadResult');
        record = record.withMetadata({
          ...record.metadata,
          'state': 'uploaded',
          'thumbnailUrl': uri.toString(),
        });
        await store.put(record);
      }
      if (record.metadata['finalContent'] == null) {
        final info = descriptor.matrixInfo;
        if (record.metadata['thumbnailUrl'] != null) {
          info['thumbnail_file'] = {
            ...Map<String, dynamic>.from(
              record.metadata['thumbnailDescriptor'] as Map,
            ),
            'url': record.metadata['thumbnailUrl'],
          };
          info['thumbnail_info'] = {
            'mimetype': 'image/jpeg',
            'size': record.thumbnailBytes!.length,
            'w': descriptor.width,
            'h': descriptor.height,
          };
        }
        final content = <String, dynamic>{
          'msgtype': 'm.video',
          'body': 'video_message.mp4',
          'filename': 'video_message.mp4',
          'info': info,
          if (target.silent)
            telegramSendOptionsKey: {
              'version': 1,
              'silent': true,
              'schedule_date': 0,
            },
          'file': {
            ...Map<String, dynamic>.from(
              record.metadata['fileDescriptor'] as Map,
            ),
            'url': record.metadata['fileUrl'],
          },
        };
        if (target.threadEventId != null) {
          content['m.relates_to'] = {
            'rel_type': 'm.thread',
            'event_id': target.threadEventId,
            'is_falling_back': target.replyEventId == null,
            'm.in_reply_to': {
              'event_id': target.replyEventId ?? target.threadEventId,
            },
          };
        } else if (target.replyEventId != null) {
          content['m.relates_to'] = {
            'm.in_reply_to': {'event_id': target.replyEventId},
          };
        }
        record = record.withMetadata({
          ...record.metadata,
          'state': 'prepared',
          'finalContent': content,
        });
        await store.put(record);
      }
      await guard(
        target,
        descriptor,
      ); // recheck permission/capability after upload.
      record = record.withMetadata({
        ...record.metadata,
        'state': 'inFlight',
        'errorCode': null,
      });
      await store.put(record);
      dispatchStarted = true;
      final eventId = await sendEvent(
        target,
        Map<String, dynamic>.from(record.metadata['finalContent'] as Map),
        record.metadata['transactionId'] as String,
      );
      record = record.withMetadata({
        ...record.metadata,
        'state': eventId != null && eventId.startsWith(r'$')
            ? 'matrixAccepted'
            : 'unknown',
        'eventId': eventId != null && eventId.startsWith(r'$') ? eventId : null,
        'errorCode': eventId != null && eventId.startsWith(r'$')
            ? null
            : 'noAcceptedEvent',
      });
      await store.put(record);
      return _result(record);
    } on ImmediateMediaRejected catch (e) {
      return _saveFailure(
        record,
        actionId,
        wasUnknown ? 'unknown' : 'failed',
        e.code,
      );
    } on PendingMediaFailure catch (e) {
      return _saveFailure(
        record,
        actionId,
        dispatchStarted || wasUnknown ? 'unknown' : 'failed',
        e.code,
      );
    } catch (_) {
      return _saveFailure(
        record,
        actionId,
        dispatchStarted || wasUnknown ? 'unknown' : 'failed',
        dispatchStarted || wasUnknown ? 'unconfirmed' : 'preDispatchFailure',
      );
    }
  });

  /// Only the caller's authenticated/source-bound reverse-state adapter may call.
  /// Stale or contradictory updates cannot override a trusted delivery result.
  Future<bool> applyBridgeDelivery(
    String actionId, {
    required String eventId,
    required int revision,
    required RoundBridgeDelivery delivery,
  }) => _serialize(actionId, () async {
    final record = await store.get(actionId);
    if (record == null ||
        !_owns(record) ||
        record.metadata['eventId'] != eventId ||
        !{'matrixAccepted', 'completed'}.contains(record.metadata['state']) ||
        revision <= (record.metadata['bridgeRevision'] as int? ?? 0) ||
        delivery == RoundBridgeDelivery.unconfirmed ||
        (record.metadata['bridgeDelivery'] == 'delivered' &&
            delivery != RoundBridgeDelivery.delivered))
      return false;
    final updated = record.withMetadata({
      ...record.metadata,
      'bridgeDelivery': delivery.name,
      'bridgeRevision': revision,
    });
    await store.put(updated);
    if (updated.metadata['state'] == 'completed' &&
        delivery == RoundBridgeDelivery.delivered) {
      await _releaseBytes(updated);
    }
    return true;
  });

  /// After encrypted composer clear, keep an accepted tombstone to prevent resend.
  Future<void> complete(String actionId) => _serialize(actionId, () async {
    final record = await store.get(actionId);
    if (record == null || !_owns(record)) {
      throw const PendingMediaFailure('differentSessionNeedsReconciliation');
    }
    if (record.metadata['state'] == 'completed') return;
    if (record.metadata['state'] != 'matrixAccepted') {
      throw const PendingMediaFailure('notMatrixAccepted');
    }
    final completed = record.withMetadata({
      ...record.metadata,
      'state': 'completed',
    });
    await store.put(completed);
    if (completed.metadata['bridgeDelivery'] == 'delivered')
      await _releaseBytes(completed);
  });

  /// Explicit user retention cleanup of a known accepted, cleared operation.
  /// Keeps stable identity/final-content tombstone; unknown media cannot be purged.
  Future<void> purgeAcceptedMedia(String actionId) =>
      _serialize(actionId, () async {
        final record = await store.get(actionId);
        if (record == null ||
            !_owns(record) ||
            record.metadata['state'] != 'completed') {
          throw const PendingMediaFailure('needsReconciliation');
        }
        await _releaseBytes(record);
      });
  Future<void> _releaseBytes(PendingMediaRecord record) => store.put(
    PendingMediaRecord(
      actionId: record.actionId,
      bytes: Uint8List(0),
      metadata: {...record.metadata, 'bytesReleased': true},
    ),
  );

  Future<void> cancel(String actionId) => _serialize(actionId, () async {
    final record = await store.get(actionId);
    if (record == null) return;
    if (!_owns(record))
      throw const PendingMediaFailure('differentSessionNeedsReconciliation');
    if ({
      'unknown',
      'inFlight',
      'matrixAccepted',
      'completed',
    }.contains(record.metadata['state'])) {
      throw const PendingMediaFailure('needsReconciliation');
    }
    await store.put(
      record.withMetadata({...record.metadata, 'state': 'cancelled'}),
    );
    await store.remove(actionId);
  });
  Future<ImmediateMediaResult> _saveFailure(
    PendingMediaRecord? record,
    String actionId,
    String state,
    String errorCode,
  ) async {
    if (record == null) return _failed(actionId, errorCode);
    final failed = record.withMetadata({
      ...record.metadata,
      'state': state,
      'errorCode': errorCode,
    });
    try {
      await store.put(failed);
    } catch (_) {}
    return _result(failed);
  }

  bool _owns(PendingMediaRecord record) =>
      record.metadata['accountId'] == accountId &&
      record.metadata['deviceId'] == deviceId;
  Future<T> _serialize<T>(String key, Future<T> Function() action) async {
    final previous = _tails[key] ?? Future<void>.value();
    final future = previous.then((_) => action());
    final tail = future.then<void>((_) {}, onError: (Object _) {});
    _tails[key] = tail;
    try {
      return await future;
    } finally {
      if (identical(_tails[key], tail)) _tails.remove(key);
    }
  }

  static ImmediateMediaResult _result(PendingMediaRecord record) =>
      ImmediateMediaResult(
        actionId: record.actionId,
        transactionId: record.metadata['transactionId'] as String,
        state: switch (record.metadata['state']) {
          'matrixAccepted' || 'completed' => ImmediateMediaState.matrixAccepted,
          'unknown' || 'inFlight' => ImmediateMediaState.unknown,
          'failed' => ImmediateMediaState.failed,
          'cancelled' => ImmediateMediaState.cancelled,
          _ => ImmediateMediaState.staged,
        },
        eventId: record.metadata['eventId'] as String?,
        errorCode: record.metadata['errorCode'] as String?,
        bridgeDelivery: RoundBridgeDelivery.values.byName(
          record.metadata['bridgeDelivery'] as String? ?? 'unconfirmed',
        ),
      );
  static ImmediateMediaResult _failed(String id, String code) =>
      ImmediateMediaResult(
        actionId: id,
        transactionId: id.isEmpty ? '' : 'round-$id',
        state: ImmediateMediaState.failed,
        errorCode: code,
      );
  static bool _mxc(Uri value) =>
      value.scheme == 'mxc' &&
      value.host.isNotEmpty &&
      value.path.length > 1 &&
      !value.hasQuery &&
      !value.hasFragment &&
      value.userInfo.isEmpty;
  static bool _encryptedDescriptor(Map<String, dynamic>? value) {
    if (value == null ||
        value['v'] != 'v2' ||
        value['iv'] is! String ||
        value['key'] is! Map ||
        value['hashes'] is! Map)
      return false;
    final key = value['key'] as Map;
    return key['kty'] == 'oct' &&
        key['alg'] == 'A256CTR' &&
        key['k'] is String &&
        (key['k'] as String).isNotEmpty &&
        (value['hashes'] as Map)['sha256'] is String;
  }

  static String _randomId() => base64UrlEncode(
    List<int>.generate(24, (_) => Random.secure().nextInt(256)),
  );
}

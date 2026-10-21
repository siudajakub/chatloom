// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:personal_core/personal_core.dart';

import 'pending_media_store.dart';

enum ImmediateMediaState { staged, matrixAccepted, unknown, failed, cancelled }

enum RoundBridgeDelivery { unconfirmed, delivered, rejected }

/// In-memory progress of a dispatch, for the optimistic outbox row only.
/// Never persisted and never used to decide what was sent.
enum RoundSendPhase { encrypting, uploading, sending }

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
typedef RoundSendProgress =
    void Function(String actionId, RoundSendPhase? phase);

/// A draft this outbox just committed and read back, plus the SDK ciphertext
/// computed while that write ran. Memory only: the draft itself is durable.
class _StagedDraft {
  final PendingMediaRecord record;
  final PendingMediaRecord? encrypted;
  final DateTime at;
  const _StagedDraft(this.record, this.encrypted, this.at);
}

/// One durable operation owns bytes, SDK encryption, uploads, final event and txid.
/// Retry is explicit and bound to the original Matrix account/device/destination.
class ImmediateMediaOutbox {
  final String accountId, deviceId;
  final PendingMediaRepository store;
  final RoundMediaGuard guard;
  final RoundMediaEncrypt encrypt;
  final RoundMediaUpload upload;
  final RoundMediaSend sendEvent;

  /// Optional optimistic-UI hook; `null` phase = this dispatch ended.
  final RoundSendProgress? onPhase;
  final String Function() _newActionId;
  final _tails = <String, Future<void>>{};

  /// The draft this outbox staged and read back moments ago (with its early
  /// ciphertext), handed to the first dispatch so it neither re-reads and
  /// re-verifies the same BLOBs nor encrypts again. Multi-megabyte, so it is
  /// dropped after [stagedCacheLifetime], by [releaseStaged] (lock,
  /// background, skipped dispatch) and by any other operation on the action.
  final _staged = <String, _StagedDraft>{};
  static const stagedCacheLifetime = Duration(minutes: 2);
  final DateTime Function() _now;
  ImmediateMediaOutbox({
    required this.accountId,
    required this.deviceId,
    required this.store,
    required this.guard,
    required this.encrypt,
    required this.upload,
    required this.sendEvent,
    this.onPhase,
    String Function()? newActionId,
    DateTime Function()? now,
  }) : _newActionId = newActionId ?? _randomId,
       _now = now ?? DateTime.now;

  /// A fresh action ID, reserved by the caller before [stage] so the bubble
  /// (`round-<id>`) can be shown before the draft is committed.
  String newActionId() => _newActionId();

  /// Drops in-memory drafts (one, or all). Durable records are unaffected; a
  /// later dispatch reads, verifies and, if needed, encrypts from storage.
  void releaseStaged([String? actionId]) {
    if (actionId == null) {
      _staged.clear();
    } else {
      _staged.remove(actionId);
    }
  }

  _StagedDraft? _takeStaged(String actionId) {
    final draft = _staged.remove(actionId);
    if (draft == null || _now().difference(draft.at) >= stagedCacheLifetime) {
      return null;
    }
    return draft;
  }

  void _pruneStaged() => _staged.removeWhere(
    (_, draft) => _now().difference(draft.at) >= stagedCacheLifetime,
  );

  /// [record] with the ciphertext and keys that [early] computed from the
  /// same plaintext (checked by digest, memoized on both sides).
  PendingMediaRecord? _withEarlyCipher(
    PendingMediaRecord record,
    PendingMediaRecord? early,
  ) {
    if (early == null ||
        early.encryptedBytes == null ||
        pendingMediaDigest(early.bytes) != pendingMediaDigest(record.bytes) ||
        (early.thumbnailBytes == null) != (record.thumbnailBytes == null) ||
        (record.thumbnailBytes != null &&
            pendingMediaDigest(early.thumbnailBytes!) !=
                pendingMediaDigest(record.thumbnailBytes!))) {
      return null;
    }
    return PendingMediaRecord(
      actionId: record.actionId,
      bytes: record.bytes,
      thumbnailBytes: record.thumbnailBytes,
      encryptedBytes: early.encryptedBytes,
      encryptedThumbnailBytes: early.encryptedThumbnailBytes,
      metadata: {
        ...record.metadata,
        'state': 'encrypted',
        'fileDescriptor': early.metadata['fileDescriptor'],
        'thumbnailDescriptor': early.metadata['thumbnailDescriptor'],
      },
    );
  }

  /// State transitions that keep every payload use the metadata-only write
  /// when the repository offers it (no BLOB transfer, read-back or hashing).
  Future<void> _saveMetadata(PendingMediaRecord record) {
    final repository = store;
    return repository is PendingMediaMetadataRepository
        ? (repository as PendingMediaMetadataRepository).putMetadata(record)
        : repository.put(record);
  }

  /// SDK encryption of the plaintext (and thumbnail), validated, as the
  /// `encrypted` checkpoint metadata. Shared by staging and dispatch.
  Future<PendingMediaRecord> _encrypted(PendingMediaRecord record) async {
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
    return PendingMediaRecord(
      actionId: record.actionId,
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
  }

  /// Durable staging before any network: the plaintext draft is committed and
  /// read back first, so neither a crash nor an SDK encryption failure can
  /// lose the round. With [encryptWhileStaging] the SDK ciphertext is computed
  /// while that write runs and kept in memory for the first dispatch, which
  /// commits it while the uploads already run. An encryption failure here is
  /// not a staging failure: dispatch simply encrypts again.
  Future<ImmediateMediaResult> stage({
    required RoundSendTarget target,
    required RoundVideoDescriptor descriptor,
    required RoundEncodingProfile profile,
    required Uint8List bytes,
    Uint8List? thumbnailBytes,
    String? actionId,
    String? reservedActionId,
    bool encryptWhileStaging = false,
  }) async {
    _pruneStaged();
    final frozenBytes = freezePendingMediaBytes(bytes);
    final frozenThumbnail = thumbnailBytes == null
        ? null
        : freezePendingMediaBytes(thumbnailBytes);
    // Hashed once (off the UI isolate); the store reuses the memoized digest.
    final mediaDigest = await pendingMediaDigestAsync(frozenBytes);
    final fingerprint = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              target.toJson(),
              descriptor.toJson(),
              mediaDigest,
              frozenThumbnail == null
                  ? null
                  : pendingMediaDigest(frozenThumbnail),
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
        final id = reservedActionId ?? _newActionId();
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
        final repository = store;
        // The read-back verified inside the write transaction when available;
        // otherwise a separate verified read.
        final writing = repository is PendingMediaVerifiedStaging
            ? (repository as PendingMediaVerifiedStaging).stageVerified(record)
            : store.stage(record).then((_) => store.get(id));
        // Local SDK work while the plaintext commit is in flight; it never
        // decides whether the draft is saved.
        final encrypting = encryptWhileStaging
            ? _encrypted(
                record,
              ).then<PendingMediaRecord?>((r) => r, onError: (Object _) => null)
            : null;
        final verified = await writing;
        if (verified == null ||
            verified.bytes.length != frozenBytes.length ||
            pendingMediaDigest(verified.bytes) != mediaDigest) {
          return _failed(id, 'stagingIntegrityFailure');
        }
        _staged[id] = _StagedDraft(
          verified,
          encrypting == null ? null : await encrypting,
          _now(),
        );
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
      final draft = _takeStaged(actionId);
      record = draft?.record ?? await store.get(actionId);
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
      // Keys and cipher BLOB are committed while the uploads run. Nothing that
      // references them (an upload URL, the final event) is persisted or sent
      // before that write succeeded; a failed write leaves the uploads as
      // unreferenced ciphertext and the draft is encrypted again on retry.
      Future<(Object, StackTrace)?>? cipherWrite;
      if (record.encryptedBytes == null) {
        final early = _withEarlyCipher(record, draft?.encrypted);
        if (early == null) onPhase?.call(actionId, RoundSendPhase.encrypting);
        final encrypted = early ?? await _encrypted(record);
        record = encrypted;
        cipherWrite = _attemptWrite(() => store.put(encrypted));
      }
      onPhase?.call(actionId, RoundSendPhase.uploading);
      // Video and thumbnail upload concurrently; each URL that arrived is kept
      // even when the other part fails, so a retry re-uploads only what is
      // missing (same ciphertext, same keys).
      final needsFile = record.metadata['fileUrl'] == null;
      final needsThumbnail =
          record.encryptedThumbnailBytes != null &&
          record.metadata['thumbnailUrl'] == null;
      if (needsFile || needsThumbnail) {
        final cipher = record.encryptedBytes!;
        final thumbnailCipher = record.encryptedThumbnailBytes;
        final parts = await Future.wait([
          _attempt(needsFile ? () => upload(target, cipher, 'file') : null),
          _attempt(
            needsThumbnail
                ? () => upload(target, thumbnailCipher!, 'thumbnail')
                : null,
          ),
        ]);
        final cipherFailure = await cipherWrite;
        cipherWrite = null;
        if (cipherFailure != null) {
          Error.throwWithStackTrace(cipherFailure.$1, cipherFailure.$2);
        }
        final uploaded = <String, String>{
          if (parts[0].$1 != null && _mxc(parts[0].$1!))
            'fileUrl': parts[0].$1.toString(),
          if (parts[1].$1 != null && _mxc(parts[1].$1!))
            'thumbnailUrl': parts[1].$1.toString(),
        };
        final failure = parts[0].$2 ?? parts[1].$2;
        if (uploaded.isNotEmpty) {
          final metadata = {...record.metadata, ...uploaded};
          record = record.withMetadata({
            ...metadata,
            'state': metadata['fileUrl'] == null
                ? 'encrypted'
                : (record.encryptedThumbnailBytes == null ||
                      metadata['thumbnailUrl'] != null)
                ? 'uploaded'
                : 'fileUploaded',
          });
        }
        if (failure != null) {
          if (uploaded.isNotEmpty) {
            try {
              await _saveMetadata(record);
            } catch (_) {
              /* the original upload failure decides the outcome */
            }
          }
          Error.throwWithStackTrace(failure.$1, failure.$2);
        }
        if ((needsFile && uploaded['fileUrl'] == null) ||
            (needsThumbnail && uploaded['thumbnailUrl'] == null)) {
          throw const ImmediateMediaRejected('invalidUploadResult');
        }
      }
      final cipherFailure = await cipherWrite;
      if (cipherFailure != null) {
        Error.throwWithStackTrace(cipherFailure.$1, cipherFailure.$2);
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
        // Deterministic from the frozen metadata: committed together with the
        // inFlight checkpoint below (or with a failure), one write fewer.
        record = record.withMetadata({
          ...record.metadata,
          'state': 'prepared',
          'finalContent': content,
        });
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
      await _saveMetadata(record);
      dispatchStarted = true;
      onPhase?.call(actionId, RoundSendPhase.sending);
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
      await _saveMetadata(record);
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
    } finally {
      onPhase?.call(actionId, null);
    }
  });

  /// Starts [write] and keeps its failure (synchronous throws included) for
  /// the caller to decide; never an unhandled error.
  static Future<(Object, StackTrace)?> _attemptWrite(
    Future<void> Function() write,
  ) async {
    try {
      await write();
      return null;
    } catch (error, stack) {
      return (error, stack);
    }
  }

  /// Starts [upload] and keeps its value or failure (synchronous throws
  /// included) for the caller to decide; never an unhandled error.
  static Future<(Uri?, (Object, StackTrace)?)> _attempt(
    Future<Uri> Function()? upload,
  ) async {
    if (upload == null) return (null, null);
    try {
      return (await upload(), null);
    } catch (error, stack) {
      return (null, (error, stack));
    }
  }

  /// Only the caller's authenticated/source-bound reverse-state adapter may call.
  /// Stale or contradictory updates cannot override a trusted delivery result.
  Future<bool> applyBridgeDelivery(
    String actionId, {
    required String eventId,
    required int revision,
    required RoundBridgeDelivery delivery,
  }) => _serialize(actionId, () async {
    _staged.remove(actionId);
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
    await _saveMetadata(updated);
    if (updated.metadata['state'] == 'completed' &&
        delivery == RoundBridgeDelivery.delivered) {
      await _releaseBytes(updated);
    }
    return true;
  });

  /// After encrypted composer clear, keep an accepted tombstone to prevent resend.
  Future<void> complete(String actionId) => _serialize(actionId, () async {
    _staged.remove(actionId);
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
    await _saveMetadata(completed);
    if (completed.metadata['bridgeDelivery'] == 'delivered')
      await _releaseBytes(completed);
  });

  /// Explicit user retention cleanup of a known accepted, cleared operation.
  /// Keeps stable identity/final-content tombstone; unknown media cannot be purged.
  Future<void> purgeAcceptedMedia(String actionId) =>
      _serialize(actionId, () async {
        _staged.remove(actionId);
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
    _staged.remove(actionId);
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
    await _saveMetadata(
      record.withMetadata({...record.metadata, 'state': 'cancelled'}),
    );
    await store.remove(actionId);
  });

  /// The user deleted an unsent round from its bubble. Unlike [cancel],
  /// this also retires an attempt whose outcome is unknown: the bubble told
  /// the user the server may already have it, and the attempt is never
  /// sent again. An accepted round cannot be discarded.
  Future<void> discard(String actionId) => _serialize(actionId, () async {
    _staged.remove(actionId);
    final record = await store.get(actionId);
    if (record == null) return;
    if (!_owns(record)) {
      throw const PendingMediaFailure('differentSessionNeedsReconciliation');
    }
    if ({'matrixAccepted', 'completed'}.contains(record.metadata['state'])) {
      throw const PendingMediaFailure('alreadyAccepted');
    }
    await _saveMetadata(
      record.withMetadata({...record.metadata, 'state': 'cancelled'}),
    );
    await store.remove(actionId);
  });

  /// Drops the tombstone of a completed round whose bytes are already
  /// released (its event is on the server; nothing can resend it).
  Future<void> forgetCompleted(String actionId) =>
      _serialize(actionId, () async {
        _staged.remove(actionId);
        final record = await store.get(actionId);
        if (record == null ||
            !_owns(record) ||
            record.metadata['state'] != 'completed' ||
            record.metadata['bytesReleased'] != true) {
          return;
        }
        await store.remove(actionId);
      });

  /// The server's copy of an attempt whose response was lost arrived in
  /// sync (own event, this transaction ID): it was accepted after all.
  /// Returns whether the record moved to `matrixAccepted`.
  Future<bool> confirmAccepted(String actionId, String eventId) =>
      _serialize(actionId, () async {
        if (!eventId.startsWith(r'$')) return false;
        final record = await store.get(actionId);
        if (record == null ||
            !_owns(record) ||
            !{'unknown', 'inFlight'}.contains(record.metadata['state'])) {
          return false;
        }
        await _saveMetadata(
          record.withMetadata({
            ...record.metadata,
            'state': 'matrixAccepted',
            'eventId': eventId,
            'errorCode': null,
          }),
        );
        return true;
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
      await _saveMetadata(failed);
    } catch (_) {
      // E.g. a ciphertext whose own write just failed: try the full write.
      try {
        await store.put(failed);
      } catch (_) {}
    }
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

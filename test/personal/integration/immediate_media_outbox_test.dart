// SPDX-License-Identifier: AGPL-3.0-or-later
// SQLCipher-backed operation tests; deterministic SDK-style encryption fixture.
// No live accounts or real encryption interoperability claim.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:personal_core/personal_core.dart';
import '../../../lib/personal/media/immediate_media_outbox.dart';
import '../../../lib/personal/media/pending_media_store.dart';

void check(bool condition, String reason) {
  if (!condition) throw StateError(reason);
}

class FaultStore
    implements PendingMediaRepository, PendingMediaSummaryRepository {
  final PendingMediaRepository inner;
  int summaryScans = 0;
  bool failAccepted = false, failStaging = false, failUploadCheckpoint = false;
  FaultStore(this.inner);
  @override
  Future<void> stage(PendingMediaRecord r) async {
    if (failStaging) throw const PendingMediaFailure('fixtureDiskFull');
    await inner.stage(r);
  }

  @override
  Future<void> put(PendingMediaRecord r) async {
    if (r.metadata['state'] == 'matrixAccepted' && failAccepted) {
      failAccepted = false;
      throw const PendingMediaFailure('fixtureDiskFull');
    }
    if (r.metadata['state'] == 'fileUploaded' && failUploadCheckpoint) {
      failUploadCheckpoint = false;
      throw const PendingMediaFailure('fixtureDiskFull');
    }
    await inner.put(r);
  }

  @override
  Future<PendingMediaRecord?> get(String id) => inner.get(id);
  @override
  Future<List<PendingMediaRecord>> list({
    required String accountId,
    required String deviceId,
  }) => throw StateError(
    'Eager full-list scan must not be used by native summary stage',
  );
  @override
  Future<List<PendingMediaSummary>> listSummaries({
    required String accountId,
    required String deviceId,
  }) {
    summaryScans++;
    return (inner as PendingMediaSummaryRepository).listSummaries(
      accountId: accountId,
      deviceId: deviceId,
    );
  }

  @override
  Future<void> remove(String id) => inner.remove(id);
}

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('round_outbox_fixture_');
  final path = '${dir.path}/pending.sqlite';
  final key = base64UrlEncode(List<int>.filled(32, 41));
  final factory = createDatabaseFactoryFfi(noIsolate: true);
  var database = await PendingMediaStore.open(
    path: path,
    cipher: key,
    factory: factory,
  );
  try {
    var faults = FaultStore(database);
    var actions = 0, encryptions = 0, uploads = 0, requests = 0;
    var loseAck = false, rejectGuard = false, rejectTransport = false;
    Completer<void>? sendHold;
    final delivered = <String, String>{};
    final sentContents = <Map<String, dynamic>>[];
    final uploadPayloads = <String>[];
    Map<String, dynamic> encryptedDescriptor() => {
      'v': 'v2',
      'iv': 'fixture-iv',
      'key': {'kty': 'oct', 'alg': 'A256CTR', 'k': 'fixture-key-$encryptions'},
      'hashes': {'sha256': 'fixture-cipher-digest'},
    };
    ImmediateMediaOutbox outbox({String device = 'd', String account = 'a'}) =>
        ImmediateMediaOutbox(
          accountId: account,
          deviceId: device,
          store: faults,
          newActionId: () => 'fixture-${++actions}',
          guard: (target, descriptor) async {
            if (rejectGuard)
              throw const ImmediateMediaRejected('capabilityRevoked');
          },
          encrypt: (bytes, thumb) async {
            encryptions++;
            return RoundEncryptionResult(
              bytes: Uint8List.fromList(bytes.map((b) => b ^ 85).toList()),
              thumbnailBytes: thumb == null
                  ? null
                  : Uint8List.fromList(thumb.map((b) => b ^ 85).toList()),
              fileDescriptor: encryptedDescriptor(),
              thumbnailDescriptor: thumb == null ? null : encryptedDescriptor(),
            );
          },
          upload: (target, bytes, part) async {
            uploads++;
            uploadPayloads.add(base64Encode(bytes));
            return Uri.parse('mxc://fixture.invalid/upload-$uploads');
          },
          sendEvent: (target, content, txid) async {
            requests++;
            sentContents.add(content);
            await sendHold?.future;
            if (rejectTransport)
              throw const ImmediateMediaRejected('fixtureSendDenied');
            final id = delivered.putIfAbsent(
              txid,
              () => '\$fixture-${delivered.length}',
            );
            if (loseAck) {
              loseAck = false;
              throw TimeoutException('fixture lost ACK');
            }
            return id;
          },
        );
    const target = RoundSendTarget(
      accountId: 'a',
      deviceId: 'd',
      roomId: 'r',
      network: 'telegram',
      replyEventId: r'$reply',
      threadEventId: r'$thread',
      silent: true,
    );
    final bytes = Uint8List.fromList(List<int>.generate(1024, (i) => i % 256));
    final thumb = Uint8List.fromList([1, 2, 3]);
    final descriptor = RoundVideoDescriptor(
      sizeBytes: bytes.length,
      width: 384,
      height: 384,
      durationMs: 60000,
      videoCodec: 'h264',
      audioCodec: 'aac',
      cornersSanitized: true,
    );
    const profile = RoundEncodingProfile(maxSizeBytes: 100000);
    Future<ImmediateMediaResult> stage(ImmediateMediaOutbox o) => o.stage(
      target: target,
      descriptor: descriptor,
      profile: profile,
      bytes: bytes,
      thumbnailBytes: thumb,
    );
    var o = outbox();
    rejectGuard = true;
    final stagedOffline = await stage(o);
    check(
      stagedOffline.state == ImmediateMediaState.staged &&
          requests == 0 &&
          uploads == 0,
      'Capability change/offline discarded captured draft or sent',
    );
    final denied = await o.dispatch(stagedOffline.actionId);
    check(
      denied.state == ImmediateMediaState.failed && uploads == 0,
      'Guard did not block before upload',
    );
    rejectGuard = false;
    final stages = await Future.wait([stage(o), stage(o)]);
    check(
      faults.summaryScans >= 3,
      'Duplicate stage skipped metadata summary projection',
    );
    check(
      stages.first.actionId == stages.last.actionId && actions == 1,
      'Double stage generated two identities',
    );
    sendHold = Completer<void>();
    final sends = [
      o.dispatch(stagedOffline.actionId),
      o.dispatch(stagedOffline.actionId),
    ];
    await Future<void>.delayed(Duration.zero);
    sendHold.complete();
    sendHold = null;
    final accepted = await Future.wait(sends);
    check(
      requests == 1 &&
          delivered.length == 1 &&
          encryptions == 1 &&
          uploads == 2,
      'Double dispatch duplicated send/upload/encryption',
    );
    check(
      accepted.first.state == ImmediateMediaState.matrixAccepted &&
          accepted.first.bridgeDelivery == RoundBridgeDelivery.unconfirmed,
      'Matrix acceptance falsely declared Telegram delivery',
    );
    final content = sentContents.last;
    check(
      jsonEncode(content[telegramSendOptionsKey]) ==
          jsonEncode({'version': 1, 'silent': true, 'schedule_date': 0}),
      'Silent send options missing or changed',
    );
    check(
      (content['info'] as Map)[roundMessageMarker] == true &&
          (content['info'] as Map)['duration'] == 60000 &&
          content['url'] == null &&
          content['file'] is Map &&
          (content['info'] as Map)['thumbnail_file'] is Map,
      'Canonical encrypted marker/descriptors lost',
    );
    check(
      ((content['m.relates_to'] as Map)['m.in_reply_to'] as Map)['event_id'] ==
              r'$reply' &&
          (content['m.relates_to'] as Map)['event_id'] == r'$thread',
      'Frozen relations lost',
    );
    await o.complete(stagedOffline.actionId);
    check(
      (await database.get(stagedOffline.actionId))!.storedBytes > 0,
      'Unconfirmed Telegram bytes purged automatically',
    );
    check(
      await o.applyBridgeDelivery(
        stagedOffline.actionId,
        eventId: accepted.first.eventId!,
        revision: 1,
        delivery: RoundBridgeDelivery.delivered,
      ),
      'Trusted delivery not applied',
    );
    check(
      (await database.get(stagedOffline.actionId))!.storedBytes == 0,
      'Delivered operation retains quota forever',
    );
    check(
      !await o.applyBridgeDelivery(
        stagedOffline.actionId,
        eventId: accepted.first.eventId!,
        revision: 1,
        delivery: RoundBridgeDelivery.rejected,
      ),
      'Stale delivery update applied',
    );
    final retryCompleted = await o.dispatch(stagedOffline.actionId);
    check(
      retryCompleted.eventId == accepted.first.eventId && requests == 1,
      'Purged tombstone resent',
    );
    final next = await stage(o);
    check(
      next.actionId != stagedOffline.actionId,
      'New explicit capture reused completed identity',
    );
    loseAck = true;
    final unknown = await o.dispatch(next.actionId);
    check(
      unknown.state == ImmediateMediaState.unknown,
      'Lost ACK falsely failed/accepted',
    );
    rejectGuard = true;
    final stillUnknown = await o.dispatch(next.actionId);
    check(
      stillUnknown.state == ImmediateMediaState.unknown,
      'Revoked capability downgraded unknown to known failed',
    );
    rejectGuard = false;
    rejectTransport = true;
    final rejectedRetry = await o.dispatch(next.actionId);
    check(
      rejectedRetry.state == ImmediateMediaState.unknown,
      'Known retry rejection erased possible earlier acceptance',
    );
    rejectTransport = false;
    final encryptionBeforeRestart = encryptions;
    final uploadsBeforeRestart = uploads;
    final frozenBefore = jsonEncode(
      (await database.get(next.actionId))!.metadata['finalContent'],
    );
    await database.close();
    database = await PendingMediaStore.open(
      path: path,
      cipher: key,
      factory: factory,
    );
    faults = FaultStore(database);
    o = outbox();
    final retry = await o.dispatch(next.actionId);
    final beforeSilentMutation = requests + uploads;
    final changedSilent = await o.stage(
      target: RoundSendTarget.fromJson({...target.toJson(), 'silent': false}),
      descriptor: descriptor,
      profile: profile,
      bytes: bytes,
      thumbnailBytes: thumb,
      actionId: next.actionId,
    );
    check(
      changedSilent.errorCode == 'requestMismatch' &&
          requests + uploads == beforeSilentMutation,
      'Retry changed silent intent or reached transport',
    );
    final persistedSilent = (await database.get(next.actionId))!;
    check(
      (persistedSilent.metadata['target'] as Map)['silent'] == true &&
          jsonEncode(
                (persistedSilent.metadata['finalContent']
                    as Map)[telegramSendOptionsKey],
              ) ==
              jsonEncode({'version': 1, 'silent': true, 'schedule_date': 0}),
      'Restart lost frozen silent intent/options',
    );
    try {
      await database.put(
        persistedSilent.withMetadata({
          ...persistedSilent.metadata,
          'target': {
            ...(persistedSilent.metadata['target'] as Map),
            'silent': false,
          },
        }),
      );
      throw StateError('Persisted silent target mutation accepted');
    } on PendingMediaFailure catch (failure) {
      check(
        failure.code == 'immutableRecordMismatch',
        'Wrong silent mutation failure',
      );
    }
    check(
      retry.transactionId == unknown.transactionId &&
          delivered.length == 2 &&
          encryptions == encryptionBeforeRestart &&
          uploads == uploadsBeforeRestart &&
          jsonEncode(sentContents.last) == frozenBefore,
      'Restart retry changed identity/content/key/upload or duplicated',
    );
    final wrongDevice = await outbox(device: 'foreign').dispatch(next.actionId);
    check(
      wrongDevice.errorCode == 'differentSessionNeedsReconciliation',
      'Device isolation failed',
    );
    final wrongAccount = await outbox(
      account: 'foreign',
    ).dispatch(next.actionId);
    check(
      wrongAccount.errorCode == 'differentSessionNeedsReconciliation',
      'Account isolation failed',
    );
    await o.complete(next.actionId);
    await o.purgeAcceptedMedia(next.actionId);
    final third = await stage(o);
    faults.failAccepted = true;
    final storageAckLoss = await o.dispatch(third.actionId);
    check(
      storageAckLoss.state == ImmediateMediaState.unknown,
      'Accepted persistence failure reported success',
    );
    final deliveredBefore = delivered.length;
    final repaired = await o.dispatch(third.actionId);
    check(
      repaired.state == ImmediateMediaState.matrixAccepted &&
          delivered.length == deliveredBefore,
      'Persistence repair duplicated send',
    );
    await o.complete(third.actionId);
    await o.purgeAcceptedMedia(third.actionId);
    faults.failStaging = true;
    final beforeNetwork = requests + uploads;
    final full = await stage(o);
    check(
      full.state == ImmediateMediaState.failed &&
          requests + uploads == beforeNetwork,
      'Network before durable staging',
    );
    faults.failStaging = false;
    final fourth = await stage(o);
    faults.failUploadCheckpoint = true;
    final checkpointFailure = await o.dispatch(fourth.actionId);
    check(
      checkpointFailure.state == ImmediateMediaState.failed,
      'Pre-dispatch storage failure not distinguished',
    );
    final encryptedCount = encryptions;
    final firstCipher = uploadPayloads.last;
    final recoveredUpload = await o.dispatch(fourth.actionId);
    check(
      recoveredUpload.state == ImmediateMediaState.matrixAccepted &&
          encryptions == encryptedCount &&
          uploadPayloads[uploadPayloads.length - 2] == firstCipher,
      'Lost upload checkpoint changed encryption keys/bytes',
    );
    check(
      !recoveredUpload.toString().contains('fixture-key'),
      'Result leaks descriptors',
    );
    stdout.writeln(
      'PASS SQLCipher media outbox offline stage, double tap, canonical encrypted '
      'content/relations, lost ACK/restart/stable keys+txid, account/device guards, '
      'disk faults, upload checkpoint, distinct delivery and safe tombstone cleanup',
    );
  } finally {
    await database.close();
    await dir.delete(recursive: true);
  }
}

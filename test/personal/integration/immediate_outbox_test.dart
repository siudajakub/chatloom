// SPDX-License-Identifier: AGPL-3.0-or-later
// Standalone Dart regression tests with fault-injected durable store/transport.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../lib/personal/immediate_outbox.dart';

class MemoryStore {
  final records = <String, Map<String, dynamic>>{};
  bool rejectAcceptedWrite = false;
  bool rejectPreparedWrite = false;
  Future<Map<String, dynamic>?> get(String key) async => records[key] == null
      ? null
      : Map<String, dynamic>.from(jsonDecode(jsonEncode(records[key])) as Map);
  Future<void> put(String key, Map<String, dynamic> value) async {
    if (value['state'] == 'accepted' && rejectAcceptedWrite) {
      rejectAcceptedWrite = false;
      throw StateError('secret-canary store failure');
    }
    // The first write of a new attempt (its record, created inFlight).
    if (rejectPreparedWrite &&
        value.containsKey('payload') &&
        records[key]?['actionId'] != value['actionId']) {
      throw StateError('secret-canary store failure');
    }
    records[key] = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(value)) as Map,
    );
  }

  Future<void> delete(String key) async => records.remove(key);
}

void check(bool condition, String reason) {
  if (!condition) throw StateError(reason);
}

Future<void> main() async {
  final payload = <String, dynamic>{
    'accountId': 'fixture-account',
    'roomId': 'fixture-room',
    'text': 'fixture-text',
    'replyId': null,
    'editId': null,
    'threadId': null,
    'parseCommands': false,
  };
  final store = MemoryStore();
  var actions = 0, requests = 0;
  final delivered = <String, String>{};
  var timeoutAfterAccept = false;
  Completer<void>? hold;
  Future<String?> transport(Map<String, dynamic> sent, String txn) async {
    requests++;
    await hold?.future;
    final event = delivered.putIfAbsent(
      txn,
      () => '\$fixture-${delivered.length}',
    );
    if (timeoutAfterAccept) {
      timeoutAfterAccept = false;
      throw TimeoutException('secret-canary network failure');
    }
    return event;
  }

  ImmediateOutbox instance({String device = 'device-a'}) => ImmediateOutbox(
    deviceId: device,
    get: store.get,
    put: store.put,
    delete: store.delete,
    sendToTransport: transport,
    newActionId: () => 'action-${++actions}',
  );
  var outbox = instance();
  final first = await outbox.send(payload);
  check(first.state == ImmediateSendState.accepted, 'First send failed');
  // READ or encrypted draft clear failed after acceptance. Caller retries the
  // clear/receipt, never a second new logical transport request.
  final repeated = await outbox.send(payload);
  check(
    repeated.actionId == first.actionId && requests == 1,
    'Post-send failure caused resend',
  );
  outbox = instance();
  final afterRestart = await outbox.send(payload);
  check(
    afterRestart.eventId == first.eventId && requests == 1,
    'Restart after acceptance caused resend',
  );
  await outbox.complete(first.actionId);
  await outbox.complete(first.actionId);
  final logicalRepeat = await outbox.send(payload);
  check(
    logicalRepeat.actionId != first.actionId && delivered.length == 2,
    'Intentional repeated message suppressed after completion',
  );
  await outbox.complete(logicalRepeat.actionId);

  timeoutAfterAccept = true;
  final unknown = await outbox.send(payload);
  check(
    unknown.state == ImmediateSendState.unknown,
    'Ambiguity not represented',
  );
  final beforeRetryDelivered = delivered.length;
  outbox = instance();
  final retry = await outbox.send(payload, actionId: unknown.actionId);
  check(
    retry.transactionId == unknown.transactionId &&
        retry.state == ImmediateSendState.accepted &&
        delivered.length == beforeRetryDelivered,
    'Timeout retry duplicated',
  );
  await outbox.complete(retry.actionId);

  hold = Completer<void>();
  final beforeConcurrent = requests;
  final concurrent = List.generate(12, (_) => outbox.send(payload));
  await Future<void>.delayed(Duration.zero);
  hold.complete();
  hold = null;
  final answers = await Future.wait(concurrent);
  check(
    requests == beforeConcurrent + 1 &&
        answers.map((r) => r.actionId).toSet().length == 1,
    'Concurrent submission did not coalesce',
  );
  final concurrentAction = answers.first.actionId;
  final wrongDevice = await instance(device: 'device-b').send(payload);
  check(
    wrongDevice.state == ImmediateSendState.failed &&
        wrongDevice.errorCode == 'differentDeviceNeedsReconciliation',
    'Another Matrix device resumed original transaction',
  );
  final beforeMutation = requests;
  final changed = await outbox.send({
    ...payload,
    'roomId': 'other-fixture-room',
  }, actionId: concurrentAction);
  check(
    changed.errorCode == 'requestMismatch' && requests == beforeMutation,
    'Pinned action changed target',
  );
  await outbox.complete(concurrentAction);

  store.rejectAcceptedWrite = true;
  final persistenceFailure = await outbox.send(payload);
  check(
    persistenceFailure.state == ImmediateSendState.unknown,
    'Failed accepted-state persistence reported success',
  );
  final persistDelivered = delivered.length;
  outbox = instance();
  final persistenceRetry = await outbox.send(
    payload,
    actionId: persistenceFailure.actionId,
  );
  check(
    persistenceRetry.transactionId == persistenceFailure.transactionId &&
        delivered.length == persistDelivered,
    'Persistence retry duplicated',
  );
  await outbox.complete(persistenceRetry.actionId);

  store.rejectPreparedWrite = true;
  final beforeUnstored = requests;
  final failedStore = await outbox.send(payload);
  check(
    failedStore.state == ImmediateSendState.failed &&
        requests == beforeUnstored,
    'Send occurred before durable storage',
  );
  store.rejectPreparedWrite = false;

  final mutable = {...payload};
  hold = Completer<void>();
  final frozenFuture = outbox.send(mutable);
  mutable['roomId'] = 'mutated-after-click';
  await Future<void>.delayed(Duration.zero);
  hold.complete();
  hold = null;
  final frozen = await frozenFuture;
  final record = store.records.values.firstWhere(
    (v) => v['actionId'] == frozen.actionId && v.containsKey('payload'),
  );
  check(
    (record['payload'] as Map)['roomId'] == 'fixture-room',
    'Caller mutation changed frozen target',
  );
  check(!frozen.toString().contains('fixture-text'), 'Result leaked content');
  await outbox.complete(frozen.actionId);

  // Durable callback: strictly after the in-flight record is persisted and
  // before the transport; the composer clears there, not after the network.
  final order = <String>[];
  hold = Completer<void>();
  final durablePayload = {...payload, 'text': 'durable-text'};
  final durable = outbox.send(
    durablePayload,
    fresh: true,
    onDurable: (attempt) {
      final stored = store.records.values.where(
        (v) => v['actionId'] == attempt.actionId && v.containsKey('payload'),
      );
      check(
        stored.length == 1 && stored.single['state'] == 'inFlight',
        'Durable callback before the record was persisted',
      );
      check(
        attempt.transactionId == 'immediate-${attempt.actionId}',
        'Durable attempt lost its transaction ID',
      );
      check(!attempt.toString().contains('durable'), 'Attempt leaked content');
      order.add('durable:${attempt.actionId}');
    },
  );
  await Future<void>.delayed(Duration.zero);
  check(order.length == 1, 'Durable callback waited for the network');
  final beforeRelease = requests;
  hold.complete();
  hold = null;
  final durableResult = await durable;
  check(
    durableResult.state == ImmediateSendState.accepted &&
        requests == beforeRelease &&
        order.single == 'durable:${durableResult.actionId}',
    'Durable send did not complete once',
  );
  await outbox.complete(durableResult.actionId);

  // Storage failure: no callback, no transport; the caller keeps its text.
  store.rejectPreparedWrite = true;
  var called = false;
  final beforeFail = requests;
  final noStore = await outbox.send(
    {...payload, 'text': 'unstored-text'},
    fresh: true,
    onDurable: (_) => called = true,
  );
  check(
    !called &&
        noStore.state == ImmediateSendState.failed &&
        requests == beforeFail,
    'Callback or transport ran without durable storage',
  );
  store.rejectPreparedWrite = false;

  // A throwing UI callback never stops a durable send.
  final throwing = await outbox.send(
    {...payload, 'text': 'callback-throws'},
    fresh: true,
    onDurable: (_) => throw StateError('fixture'),
  );
  check(
    throwing.state == ImmediateSendState.accepted,
    'Callback failure blocked the send',
  );
  await outbox.complete(throwing.actionId);

  // The same text sent twice in one process is two messages, sent
  // concurrently with different transaction IDs.
  final repeatPayload = {...payload, 'text': 'ok'};
  hold = Completer<void>();
  final beforeRepeat = requests;
  final firstOk = outbox.send(repeatPayload, fresh: true);
  final secondOk = outbox.send(repeatPayload, fresh: true);
  await Future<void>.delayed(const Duration(milliseconds: 1));
  check(requests == beforeRepeat + 2, 'Fresh sends were serialized');
  hold.complete();
  hold = null;
  final oks = await Future.wait([firstOk, secondOk]);
  check(
    oks[0].transactionId != oks[1].transactionId &&
        oks.every((r) => r.state == ImmediateSendState.accepted),
    'Repeated fresh text was coalesced',
  );
  // Accepted but not completed (crash before the draft clear): after a
  // restart the same text resumes the first live record, never resends.
  outbox = instance();
  final beforeResume = requests;
  final resumed = await outbox.send(repeatPayload, fresh: true);
  check(
    resumed.actionId == oks[0].actionId && requests == beforeResume,
    'Restart duplicated an accepted fresh send',
  );
  await outbox.complete(oks[0].actionId);
  await outbox.complete(oks[1].actionId);

  // Retry from the bubble keeps the transaction ID; delete retires it.
  timeoutAfterAccept = true;
  final shaky = await outbox.send({...payload, 'text': 'shaky'}, fresh: true);
  check(shaky.state == ImmediateSendState.unknown, 'Unknown not kept');
  check(
    (await outbox.lookup(shaky.actionId))?.state == ImmediateSendState.unknown,
    'Lookup lost the unknown state',
  );
  var retried = false;
  final bubbleRetry = await outbox.retry(
    shaky.actionId,
    onDurable: (_) => retried = true,
  );
  check(
    retried &&
        bubbleRetry.transactionId == shaky.transactionId &&
        bubbleRetry.state == ImmediateSendState.accepted,
    'Retry changed the transaction ID',
  );
  timeoutAfterAccept = true;
  final dropped = await outbox.send({...payload, 'text': 'drop'}, fresh: true);
  await outbox.discard(dropped.actionId);
  check(
    (await outbox.retry(dropped.actionId)).errorCode == 'actionCompleted',
    'A deleted attempt could be retried',
  );
  outbox = instance();
  final again = await outbox.send({...payload, 'text': 'drop'}, fresh: true);
  check(
    again.actionId != dropped.actionId,
    'A deleted attempt was resumed instead of sending a new message',
  );
  check(
    (await outbox.lookup('missing-action')) == null,
    'Lookup invented a record',
  );

  // CC-02: once no draft holds a text (markConsumed: the composer cleared
  // and saved its draft), an identical send after a restart is a new
  // message, never the old attempt resumed, whatever state it is in. The
  // old bubble still retries its own attempt.
  timeoutAfterAccept = true;
  final unconfirmed = await outbox.send({
    ...payload,
    'text': 'consumed',
  }, fresh: true);
  check(unconfirmed.state == ImmediateSendState.unknown, 'Unknown not kept');
  await outbox.markConsumed(unconfirmed.actionId);
  await outbox.markConsumed(unconfirmed.actionId);
  final acceptedConsumed = await outbox.send({
    ...payload,
    'text': 'consumed-accepted',
  }, fresh: true);
  check(
    acceptedConsumed.state == ImmediateSendState.accepted,
    'Fixture send failed',
  );
  await outbox.markConsumed(acceptedConsumed.actionId);
  outbox = instance();
  final beforeConsumed = requests;
  final newUnknownText = await outbox.send({
    ...payload,
    'text': 'consumed',
  }, fresh: true);
  check(
    newUnknownText.actionId != unconfirmed.actionId &&
        newUnknownText.transactionId != unconfirmed.transactionId &&
        requests == beforeConsumed + 1,
    'A consumed unknown attempt swallowed a new message',
  );
  final newAcceptedText = await outbox.send({
    ...payload,
    'text': 'consumed-accepted',
  }, fresh: true);
  check(
    newAcceptedText.actionId != acceptedConsumed.actionId &&
        newAcceptedText.state == ImmediateSendState.accepted &&
        requests == beforeConsumed + 2,
    'A consumed accepted attempt swallowed a new message',
  );
  final ownRetry = await outbox.retry(unconfirmed.actionId);
  check(
    ownRetry.transactionId == unconfirmed.transactionId,
    'A consumed attempt lost its own retry',
  );
  await outbox.markConsumed('missing-action');
  stdout.writeln(
    'PASS immediate outbox acceptance retention, crash/retry, '
    'concurrency, device isolation, immutable target, storage fault, '
    'durable callback, fresh repeat, retry, delete and consumed tests',
  );
}

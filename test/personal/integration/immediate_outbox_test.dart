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
    if (value['state'] == 'prepared' && rejectPreparedWrite) {
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
  stdout.writeln(
    'PASS immediate outbox acceptance retention, crash/retry, '
    'concurrency, device isolation, immutable target and storage fault tests',
  );
}

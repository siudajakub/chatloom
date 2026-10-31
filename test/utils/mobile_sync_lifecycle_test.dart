// SPDX-License-Identifier: AGPL-3.0-or-later
// The phone's sync loop across app lifecycle changes (2026-10-31): stopped
// in the background with no retries or polling, an immediate catch-up on
// return, quick retries after a failure, a quiet connection status, and the
// push catch-up working with the loop stopped. Synthetic offline client; no
// network, account or storage.
import 'dart:async';

import 'package:chatloom/personal/connection_status.dart';
import 'package:chatloom/utils/background_push_catch_up.dart';
import 'package:chatloom/utils/mobile_sync_lifecycle.dart';
import 'package:chatloom/utils/sync_network_recovery.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

class _Database implements DatabaseApi {
  @override
  Future<void> transaction(Future<void> Function() action) => action();
  @override
  Future<void> deleteOldFiles(int savedAt) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Every `/sync` waits until the test answers it.
class _HangingClient extends Client {
  _HangingClient() : super('synthetic-lifecycle', database: _Database());
  final timeouts = <int?>[];
  final requests = <Completer<SyncUpdate>>[];
  @override
  bool isLogged() => true;
  @override
  String get syncFilterId => 'synthetic-filter';
  @override
  String? get prevBatch => 'synthetic-batch';
  @override
  Future<SyncUpdate> sync({
    String? filter,
    String? since,
    bool? fullState,
    PresenceType? setPresence,
    int? timeout,
    bool? useStateAfter,
  }) {
    timeouts.add(timeout);
    final request = Completer<SyncUpdate>();
    requests.add(request);
    return request.future;
  }

  @override
  Future<void> updateUserDeviceKeys({Set<String>? additionalUsers}) async {}
  @override
  Future<void> processToDeviceQueue() async {}

  void answer(int index) =>
      requests[index].complete(SyncUpdate(nextBatch: 'synthetic-batch'));

  void drop(int index) =>
      requests[index].completeError(const _SocketExceptionFixture());
}

class _SocketExceptionFixture implements Exception {
  const _SocketExceptionFixture();
}

class _Phone {
  _Phone() {
    // As `ClientManager.createClient` sets it for the app's clients.
    client.quickSyncRetry = true;
    client.syncErrorMaxTimeoutSec = foregroundSyncRetryCapSec;
    monitor.addListener(() {
      if (seen.isEmpty || seen.last != monitor.value) seen.add(monitor.value);
    });
    lifecycle.seed(AppLifecycleState.resumed);
    // The loop as the startup leaves it (`backgroundSync` is on by default;
    // its setter would start the sync outside the fake clock's zone).
    unawaited(client.oneShotSync());
  }

  final client = _HangingClient();
  bool network = true;
  final seen = <ConnectionPhase>[];
  late final monitor = ConnectionStatusMonitor(
    statuses: () => client.onSyncStatus.stream,
    current: () => client.onSyncStatus.value,
    firstSync: () => client.prevBatch == null,
    hasNetwork: () async => network,
    quickRequest: () => client.syncRequestTimeout == Duration.zero,
  );
  late final lifecycle = MobileSyncLifecycle(
    clients: () => [client],
    monitorOf: (_) => monitor,
  );

  /// Android's order when the user switches away and back.
  void leave() {
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      lifecycle.onLifecycle(state);
    }
  }

  void comeBack() {
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      lifecycle.onLifecycle(state);
    }
  }

  void close(FakeAsync clock) {
    client.backgroundSync = false;
    unawaited(client.dispose(closeDatabase: false));
    monitor.dispose();
    clock.elapse(const Duration(minutes: 2));
  }
}

void main() {
  test('the notification shade neither stops nor restarts the loop', () {
    fakeAsync((clock) {
      final phone = _Phone();
      clock.flushMicrotasks();
      expect(phone.client.timeouts, [30000]);
      phone.lifecycle.onLifecycle(AppLifecycleState.inactive);
      phone.lifecycle.onLifecycle(AppLifecycleState.resumed);
      clock.flushMicrotasks();
      expect(phone.client.timeouts, [30000]);
      expect(phone.lifecycle.foreground, isTrue);
      phone.close(clock);
    });
  });

  test('background: the loop stops, nothing retries, polls or shows', () {
    fakeAsync((clock) {
      final phone = _Phone();
      clock.flushMicrotasks();
      phone.leave();
      expect(phone.lifecycle.foreground, isFalse);
      // The system cuts the app's network: the last long-poll dies.
      phone.network = false;
      phone.client.drop(0);
      clock.flushMicrotasks();
      expect(
        phone.client.onSyncStatus.value?.status,
        SyncStatus.error,
        reason: 'the SDK reports it',
      );
      clock.elapse(const Duration(hours: 1));
      expect(phone.client.timeouts, [30000], reason: 'no retry, no polling');
      expect(phone.seen, isEmpty, reason: 'nobody is told "offline"');
      expect(clock.pendingTimers, isEmpty, reason: 'nothing left to wake up');
      phone.close(clock);
    });
  });

  test('a long-poll answering in the background starts no new one', () {
    fakeAsync((clock) {
      final phone = _Phone();
      clock.flushMicrotasks();
      phone.leave();
      // The server answers the last long-poll within its 30 s.
      clock.elapse(const Duration(seconds: 12));
      phone.client.answer(0);
      clock.flushMicrotasks();
      expect(phone.client.onSyncStatus.value?.status, SyncStatus.finished);
      clock.elapse(const Duration(hours: 1));
      expect(phone.client.timeouts, [30000], reason: 'the loop stopped');
      expect(phone.seen, isEmpty);
      expect(clock.pendingTimers, isEmpty);
      phone.close(clock);
    });
  });

  test('coming back syncs at once and drops the long-poll from before', () {
    fakeAsync((clock) {
      final phone = _Phone();
      clock.flushMicrotasks();
      phone.leave();
      // A short switch: the long-poll from before is still waiting, perhaps
      // on a socket the background killed.
      clock.elapse(const Duration(seconds: 20));
      phone.comeBack();
      clock.flushMicrotasks();
      expect(phone.client.timeouts, [
        30000,
        0,
      ], reason: 'zero-timeout catch-up');
      expect(phone.monitor.raw, ConnectionPhase.updating);
      // Its late failure is ignored, not reported as a failed sync.
      phone.client.drop(0);
      clock.flushMicrotasks();
      expect(phone.client.onSyncStatus.value?.status, isNot(SyncStatus.error));
      // The catch-up answers within the grace: nothing shows; the loop
      // long-polls again.
      clock.elapse(const Duration(milliseconds: 500));
      phone.client.answer(1);
      clock.flushMicrotasks();
      expect(phone.client.timeouts, [30000, 0, 30000]);
      clock.elapse(const Duration(seconds: 5));
      expect(phone.seen, isEmpty);
      phone.close(clock);
    });
  });

  test('a slow catch-up keeps a long-poll\'s budget and says "Updating…"', () {
    fakeAsync((clock) {
      final phone = _Phone();
      clock.flushMicrotasks();
      phone.leave();
      phone.client.answer(0);
      clock.elapse(const Duration(hours: 8));
      phone.comeBack();
      clock.flushMicrotasks();
      expect(phone.client.timeouts, [30000, 0]);
      // A night's backlog on a slow network: not cut off after 10 s (and
      // fetched twice), only a quiet "Updating…" meanwhile.
      clock.elapse(const Duration(seconds: 25));
      expect(phone.client.timeouts, [30000, 0], reason: 'not retried');
      expect(phone.client.onSyncStatus.value?.status, isNot(SyncStatus.error));
      expect(phone.seen, [ConnectionPhase.updating]);
      phone.client.answer(1);
      clock.flushMicrotasks();
      expect(phone.seen, [ConnectionPhase.updating, ConnectionPhase.online]);
      expect(phone.client.timeouts, [30000, 0, 30000]);
      phone.close(clock);
    });
  });

  test('a catch-up that reported nothing leaves no "Updating…"', () {
    fakeAsync((clock) {
      final phone = _Phone();
      clock.flushMicrotasks();
      // As while the client initialises: the sync returns at once without
      // any status.
      final lifecycle = MobileSyncLifecycle(
        clients: () => [phone.client],
        monitorOf: (_) => phone.monitor,
        apply:
            (Client client, {required bool foreground, bool catchUp = false}) =>
                catchUp ? Future<void>.value() : null,
      )..seed(AppLifecycleState.resumed);
      lifecycle.onLifecycle(AppLifecycleState.paused);
      lifecycle.onLifecycle(AppLifecycleState.resumed);
      expect(phone.monitor.raw, ConnectionPhase.updating);
      clock.flushMicrotasks();
      expect(phone.monitor.raw, ConnectionPhase.online);
      clock.elapse(const Duration(seconds: 5));
      expect(phone.seen, isEmpty);
      phone.close(clock);
    });
  });

  test('a failure right after coming back retries fast and stays quiet', () {
    fakeAsync((clock) {
      final phone = _Phone();
      clock.flushMicrotasks();
      phone.leave();
      // An error the background caused before the return.
      phone.client.drop(0);
      clock.elapse(const Duration(minutes: 30));
      phone.network = false; // Still blocked for a moment after the return.
      phone.comeBack();
      clock.flushMicrotasks();
      expect(phone.client.timeouts, [30000, 0]);
      // The catch-up hits a dead pooled socket.
      phone.client.drop(1);
      phone.network = true;
      clock.elapse(const Duration(seconds: 3));
      // The SDK's first retry comes after 3 s and asks for an answer at
      // once, with a long-poll's response budget.
      expect(phone.client.timeouts, [30000, 0, 0]);
      phone.client.answer(2);
      clock.flushMicrotasks();
      expect(phone.client.timeouts, [30000, 0, 0, 30000]);
      clock.elapse(const Duration(seconds: 20));
      expect(phone.seen, [ConnectionPhase.updating, ConnectionPhase.online]);
      expect(phone.seen.where((phase) => phase.offline), isEmpty);
      expect(phone.monitor.lasting, isFalse);
      phone.close(clock);
    });
  });

  test('only a quick request can stall; a healthy long-poll never does', () {
    fakeAsync((clock) {
      final phone = _Phone();
      clock.flushMicrotasks();
      // The long-poll fails once; the retry timer is pending.
      phone.client.drop(0);
      clock.flushMicrotasks();
      // Something starts a plain long-poll before the retry (the startup or
      // a desktop window coming back).
      unawaited(phone.client.oneShotSync());
      clock.flushMicrotasks();
      expect(phone.client.timeouts, [30000, 30000]);
      expect(phone.client.syncRequestTimeout, const Duration(seconds: 30));
      clock.elapse(const Duration(seconds: 25));
      expect(phone.seen, isEmpty, reason: 'waiting is what a long-poll does');
      phone.client.answer(1);
      clock.flushMicrotasks();
      // The quick retry after a failure does stall when the server is silent.
      phone.client.drop(2);
      clock.elapse(const Duration(seconds: 3));
      expect(phone.client.timeouts.last, 0);
      expect(phone.client.syncRequestTimeout, Duration.zero);
      clock.elapse(const Duration(seconds: 9));
      expect(phone.monitor.value, ConnectionPhase.connecting);
      phone.client.answer(3);
      clock.flushMicrotasks();
      expect(phone.monitor.value, ConnectionPhase.online);
      phone.close(clock);
    });
  });

  test('really offline after coming back: quiet line, then lasting', () {
    fakeAsync((clock) {
      final phone = _Phone();
      clock.flushMicrotasks();
      phone.leave();
      phone.network = false;
      phone.comeBack();
      clock.flushMicrotasks();
      phone.client.drop(1);
      clock.elapse(const Duration(seconds: 3));
      phone.client.drop(2);
      clock.flushMicrotasks();
      expect(phone.monitor.value, ConnectionPhase.waitingForNetwork);
      expect(phone.monitor.lasting, isFalse);
      // Retries keep failing at once; after 30 s it is worth a notice.
      for (var i = 3; i < 8; i++) {
        clock.elapse(const Duration(seconds: 20));
        if (phone.client.requests.length > i) phone.client.drop(i);
        clock.flushMicrotasks();
      }
      expect(phone.monitor.lasting, isTrue);
      expect(
        phone.client.timeouts.skip(1),
        everyElement(0),
        reason: 'every retry is a quick one',
      );
      // The network returns: the next retry gets through at once.
      phone.network = true;
      unawaited(syncNow(phone.client));
      clock.flushMicrotasks();
      phone.client.answer(phone.client.requests.length - 1);
      clock.flushMicrotasks();
      expect(phone.monitor.value, ConnectionPhase.online);
      expect(phone.monitor.lasting, isFalse);
      phone.close(clock);
    });
  });

  // Real async: the catch-up awaits stream cancellations, which complete in
  // the root zone where a fake clock cannot flush them.
  test(
    'the push catch-up syncs with the loop stopped and starts no loop',
    () async {
      final phone = _Phone();
      await pumpEventQueue();
      phone.leave();
      phone.client.answer(0);
      await pumpEventQueue();
      expect(phone.client.timeouts, [30000], reason: 'the loop stopped');
      final catchUp = PushCatchUp(
        minInterval: Duration.zero,
        notify: (_, arrived) async => arrived.length,
      );
      final first = catchUp.run(phone.client)!;
      await pumpEventQueue();
      expect(phone.client.timeouts, [30000, 0]);
      phone.client.answer(1);
      expect(await first, 0, reason: 'synced; nothing new to alert');
      // A failing push catch-up neither retries nor shows anything.
      final second = catchUp.run(phone.client)!;
      await pumpEventQueue();
      phone.client.drop(2);
      expect(await second, isNull);
      await pumpEventQueue();
      expect(phone.client.timeouts, [30000, 0, 0], reason: 'no retry, no loop');
      expect(phone.seen, isEmpty);
      phone.client.backgroundSync = false;
      await phone.client.dispose(closeDatabase: false);
      phone.monitor.dispose();
    },
  );
}

// SPDX-License-Identifier: AGPL-3.0-or-later
// Network transitions restart a long-poll stuck on a dead socket (review R4).
// Synthetic offline client; no network, account or storage.
import 'dart:async';

import 'package:chatloom/utils/sync_network_recovery.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fake_async/fake_async.dart';
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

/// Every `/sync` hangs until the test answers it, like a long-poll whose
/// socket belonged to a network that went away.
class _HangingClient extends Client {
  _HangingClient({this.initial = false})
    : super('synthetic-hanging', database: _Database());
  final bool initial;
  final timeouts = <int?>[];
  final requests = <Completer<SyncUpdate>>[];
  @override
  bool isLogged() => true;
  @override
  String get syncFilterId => 'synthetic-filter';
  @override
  String? get prevBatch => initial ? null : 'synthetic-batch';
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
}

void main() {
  test('a network switch drops the waiting long-poll and syncs at once', () {
    fakeAsync((clock) {
      final client = _HangingClient();
      var processed = 0;
      final statuses = <SyncStatus>[];
      client.onSync.stream.listen((_) => processed++);
      client.onSyncStatus.stream.listen((s) => statuses.add(s.status));
      final recovery = SyncNetworkRecovery(foreground: () => true);

      unawaited(client.oneShotSync());
      clock.flushMicrotasks();
      expect(client.timeouts, [30000]);

      // The first report is the current network, then capability repeats.
      for (final networks in [
        [ConnectivityResult.wifi],
        [ConnectivityResult.wifi],
      ]) {
        unawaited(recovery.onNetworksChanged([client], networks));
        clock.flushMicrotasks();
      }
      expect(client.timeouts, [30000], reason: 'no transition yet');

      // Wi-Fi -> mobile: a fresh zero-timeout request starts at once.
      unawaited(
        recovery.onNetworksChanged([client], [ConnectivityResult.mobile]),
      );
      clock.flushMicrotasks();
      expect(client.timeouts, [30000, 0]);

      // The dead request finally fails: nothing is reported or restarted.
      client.requests[0].completeError(const SocketExceptionFixture());
      clock.flushMicrotasks();
      expect(statuses, isNot(contains(SyncStatus.error)));
      expect(client.timeouts, [30000, 0]);

      // The new request answers and the loop continues with one long-poll.
      client.requests[1].complete(SyncUpdate(nextBatch: 'synthetic-batch'));
      clock.flushMicrotasks();
      expect(processed, 1);
      expect(client.timeouts, [30000, 0, 30000]);

      // A late answer of a dropped request is never processed.
      unawaited(
        recovery.onNetworksChanged([client], [ConnectivityResult.wifi]),
      );
      clock.flushMicrotasks();
      expect(client.timeouts, [30000, 0, 30000, 0]);
      client.requests[2].complete(SyncUpdate(nextBatch: 'synthetic-batch'));
      clock.flushMicrotasks();
      expect(processed, 1);
      expect(client.timeouts, hasLength(4));

      client.backgroundSync = false;
      unawaited(client.dispose(closeDatabase: false));
      clock.elapse(const Duration(minutes: 2));
    });
  });

  test('no restart in the background, to no network or of an initial sync', () {
    fakeAsync((clock) {
      var foreground = false;
      final client = _HangingClient();
      final recovery = SyncNetworkRecovery(foreground: () => foreground);
      unawaited(client.oneShotSync());
      clock.flushMicrotasks();
      unawaited(
        recovery.onNetworksChanged([client], [ConnectivityResult.wifi]),
      );
      unawaited(
        recovery.onNetworksChanged([client], [ConnectivityResult.mobile]),
      );
      clock.flushMicrotasks();
      expect(client.timeouts, [30000], reason: 'background: push owns it');

      foreground = true;
      unawaited(
        recovery.onNetworksChanged([client], [ConnectivityResult.none]),
      );
      clock.flushMicrotasks();
      expect(client.timeouts, [30000], reason: 'no network to sync on');

      // The initial sync (no batch yet) is joined, never thrown away.
      final initial = _HangingClient(initial: true);
      unawaited(initial.oneShotSync());
      clock.flushMicrotasks();
      expect(initial.timeouts, [null]);
      unawaited(
        wakeSyncOnNetworkRecovery([initial], [ConnectivityResult.wifi]),
      );
      clock.flushMicrotasks();
      expect(initial.timeouts, [null]);

      for (final c in [client, initial]) {
        c.backgroundSync = false;
        unawaited(c.dispose(closeDatabase: false));
      }
      clock.elapse(const Duration(minutes: 2));
    });
  });
}

class SocketExceptionFixture implements Exception {
  const SocketExceptionFixture();
}

// SPDX-License-Identifier: AGPL-3.0-or-later
// The phone's network watcher runs only while its sync loop does (battery
// wave, 2026-11-26): cancelled in the background, where every report was
// ignored, and a fresh baseline after the return, whose catch-up already
// syncs. Synthetic offline client and platform stream; no network.
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

/// Every `/sync` waits until the test answers it.
class _HangingClient extends Client {
  _HangingClient() : super('synthetic-watch', database: _Database());
  final timeouts = <int?>[];
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
    return Completer<SyncUpdate>().future;
  }

  @override
  Future<void> updateUserDeviceKeys({Set<String>? additionalUsers}) async {}
  @override
  Future<void> processToDeviceQueue() async {}
}

/// The platform's broadcast stream: a listener registers the native network
/// callback, cancelling the last one unregisters it.
class _Platform {
  var registered = 0;
  var unregistered = 0;
  late final controller = StreamController<List<ConnectivityResult>>.broadcast(
    onListen: () => registered++,
    onCancel: () => unregistered++,
  );
  bool get listening => registered > unregistered;
}

void main() {
  test('subscribed only while active; starting again restarts the '
      'baseline', () {
    final platform = _Platform();
    final seen = <List<ConnectivityResult>>[];
    var starts = 0;
    final watch = NetworkWatch(
      changes: () => platform.controller.stream,
      onNetworks: seen.add,
      onStart: () => starts++,
    );
    expect(watch.active, isFalse);
    expect(platform.listening, isFalse);

    watch.active = true;
    watch.active = true;
    expect(platform.registered, 1, reason: 'one subscription');
    expect(starts, 1);

    watch.active = false;
    expect(platform.listening, isFalse, reason: 'native callback released');
    watch.active = false;
    expect(platform.unregistered, 1);

    watch.active = true;
    expect(platform.registered, 2);
    expect(starts, 2);

    watch.dispose();
    expect(platform.listening, isFalse);
    watch.active = true;
    expect(platform.listening, isFalse, reason: 'disposed stays off');
    expect(seen, isEmpty);
  });

  test('a platform without the watcher keeps sync on its own retries', () {
    var errors = 0;
    final watch = NetworkWatch(
      changes: () => throw UnsupportedError('no watcher'),
      onNetworks: (_) {},
      onError: () => errors++,
    );
    watch.active = true;
    expect(errors, 1);
    expect(watch.active, isFalse);
  });

  test('away: no report reaches the app; back: the first report is a '
      'baseline, a later change still wakes the loop', () {
    fakeAsync((clock) {
      final platform = _Platform();
      final client = _HangingClient();
      final recovery = SyncNetworkRecovery(foreground: () => true);
      final watch = NetworkWatch(
        changes: () => platform.controller.stream,
        onNetworks: (networks) =>
            unawaited(recovery.onNetworksChanged([client], networks)),
        onStart: recovery.reset,
      )..active = true;
      platform.controller.add([ConnectivityResult.wifi]);
      clock.flushMicrotasks();
      expect(
        client.timeouts,
        isEmpty,
        reason: 'the first report is a baseline',
      );

      // The app leaves the screen, and the phone leaves the Wi-Fi.
      watch.active = false;
      platform.controller.add([ConnectivityResult.mobile]);
      platform.controller.add([ConnectivityResult.mobile]);
      clock.flushMicrotasks();
      expect(client.timeouts, isEmpty);

      // Back on screen: the platform reports the current network at once;
      // the resume catch-up already syncs, so no second sync starts.
      watch.active = true;
      platform.controller.add([ConnectivityResult.mobile]);
      clock.flushMicrotasks();
      expect(client.timeouts, isEmpty);

      // A real transition while on screen restarts the sync at once.
      platform.controller.add([ConnectivityResult.wifi]);
      clock.flushMicrotasks();
      expect(client.timeouts, [0]);

      watch.dispose();
      client.backgroundSync = false;
      unawaited(client.dispose(closeDatabase: false));
      clock.elapse(const Duration(minutes: 2));
    });
  });
}

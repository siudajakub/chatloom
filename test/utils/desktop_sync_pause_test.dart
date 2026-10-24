// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/utils/desktop_sync_pause.dart';
import 'package:chatloom/utils/sync_network_recovery.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

class _Client implements Client {
  int restarts = 0;
  @override
  bool isLogged() => true;
  @override
  String? get prevBatch => 'synthetic-batch';
  @override
  Future<void> restartSync({Duration? timeout}) async => restarts++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// macOS: sync stops after 10 minutes hidden and resumes on show (BP-02,
/// MAC-12; J declined Mac notifications).
void main() {
  late _Client client;
  late List<bool> applied;
  DesktopSyncPause pause() => DesktopSyncPause(
    clients: () => [client],
    apply: (_, {required visible}) => applied.add(visible),
  );

  setUp(() {
    client = _Client();
    applied = [];
  });

  test('hidden for 10 minutes stops the loop; showing resumes at once', () {
    fakeAsync((async) {
      final sync = pause();
      sync.onLifecycle(AppLifecycleState.resumed);
      sync.onLifecycle(AppLifecycleState.hidden);
      async.elapse(const Duration(minutes: 9, seconds: 59));
      expect(applied, isEmpty);
      expect(sync.paused, isFalse);
      async.elapse(const Duration(seconds: 1));
      expect(applied, [false]);
      expect(sync.paused, isTrue);
      // Shown but not focused (another app in front) already resumes.
      sync.onLifecycle(AppLifecycleState.inactive);
      expect(applied, [false, true]);
      expect(sync.paused, isFalse);
      sync.dispose();
    });
  });

  test('a short hide or an unfocused window never stops sync', () {
    fakeAsync((async) {
      final sync = pause();
      sync.onLifecycle(AppLifecycleState.hidden);
      async.elapse(const Duration(minutes: 5));
      sync.onLifecycle(AppLifecycleState.resumed);
      async.elapse(const Duration(minutes: 30));
      sync.onLifecycle(AppLifecycleState.inactive);
      async.elapse(const Duration(minutes: 30));
      expect(applied, isEmpty);
      expect(async.pendingTimers, isEmpty);
      sync.dispose();
    });
  });

  test('an occluded or minimised window counts as hidden', () {
    fakeAsync((async) {
      final sync = pause();
      sync.onLifecycle(AppLifecycleState.resumed);
      sync.onWindowVisible(false);
      async.elapse(const Duration(minutes: 10));
      expect(applied, [false]);
      sync.onWindowVisible(true);
      expect(applied, [false, true]);
      sync.dispose();
    });
  });

  test('network changes do not restart a paused sync', () {
    fakeAsync((async) {
      final sync = pause();
      final recovery = SyncNetworkRecovery(foreground: () => !sync.paused);
      unawaited(
        recovery.onNetworksChanged([client], [ConnectivityResult.wifi]),
      );
      sync.onLifecycle(AppLifecycleState.hidden);
      async.elapse(const Duration(minutes: 10));
      unawaited(
        recovery.onNetworksChanged([client], [ConnectivityResult.mobile]),
      );
      async.flushMicrotasks();
      expect(client.restarts, 0);
      sync.onLifecycle(AppLifecycleState.resumed);
      unawaited(
        recovery.onNetworksChanged([client], [ConnectivityResult.wifi]),
      );
      async.flushMicrotasks();
      expect(client.restarts, 1);
      sync.dispose();
    });
  });

  test('detached leaves the loop alone', () {
    fakeAsync((async) {
      final sync = pause();
      sync.onLifecycle(AppLifecycleState.detached);
      async.elapse(const Duration(minutes: 20));
      expect(applied, isEmpty);
      sync.dispose();
    });
  });
}

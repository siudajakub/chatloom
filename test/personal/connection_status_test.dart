// SPDX-License-Identifier: AGPL-3.0-or-later
// Telegram-style connection status: raw phases and the grace debounce
// (fake time, fake status stream, fake connectivity).
import 'dart:async';

import 'package:chatloom/personal/connection_status.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

class _Harness {
  _Harness({this.network = true, this.firstSync = false});

  // Synchronous, so expectations can follow each emit directly.
  final statuses = StreamController<SyncStatusUpdate>.broadcast(sync: true);
  SyncStatusUpdate? current;
  bool network;
  bool firstSync;
  final seen = <ConnectionPhase>[];

  late final monitor = ConnectionStatusMonitor(
    statuses: () => statuses.stream,
    current: () => current,
    firstSync: () => firstSync,
    hasNetwork: () async => network,
  );

  void listen() => monitor.addListener(() => seen.add(monitor.value));

  void emit(SyncStatus status) {
    current = SyncStatusUpdate(status);
    statuses.add(current!);
  }
}

void main() {
  test('raw phases follow the sync loop', () {
    ConnectionPhase raw(
      SyncStatus? status, {
      bool failed = false,
      bool noNetwork = false,
      bool firstSync = false,
    }) => rawConnectionPhase(
      status: status,
      failed: failed,
      noNetwork: noNetwork,
      firstSync: firstSync,
    );
    // A healthy long poll is online.
    expect(raw(SyncStatus.waitingForResponse), ConnectionPhase.online);
    expect(raw(SyncStatus.finished), ConnectionPhase.online);
    expect(raw(null), ConnectionPhase.online);
    expect(raw(SyncStatus.processing), ConnectionPhase.updating);
    expect(
      raw(SyncStatus.waitingForResponse, failed: true),
      ConnectionPhase.connecting,
    );
    expect(
      raw(SyncStatus.error, failed: true, noNetwork: true),
      ConnectionPhase.waitingForNetwork,
    );
    expect(
      raw(SyncStatus.waitingForResponse, firstSync: true),
      ConnectionPhase.updating,
    );
    expect(raw(null, firstSync: true), ConnectionPhase.online);
    expect(ConnectionPhase.connecting.label, 'Connecting…');
    expect(ConnectionPhase.waitingForNetwork.label, 'Waiting for network…');
    expect(ConnectionPhase.updating.label, 'Updating…');
    expect(ConnectionPhase.online.label, isNull);
  });

  test('a short blip never shows', () {
    fakeAsync((async) {
      final h = _Harness()..listen();
      h.emit(SyncStatus.error);
      async.elapse(const Duration(seconds: 3));
      h.emit(SyncStatus.waitingForResponse);
      async.elapse(const Duration(milliseconds: 500));
      h.emit(SyncStatus.processing);
      h.emit(SyncStatus.finished);
      async.elapse(const Duration(seconds: 10));
      expect(h.seen, isEmpty);
      expect(h.monitor.value, ConnectionPhase.online);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('a lasting failure shows after the grace, recovery at once', () {
    fakeAsync((async) {
      final h = _Harness()..listen();
      h.emit(SyncStatus.error);
      async.elapse(const Duration(seconds: 3));
      expect(h.monitor.value, ConnectionPhase.online);
      async.elapse(const Duration(seconds: 1));
      expect(h.monitor.value, ConnectionPhase.connecting);
      // Retrying keeps "Connecting…".
      h.emit(SyncStatus.waitingForResponse);
      expect(h.monitor.value, ConnectionPhase.connecting);
      // The answer arrives: "Updating…" while it is processed, then online.
      h.emit(SyncStatus.processing);
      expect(h.monitor.value, ConnectionPhase.updating);
      h.emit(SyncStatus.cleaningUp);
      h.emit(SyncStatus.finished);
      expect(h.monitor.value, ConnectionPhase.online);
      expect(h.seen, [
        ConnectionPhase.connecting,
        ConnectionPhase.updating,
        ConnectionPhase.online,
      ]);
    });
  });

  test('no network on the device says "Waiting for network…"', () {
    fakeAsync((async) {
      final h = _Harness(network: false)..listen();
      h.emit(SyncStatus.error);
      async.elapse(const Duration(seconds: 5));
      expect(h.monitor.value, ConnectionPhase.waitingForNetwork);
      // The network returns; the next sync succeeds.
      h.network = true;
      h.emit(SyncStatus.waitingForResponse);
      h.emit(SyncStatus.finished);
      expect(h.monitor.value, ConnectionPhase.online);
    });
  });

  test('long processing shows "Updating…" after its shorter grace', () {
    fakeAsync((async) {
      final h = _Harness()..listen();
      h.emit(SyncStatus.processing);
      async.elapse(const Duration(milliseconds: 1500));
      expect(h.monitor.value, ConnectionPhase.online);
      async.elapse(const Duration(milliseconds: 600));
      expect(h.monitor.value, ConnectionPhase.updating);
      h.emit(SyncStatus.finished);
      expect(h.monitor.value, ConnectionPhase.online);
    });
  });

  test('the first sync of a new login says "Updating…"', () {
    fakeAsync((async) {
      final h = _Harness(firstSync: true)..listen();
      h.emit(SyncStatus.waitingForResponse);
      async.elapse(const Duration(seconds: 3));
      expect(h.monitor.value, ConnectionPhase.updating);
      h.firstSync = false;
      h.emit(SyncStatus.finished);
      expect(h.monitor.value, ConnectionPhase.online);
    });
  });

  test('starts from the current status and stops without listeners', () {
    fakeAsync((async) {
      final h = _Harness()..current = const SyncStatusUpdate(SyncStatus.error);
      void listener() {}
      h.monitor.addListener(listener);
      expect(h.monitor.raw, ConnectionPhase.connecting);
      expect(async.pendingTimers, hasLength(1));
      h.monitor.removeListener(listener);
      expect(async.pendingTimers, isEmpty);
      expect(h.statuses.hasListener, isFalse);
    });
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
// Telegram-style connection status: raw phases, evidence before "offline",
// the grace debounce and the app lifecycle (fake time, fake status stream,
// fake connectivity).
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
  var checks = 0;
  final seen = <ConnectionPhase>[];
  final lastingSeen = <bool>[];

  late final monitor = ConnectionStatusMonitor(
    statuses: () => statuses.stream,
    current: () => current,
    firstSync: () => firstSync,
    hasNetwork: () async {
      checks++;
      return network;
    },
  );

  void listen() => monitor.addListener(() {
    if (seen.isEmpty || seen.last != monitor.value) seen.add(monitor.value);
    if (lastingSeen.isEmpty || lastingSeen.last != monitor.lasting) {
      lastingSeen.add(monitor.lasting);
    }
  });

  void emit(SyncStatus status) {
    current = SyncStatusUpdate(status);
    statuses.add(current!);
  }

  /// One failed attempt, as the SDK reports it.
  void fail(FakeAsync async) {
    emit(SyncStatus.waitingForResponse);
    emit(SyncStatus.error);
    async.flushMicrotasks();
  }

  void succeed() {
    emit(SyncStatus.waitingForResponse);
    emit(SyncStatus.processing);
    emit(SyncStatus.cleaningUp);
    emit(SyncStatus.finished);
  }
}

void main() {
  test('raw phases follow the sync loop', () {
    ConnectionPhase raw(
      SyncStatus? status, {
      bool failing = false,
      bool noNetwork = false,
      bool firstSync = false,
      bool catchingUp = false,
    }) => rawConnectionPhase(
      status: status,
      failing: failing,
      noNetwork: noNetwork,
      firstSync: firstSync,
      catchingUp: catchingUp,
    );
    // A healthy long poll is online.
    expect(raw(SyncStatus.waitingForResponse), ConnectionPhase.online);
    expect(raw(SyncStatus.finished), ConnectionPhase.online);
    expect(raw(null), ConnectionPhase.online);
    expect(raw(SyncStatus.processing), ConnectionPhase.updating);
    expect(
      raw(SyncStatus.waitingForResponse, failing: true),
      ConnectionPhase.connecting,
    );
    expect(
      raw(SyncStatus.error, failing: true, noNetwork: true),
      ConnectionPhase.waitingForNetwork,
    );
    // An answer being processed proves the server is reachable.
    expect(raw(SyncStatus.processing, failing: true), ConnectionPhase.updating);
    // The catch-up after a return to the app.
    expect(
      raw(SyncStatus.waitingForResponse, catchingUp: true),
      ConnectionPhase.updating,
    );
    expect(raw(SyncStatus.error, catchingUp: true), ConnectionPhase.updating);
    expect(
      raw(SyncStatus.waitingForResponse, firstSync: true),
      ConnectionPhase.updating,
    );
    expect(raw(null, firstSync: true), ConnectionPhase.online);
    expect(ConnectionPhase.connecting.label, 'Connecting…');
    expect(ConnectionPhase.waitingForNetwork.label, 'Waiting for network…');
    expect(ConnectionPhase.updating.label, 'Updating…');
    expect(ConnectionPhase.online.label, isNull);
    expect(ConnectionPhase.connecting.busy, isTrue);
    expect(ConnectionPhase.updating.busy, isTrue);
    expect(ConnectionPhase.waitingForNetwork.busy, isFalse);
  });

  test('one failed request is never "offline"', () {
    fakeAsync((async) {
      final h = _Harness(network: false)..listen();
      h.fail(async);
      expect(h.monitor.raw, ConnectionPhase.online);
      // The SDK retries after 3 s; the retry gets through.
      async.elapse(const Duration(seconds: 3));
      h.succeed();
      async.elapse(const Duration(seconds: 40));
      expect(h.seen, isEmpty);
      expect(h.monitor.value, ConnectionPhase.online);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('two failures in a row show "Connecting…", recovery at once', () {
    fakeAsync((async) {
      final h = _Harness()..listen();
      h.fail(async);
      async.elapse(const Duration(seconds: 3));
      h.fail(async);
      expect(h.monitor.raw, ConnectionPhase.connecting);
      // A failure again moments later does not flash: the grace is 1 s.
      expect(h.monitor.value, ConnectionPhase.online);
      async.elapse(const Duration(seconds: 1));
      expect(h.monitor.value, ConnectionPhase.connecting);
      expect(h.checks, 2, reason: 'one connectivity check per failure');
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
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('a retry that never answers is evidence too', () {
    fakeAsync((async) {
      final h = _Harness()..listen();
      h.fail(async);
      async.elapse(const Duration(seconds: 3));
      // The quick retry should answer at once; it hangs.
      h.emit(SyncStatus.waitingForResponse);
      async.elapse(const Duration(seconds: 8));
      expect(h.monitor.raw, ConnectionPhase.connecting);
      async.elapse(const Duration(seconds: 1));
      expect(h.monitor.value, ConnectionPhase.connecting);
      h.emit(SyncStatus.processing);
      h.emit(SyncStatus.finished);
      expect(h.monitor.value, ConnectionPhase.online);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('no network on the device says "Waiting for network…"', () {
    fakeAsync((async) {
      final h = _Harness(network: false)..listen();
      h.fail(async);
      async.elapse(const Duration(seconds: 3));
      h.fail(async);
      async.elapse(const Duration(seconds: 1));
      expect(h.monitor.value, ConnectionPhase.waitingForNetwork);
      // The network returns; the next sync succeeds.
      h.network = true;
      h.succeed();
      expect(h.monitor.value, ConnectionPhase.online);
    });
  });

  test('a problem lasting 30 s on screen becomes lasting', () {
    fakeAsync((async) {
      final h = _Harness(network: false)..listen();
      h.fail(async);
      async.elapse(const Duration(seconds: 3));
      h.fail(async);
      async.elapse(const Duration(seconds: 1));
      expect(h.monitor.lasting, isFalse);
      async.elapse(const Duration(seconds: 29));
      expect(h.monitor.lasting, isFalse);
      // Retries keep failing (6 s, 12 s, 20 s apart).
      h.fail(async);
      async.elapse(const Duration(seconds: 1));
      expect(h.monitor.lasting, isTrue);
      expect(h.monitor.value, ConnectionPhase.waitingForNetwork);
      h.succeed();
      expect(h.monitor.lasting, isFalse);
      expect(h.lastingSeen, [false, true, false]);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('long processing shows "Updating…" after its shorter grace', () {
    fakeAsync((async) {
      final h = _Harness()..listen();
      h.emit(SyncStatus.processing);
      async.elapse(const Duration(milliseconds: 1400));
      expect(h.monitor.value, ConnectionPhase.online);
      async.elapse(const Duration(milliseconds: 200));
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
      async.flushMicrotasks();
      // An old failure is one failure: not shown yet...
      expect(h.monitor.raw, ConnectionPhase.online);
      // ...until the next attempt fails too.
      h.fail(async);
      expect(h.monitor.raw, ConnectionPhase.connecting);
      expect(async.pendingTimers, isNotEmpty);
      h.monitor.removeListener(listener);
      expect(async.pendingTimers, isEmpty);
      expect(h.statuses.hasListener, isFalse);
      // A listener that comes back while syncs still fail keeps the evidence
      // (a builder re-adding its listener must not hide a real problem).
      h.monitor.addListener(listener);
      async.flushMicrotasks();
      expect(h.monitor.raw, ConnectionPhase.connecting);
      h.monitor.removeListener(listener);
      // Anything but a failure since then: a new attempt, no evidence.
      h.emit(SyncStatus.waitingForResponse);
      h.monitor.addListener(listener);
      expect(h.monitor.raw, ConnectionPhase.online);
      h.monitor.removeListener(listener);
    });
  });

  group('app lifecycle', () {
    test('errors in the background never count and the return is clean', () {
      fakeAsync((async) {
        // While in the background Android reports a blocked network as none.
        final h = _Harness(network: false)..listen();
        h.monitor.background();
        // The stopped loop's long-poll dies, a push catch-up fails.
        h.fail(async);
        h.fail(async);
        async.elapse(const Duration(minutes: 5));
        expect(h.monitor.value, ConnectionPhase.online);
        expect(h.checks, 0, reason: 'no connectivity checks in background');
        expect(async.pendingTimers, isEmpty);

        // Back on screen with a working network: a quick catch-up.
        h.network = true;
        h.monitor.resumed(catchingUp: true);
        expect(h.monitor.raw, ConnectionPhase.updating);
        async.elapse(const Duration(milliseconds: 600));
        h.succeed();
        async.elapse(const Duration(seconds: 5));
        expect(h.seen, isEmpty, reason: 'nothing flashes');
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a slow catch-up shows only a quiet "Updating…"', () {
      fakeAsync((async) {
        final h = _Harness()..listen();
        h.monitor.background();
        h.monitor.resumed(catchingUp: true);
        h.emit(SyncStatus.waitingForResponse);
        async.elapse(const Duration(milliseconds: 1400));
        expect(h.monitor.value, ConnectionPhase.online);
        async.elapse(const Duration(milliseconds: 200));
        expect(h.monitor.value, ConnectionPhase.updating);
        h.emit(SyncStatus.processing);
        h.emit(SyncStatus.finished);
        expect(h.seen, [ConnectionPhase.updating, ConnectionPhase.online]);
      });
    });

    test('a failure right after the return is not "offline"', () {
      fakeAsync((async) {
        // The first request reuses a socket the background killed, and the
        // system still reports the network as blocked for a moment.
        final h = _Harness(network: false)..listen();
        h.monitor.background();
        h.monitor.resumed(catchingUp: true);
        h.fail(async);
        expect(h.monitor.raw, ConnectionPhase.updating);
        h.network = true;
        async.elapse(const Duration(seconds: 3));
        // The SDK's quick retry gets through.
        h.succeed();
        async.elapse(const Duration(seconds: 40));
        expect(
          h.seen.where((phase) => phase.offline),
          isEmpty,
          reason: 'never "Waiting for network…" or "Connecting…"',
        );
        expect(h.monitor.value, ConnectionPhase.online);
        expect(h.monitor.lasting, isFalse);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('really offline after the return: quiet line, then lasting', () {
      fakeAsync((async) {
        final h = _Harness(network: false)..listen();
        h.monitor.background();
        h.monitor.resumed(catchingUp: true);
        h.fail(async);
        async.elapse(const Duration(seconds: 2));
        expect(h.monitor.value, ConnectionPhase.updating);
        async.elapse(const Duration(seconds: 1));
        h.fail(async);
        // "Updating…" was showing: the problem replaces it at once.
        expect(h.monitor.value, ConnectionPhase.waitingForNetwork);
        expect(h.monitor.lasting, isFalse);
        async.elapse(const Duration(seconds: 30));
        expect(h.monitor.lasting, isTrue);
        // Leaving the app drops it all: nothing is measured in background.
        h.monitor.background();
        expect(h.monitor.value, ConnectionPhase.online);
        expect(h.monitor.lasting, isFalse);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('"Updating…" never outlives a catch-up that reported nothing', () {
      fakeAsync((async) {
        final h = _Harness()..listen();
        h.monitor.background();
        // The catch-up was skipped (the client is still initialising) or
        // dropped for a newer sync: no status at all.
        h.monitor.resumed(catchingUp: true);
        expect(h.monitor.raw, ConnectionPhase.updating);
        async.elapse(const Duration(seconds: 2));
        expect(h.monitor.value, ConnectionPhase.updating);
        h.monitor.caughtUp();
        expect(h.monitor.value, ConnectionPhase.online);
        expect(async.pendingTimers, isEmpty);
        // A failed catch-up keeps it until the retry decides: one failure
        // is no reason to say "offline" and no reason to go quiet either.
        h.monitor.resumed(catchingUp: true);
        h.fail(async);
        h.monitor.caughtUp();
        expect(h.monitor.raw, ConnectionPhase.updating);
        async.elapse(const Duration(seconds: 3));
        h.succeed();
        expect(h.monitor.value, ConnectionPhase.online);
        expect(h.seen.where((phase) => phase.offline), isEmpty);
        expect(async.pendingTimers, isEmpty);
      });
    });
  });
}

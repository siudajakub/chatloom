// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/push_diagnostics.dart';
import 'package:chatloom/utils/background_push_catch_up.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

class _Client implements Client {
  bool logged = true;
  @override
  bool isLogged() => logged;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// One bounded catch-up sync after a background notification (2026-10-21).
void main() {
  test('a burst of notifications shares one catch-up per interval', () {
    fakeAsync((async) {
      final client = _Client();
      var syncs = 0;
      final catchUp = PushCatchUp(
        clock: () => DateTime.utc(2026).add(async.elapsed),
        sync: (_) async {
          syncs++;
          await Future<void>.delayed(const Duration(milliseconds: 300));
        },
      );
      final first = catchUp.run(client);
      expect(first, isNotNull);
      expect(identical(catchUp.run(client), first), isTrue, reason: 'joined');
      async.elapse(const Duration(seconds: 1));
      expect(syncs, 1);
      // More notifications within the interval: their events are read from
      // the database the catch-up filled; no further sync.
      for (var i = 0; i < 5; i++) {
        expect(catchUp.run(client), isNull);
        async.elapse(const Duration(seconds: 1));
      }
      expect(syncs, 1);
      async.elapse(const Duration(seconds: 5));
      expect(catchUp.run(client), isNotNull);
      async.elapse(const Duration(seconds: 1));
      expect(syncs, 2);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('the wait is bounded and failures stay quiet', () {
    fakeAsync((async) {
      final client = _Client();
      final hanging = Completer<void>();
      var calls = 0;
      final catchUp = PushCatchUp(
        wait: const Duration(seconds: 15),
        minInterval: Duration.zero,
        clock: () => DateTime.utc(2026).add(async.elapsed),
        sync: (_) {
          calls++;
          return calls == 1
              ? hanging.future
              : Future<void>.error(StateError('offline'));
        },
      );
      var done = false;
      catchUp.run(client)!.then((_) => done = true);
      async.elapse(const Duration(seconds: 14));
      expect(done, isFalse);
      async.elapse(const Duration(seconds: 1));
      expect(done, isTrue, reason: 'the push does not wait longer');

      var failedDone = false;
      catchUp.run(client)!.then((_) => failedDone = true);
      async.flushMicrotasks();
      expect(failedDone, isTrue, reason: 'an offline catch-up never throws');
      hanging.complete();
      async.flushMicrotasks();
    });
  });

  test('only a notification shown while the phone app is away catches up', () {
    for (final outcome in PushOutcome.values) {
      for (final lifecycle in [null, ...AppLifecycleState.values]) {
        expect(
          PushCatchUp.wanted(outcome, mobile: true, lifecycle: lifecycle),
          outcome == PushOutcome.shown &&
              lifecycle != AppLifecycleState.resumed,
          reason: '$outcome $lifecycle',
        );
      }
      expect(
        PushCatchUp.wanted(
          outcome,
          mobile: false,
          lifecycle: AppLifecycleState.paused,
        ),
        isFalse,
        reason: 'desktop keeps its own loop',
      );
    }
  });

  test('a signed-out account is not synced', () {
    final client = _Client()..logged = false;
    var syncs = 0;
    final catchUp = PushCatchUp(sync: (_) async => syncs++);
    expect(catchUp.run(client), isNull);
    expect(syncs, 0);
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/push_diagnostics.dart';
import 'package:chatloom/utils/background_push_catch_up.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Client implements Client {
  bool logged = true;
  @override
  bool isLogged() => logged;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A timeline event the catch-up only passes on.
class _Event implements Event {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// One bounded catch-up sync after a background notification (2026-10-21),
/// and the alerts for its backlog (2026-10-27).
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
          return const <Event>[];
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
      final hanging = Completer<List<Event>?>();
      var calls = 0;
      final catchUp = PushCatchUp(
        wait: const Duration(seconds: 15),
        minInterval: Duration.zero,
        clock: () => DateTime.utc(2026).add(async.elapsed),
        sync: (_) {
          calls++;
          return calls == 1
              ? hanging.future
              : Future<List<Event>?>.error(StateError('offline'));
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
      hanging.complete(null);
      async.flushMicrotasks();
    });
  });

  test('a message push that was shown, or whose message could not be '
      'loaded, catches up while the phone app is away', () {
    expect(PushCatchUp.after, {
      PushOutcome.shown,
      PushOutcome.shownFallback,
      PushOutcome.fetchFailed,
      PushOutcome.timeout,
    });
    for (final outcome in PushOutcome.values) {
      for (final lifecycle in [null, ...AppLifecycleState.values]) {
        expect(
          PushCatchUp.wanted(outcome, mobile: true, lifecycle: lifecycle),
          PushCatchUp.after.contains(outcome) &&
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
    final catchUp = PushCatchUp(
      sync: (_) async {
        syncs++;
        return null;
      },
    );
    expect(catchUp.run(client), isNull);
    expect(syncs, 0);
  });

  group('backlog alerts (2026-10-27)', () {
    test('a burst of failed pushes runs one sync and alerts for its backlog '
        'once; the pushes in the burst share that run', () {
      fakeAsync((async) {
        final client = _Client();
        final arrived = [_Event(), _Event()];
        var syncs = 0;
        final notified = <List<Event>>[];
        final catchUp = PushCatchUp(
          clock: () => DateTime.utc(2026).add(async.elapsed),
          sync: (_) async {
            syncs++;
            await Future<void>.delayed(const Duration(seconds: 1));
            return arrived;
          },
          notify: (_, events) async {
            notified.add(events);
            return events.length;
          },
        );
        final results = <int?>[];
        for (final outcome in [
          PushOutcome.fetchFailed,
          PushOutcome.timeout,
          PushOutcome.shownFallback,
          PushOutcome.fetchFailed,
        ]) {
          expect(
            PushCatchUp.wanted(
              outcome,
              mobile: true,
              lifecycle: AppLifecycleState.paused,
            ),
            isTrue,
          );
          catchUp.run(client)?.then(results.add);
          async.elapse(const Duration(milliseconds: 200));
        }
        async.elapse(const Duration(seconds: 2));
        expect(syncs, 1);
        expect(notified, hasLength(1));
        expect(identical(notified.single, arrived), isTrue);
        expect(results, [2, 2, 2, 2], reason: 'all joined the one run');
        // Later in the interval: skipped, not synced or alerted again.
        expect(catchUp.run(client), isNull);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a failed sync alerts for nothing; an empty one has nothing to '
        'alert for', () {
      fakeAsync((async) {
        final client = _Client();
        List<Event>? arrived;
        var notifies = 0;
        final catchUp = PushCatchUp(
          minInterval: Duration.zero,
          clock: () => DateTime.utc(2026).add(async.elapsed),
          sync: (_) async => arrived,
          notify: (_, events) async {
            notifies++;
            return events.length;
          },
        );
        int? failed = -1, empty = -1;
        catchUp.run(client)!.then((value) => failed = value);
        async.flushMicrotasks();
        expect(failed, isNull, reason: 'the sync failed');
        arrived = [];
        catchUp.run(client)!.then((value) => empty = value);
        async.flushMicrotasks();
        expect(empty, 0);
        expect(notifies, 0);
      });
    });

    test('alerting is bounded and never throws', () {
      fakeAsync((async) {
        final client = _Client();
        final catchUp = PushCatchUp(
          minInterval: Duration.zero,
          notifyWait: const Duration(seconds: 20),
          clock: () => DateTime.utc(2026).add(async.elapsed),
          sync: (_) async => [_Event()],
          notify: (_, _) => Completer<int>().future,
        );
        var done = false;
        int? result = -1;
        catchUp.run(client)!.then((value) {
          done = true;
          result = value;
        });
        async.elapse(const Duration(seconds: 19));
        expect(done, isFalse);
        async.elapse(const Duration(seconds: 1));
        expect(done, isTrue);
        expect(result, isNull);

        final failing = PushCatchUp(
          minInterval: Duration.zero,
          sync: (_) async => [_Event()],
          notify: (_, _) => throw StateError('synthetic'),
        );
        var failedDone = false;
        failing.run(client)!.then((_) => failedDone = true);
        async.flushMicrotasks();
        expect(failedDone, isTrue);
      });
    });
  });

  group('each message alerts once (NotifiedMessages)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      NotifiedMessages.debugReset();
    });

    test('a claimed message cannot be claimed again, also after the process '
        'restarted; a released one can', () async {
      final store = await SharedPreferences.getInstance();
      await NotifiedMessages.load(store);
      expect(NotifiedMessages.claim('account', r'$synthetic-a'), isTrue);
      expect(NotifiedMessages.claim('account', r'$synthetic-a'), isFalse);
      expect(NotifiedMessages.contains('account', r'$synthetic-a'), isTrue);
      expect(NotifiedMessages.contains('other', r'$synthetic-a'), isFalse);
      expect(NotifiedMessages.claim('account', r'$synthetic-b'), isTrue);
      NotifiedMessages.release('account', r'$synthetic-b');
      await NotifiedMessages.saved;

      NotifiedMessages.debugReset();
      await NotifiedMessages.load(await SharedPreferences.getInstance());
      expect(NotifiedMessages.claim('account', r'$synthetic-a'), isFalse);
      expect(NotifiedMessages.claim('account', r'$synthetic-b'), isTrue);
    });

    test('only bounded one-way digests are stored', () async {
      final store = await SharedPreferences.getInstance();
      await NotifiedMessages.load(store);
      for (var i = 0; i < NotifiedMessages.limit + 10; i++) {
        NotifiedMessages.claim('synthetic-account', '\$synthetic-$i');
      }
      await NotifiedMessages.saved;
      final stored = store.getStringList(NotifiedMessages.storeKey)!;
      expect(stored, hasLength(NotifiedMessages.limit));
      expect(stored.join(), isNot(contains('synthetic')));
      // The oldest are forgotten first.
      expect(
        NotifiedMessages.contains('synthetic-account', r'$synthetic-0'),
        isFalse,
      );
      expect(
        NotifiedMessages.contains(
          'synthetic-account',
          '\$synthetic-${NotifiedMessages.limit + 9}',
        ),
        isTrue,
      );
    });
  });

  group('count-only pushes (BP-06a)', () {
    test('two count pushes 2 s apart with a matching count sync once', () {
      fakeAsync((async) {
        final client = _Client();
        var syncs = 0;
        var local = 3;
        final counts = PushCountSync(
          clock: () => DateTime.utc(2026).add(async.elapsed),
          sync: (_) async {
            syncs++;
            local = 2; // the sync brought the read state from the Mac
          },
          localUnread: (_) => local,
        );
        bool? first, second;
        counts.run(client, unread: 2).then((value) => first = value);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        counts.run(client, unread: 2).then((value) => second = value);
        async.flushMicrotasks();
        expect(syncs, 1);
        expect(first, isTrue);
        expect(second, isFalse, reason: 'local state already matches');
      });
    });

    test('a different count within the window still syncs', () {
      fakeAsync((async) {
        final client = _Client();
        var syncs = 0;
        final counts = PushCountSync(
          clock: () => DateTime.utc(2026).add(async.elapsed),
          sync: (_) async => syncs++,
          localUnread: (_) => 5,
        );
        counts.run(client, unread: 4);
        async.elapse(const Duration(seconds: 3));
        counts.run(client, unread: 3);
        async.flushMicrotasks();
        expect(syncs, 2, reason: 'another chat was read meanwhile');
        // Without a count, the window alone decides.
        async.elapse(const Duration(seconds: 3));
        counts.run(client, unread: null);
        async.flushMicrotasks();
        expect(syncs, 2);
        async.elapse(const Duration(seconds: 10));
        counts.run(client, unread: null);
        async.flushMicrotasks();
        expect(syncs, 3);
      });
    });

    test('a running sync is joined; a failure never throws', () {
      fakeAsync((async) {
        final client = _Client();
        var syncs = 0;
        final counts = PushCountSync(
          clock: () => DateTime.utc(2026).add(async.elapsed),
          sync: (_) async {
            syncs++;
            await Future<void>.delayed(const Duration(seconds: 1));
            throw StateError('synthetic offline');
          },
          localUnread: (_) => 0,
        );
        var done = 0;
        counts.run(client, unread: 1).then((_) => done++);
        counts.run(client, unread: 1).then((_) => done++);
        async.elapse(const Duration(seconds: 2));
        expect(syncs, 1);
        expect(done, 2);
      });
    });
  });
}

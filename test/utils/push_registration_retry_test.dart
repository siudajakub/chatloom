// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/utils/push_registration_retry.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('repeated 503 responses stop after five automatic retries', () {
    fakeAsync((clock) {
      var requests = 0, exhausted = 0;
      final policy = PushRegistrationRetry<String>(
        retry: (_) async {
          requests++;
          throw StateError('Synthetic HTTP 503');
        },
        eligible: (_) => true,
        onExhausted: (_) {
          exhausted++;
        },
      );
      policy.setForeground(true);
      policy.failed('account');
      for (final seconds in [30, 60, 120, 240, 300]) {
        clock.elapse(Duration(seconds: seconds));
        clock.flushMicrotasks();
      }
      expect(requests, 5);
      expect(exhausted, 1);
      expect(policy.scheduledCount, 0);
      clock.elapse(const Duration(days: 1));
      expect(requests, 5);
      policy.reset();
    });
  });

  test(
    'detached initial failure retains pending work without background timers',
    () {
      fakeAsync((clock) {
        var requests = 0;
        final policy = PushRegistrationRetry<String>(
          retry: (_) async {
            requests++;
          },
          eligible: (_) => true,
          onExhausted: (_) => fail('Unexpected exhaustion'),
        );
        policy.failed('account');
        expect(policy.trackedCount, 1);
        expect(policy.scheduledCount, 0);
        clock.elapse(const Duration(days: 1));
        expect(requests, 0);
        policy.setForeground(true);
        clock.elapse(const Duration(seconds: 30));
        expect(requests, 1);
        policy.reset();
      });
    },
  );

  test('pause cancels timers and resume preserves the retry count/backoff', () {
    fakeAsync((clock) {
      var requests = 0;
      final policy = PushRegistrationRetry<String>(
        retry: (_) async {
          requests++;
          throw StateError('Synthetic HTTP 503');
        },
        eligible: (_) => true,
        onExhausted: (_) {},
      );
      policy.setForeground(true);
      policy.failed('account');
      clock.elapse(const Duration(seconds: 30));
      expect(requests, 1);
      policy.setForeground(false);
      expect(policy.scheduledCount, 0);
      clock.elapse(const Duration(hours: 8));
      expect(requests, 1);
      policy.setForeground(true);
      clock.elapse(const Duration(seconds: 30));
      expect(requests, 1);
      clock.elapse(const Duration(seconds: 30));
      expect(requests, 2);
      policy.reset();
    });
  });

  test(
    'failure of a request already in flight cannot schedule background retries',
    () {
      fakeAsync((clock) {
        final request = Completer<void>();
        var requests = 0;
        final policy = PushRegistrationRetry<String>(
          retry: (_) {
            requests++;
            return request.future;
          },
          eligible: (_) => true,
          onExhausted: (_) {},
        );
        policy.setForeground(true);
        policy.failed('account');
        clock.elapse(const Duration(seconds: 30));
        policy.setForeground(false);
        request.completeError(StateError('Synthetic HTTP 503'));
        clock.flushMicrotasks();
        expect(policy.scheduledCount, 0);
        clock.elapse(const Duration(hours: 8));
        expect(requests, 1);
        policy.setForeground(true);
        expect(policy.scheduledCount, 1);
        policy.reset();
      });
    },
  );

  test('logout forget cancels timers and removes retained account state', () {
    fakeAsync((clock) {
      var requests = 0;
      final policy = PushRegistrationRetry<String>(
        retry: (_) async {
          requests++;
        },
        eligible: (_) => true,
        onExhausted: (_) {},
      );
      policy.setForeground(true);
      policy.failed('account');
      policy.forget('account');
      expect(policy.scheduledCount, 0);
      expect(policy.trackedCount, 0);
      clock.elapse(const Duration(days: 1));
      expect(requests, 0);
    });
  });

  test(
    'lost account eligibility retires a pending retry before any request',
    () {
      fakeAsync((clock) {
        var loggedIn = true, requests = 0;
        final policy = PushRegistrationRetry<String>(
          retry: (_) async {
            requests++;
          },
          eligible: (_) => loggedIn,
          onExhausted: (_) {},
        );
        policy.setForeground(true);
        policy.failed('account');
        loggedIn = false;
        clock.elapse(const Duration(seconds: 30));
        expect(requests, 0);
        expect(policy.trackedCount, 0);
      });
    },
  );

  test('visible setup/token reset permits a fresh series after exhaustion', () {
    fakeAsync((clock) {
      var requests = 0;
      final policy = PushRegistrationRetry<String>(
        retry: (_) async {
          requests++;
          throw StateError('Synthetic HTTP 503');
        },
        eligible: (_) => true,
        onExhausted: (_) {},
      );
      policy.setForeground(true);
      policy.failed('account');
      for (final seconds in [30, 60, 120, 240, 300]) {
        clock.elapse(Duration(seconds: seconds));
      }
      expect(requests, 5);
      policy.setForeground(false);
      policy.setForeground(true);
      clock.elapse(const Duration(days: 1));
      expect(requests, 5);
      policy.reset();
      policy.failed('account');
      clock.elapse(const Duration(seconds: 30));
      expect(requests, 6);
      policy.reset();
    });
  });

  test(
    'token rotation reset prevents a late old failure from reviving timers',
    () {
      fakeAsync((clock) {
        final request = Completer<void>();
        final policy = PushRegistrationRetry<String>(
          retry: (_) => request.future,
          eligible: (_) => true,
          onExhausted: (_) {},
        );
        policy.setForeground(true);
        policy.failed('account');
        clock.elapse(const Duration(seconds: 30));
        policy.reset();
        request.completeError(StateError('Synthetic old response'));
        clock.flushMicrotasks();
        expect(policy.scheduledCount, 0);
        expect(policy.trackedCount, 0);
      });
    },
  );
}

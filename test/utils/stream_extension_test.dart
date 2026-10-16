// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:fluffychat/utils/stream_extension.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rate limit does not subscribe until a view listens', () {
    var listens = 0;
    final source = StreamController<int>(onListen: () => listens++);
    source.stream.rateLimit(const Duration(milliseconds: 200));
    expect(listens, 0);
    unawaited(source.close());
  });

  test('disposing a view cancels its trailing timer and subscription', () {
    fakeAsync((clock) {
      var cancellations = 0;
      final source = StreamController<int>(
        onCancel: () => cancellations++,
      );
      final values = <bool>[];
      final view = source.stream
          .rateLimit(const Duration(milliseconds: 200))
          .listen(values.add);
      source.add(1);
      source.add(2);
      clock.flushMicrotasks();
      expect(values, [true]);
      expect(clock.nonPeriodicTimerCount, 1);
      unawaited(view.cancel());
      clock.flushMicrotasks();
      expect(cancellations, 1);
      expect(clock.pendingTimers, isEmpty);
      clock.elapse(const Duration(seconds: 1));
      expect(values, [true]);
      unawaited(source.close());
      clock.flushMicrotasks();
    });
  });

  test('bursts retain one trailing update and completion flushes it', () {
    fakeAsync((clock) {
      final source = StreamController<int>();
      final values = <bool>[];
      var done = false;
      source.stream.rateLimit(const Duration(milliseconds: 200)).listen(
        values.add,
        onDone: () => done = true,
      );
      source.add(1);
      source.add(2);
      clock.flushMicrotasks();
      clock.elapse(const Duration(milliseconds: 200));
      expect(values, [true, true]);
      source.add(3);
      source.add(4);
      unawaited(source.close());
      clock.flushMicrotasks();
      expect(values, [true, true, true]);
      expect(done, isTrue);
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test('paused views suspend upstream work and the pending timer', () {
    fakeAsync((clock) {
      final source = StreamController<int>();
      final values = <bool>[];
      final view = source.stream
          .rateLimit(const Duration(milliseconds: 200))
          .listen(values.add);
      source.add(1);
      source.add(2);
      clock.flushMicrotasks();
      view.pause();
      expect(source.isPaused, isTrue);
      expect(clock.pendingTimers, isEmpty);
      clock.elapse(const Duration(minutes: 1));
      expect(values, [true]);
      view.resume();
      clock.flushMicrotasks();
      expect(values, [true, true]);
      unawaited(view.cancel());
      unawaited(source.close());
      clock.flushMicrotasks();
      expect(clock.pendingTimers, isEmpty);
    });
  });
}

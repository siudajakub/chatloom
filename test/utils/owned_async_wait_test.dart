// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/utils/owned_async_wait.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'owner cancellation releases a wait on unfinished shared loading',
    () async {
      final shared = Completer<void>();
      final wait = OwnedAsyncWait();
      final waiting = wait.until(shared.future);
      wait.cancel();
      expect(await waiting, isFalse);
      expect(shared.isCompleted, isFalse);
      // A late shared-loader error remains observed after its view disappeared.
      shared.completeError(StateError('synthetic loader failure'));
      await Future<void>.delayed(Duration.zero);
      expect(await wait.until(Future<void>.value()), isFalse);
    },
  );

  test(
    'cancelling a first-match wait removes the offline subscription',
    () async {
      final source = StreamController<int>.broadcast();
      final wait = OwnedAsyncWait();
      final waiting = wait.firstWhere(source.stream, (value) => value == 2);
      expect(source.hasListener, isTrue);
      source.add(1);
      await Future<void>.delayed(Duration.zero);
      wait.cancel();
      expect(await waiting, isFalse);
      expect(source.hasListener, isFalse);
      await source.close();
    },
  );

  test(
    'matching completion and stream errors both release subscriptions',
    () async {
      final source = StreamController<int>.broadcast();
      final wait = OwnedAsyncWait();
      final waiting = wait.firstWhere(source.stream, (value) => value == 2);
      source.add(1);
      source.add(2);
      expect(await waiting, isTrue);
      expect(source.hasListener, isFalse);
      final failed = wait.firstWhere(source.stream, (value) => true);
      final assertion = expectLater(failed, throwsStateError);
      source.addError(StateError('synthetic stream failure'));
      await assertion;
      expect(source.hasListener, isFalse);
      wait.cancel();
      await source.close();
    },
  );
}

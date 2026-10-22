// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/utils/push_work_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('expired work cannot start another operation', () async {
    var calls = 0;
    final work = PushWorkBudget(limit: Duration.zero);
    await expectLater(
      work.wait(() async {
        calls++;
      }),
      throwsA(isA<TimeoutException>()),
    );
    expect(calls, 0);
  });

  test(
    'late network completion cannot continue into notification publication',
    () async {
      final network = Completer<void>();
      final work = PushWorkBudget(limit: const Duration(milliseconds: 10));
      var notifications = 0;
      final operation = () async {
        await work.wait(() => network.future);
        await work.wait(() async {
          notifications++;
        });
      }();
      await expectLater(operation, throwsA(isA<TimeoutException>()));
      network.complete();
      await Future<void>.value();
      expect(notifications, 0);
      await expectLater(
        work.wait(() async {
          notifications++;
        }),
        throwsA(isA<TimeoutException>()),
      );
      expect(notifications, 0);
    },
  );

  test(
    'late reminder claim cannot invoke the guarded notification callback',
    () async {
      final claim = Completer<void>();
      final budget = PushWorkBudget(limit: const Duration(milliseconds: 10));
      var shown = 0;
      final lateClaim = () async {
        await claim.future;
        await budget.wait(() async {
          shown++;
        });
      }();
      await expectLater(
        budget.wait(() => lateClaim),
        throwsA(isA<TimeoutException>()),
      );
      final lateError = expectLater(
        lateClaim,
        throwsA(isA<TimeoutException>()),
      );
      claim.complete();
      await lateError;
      expect(shown, 0);
    },
  );
}

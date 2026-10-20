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

  test('immediately completed call syncs are paced', () async {
    var syncs = 0;
    final pauses = <Duration>[];
    await pollIncomingCall(
      lifetime: const Duration(seconds: 30),
      sync: () async {
        syncs++;
      },
      finished: () async => syncs == 3,
      delay: (duration) async {
        pauses.add(duration);
      },
    );
    expect(syncs, 3);
    expect(pauses, [const Duration(seconds: 2), const Duration(seconds: 2)]);
  });

  test('a hung sync cannot retain the incoming-call monitor', () async {
    final network = Completer<void>();
    var checked = false;
    await pollIncomingCall(
      lifetime: const Duration(seconds: 30),
      requestTimeout: const Duration(milliseconds: 10),
      sync: () => network.future,
      finished: () async {
        checked = true;
        return false;
      },
    );
    expect(checked, isFalse);
    network.complete();
  });

  test('expired call never performs network work', () async {
    var calls = 0;
    await pollIncomingCall(
      lifetime: Duration.zero,
      sync: () async {
        calls++;
      },
      finished: () async => false,
    );
    expect(calls, 0);
  });

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

  test(
    'a hung native completion check also observes the call deadline',
    () async {
      final nativeCheck = Completer<bool>();
      await pollIncomingCall(
        lifetime: const Duration(milliseconds: 10),
        sync: () async {},
        finished: () => nativeCheck.future,
      );
      nativeCheck.complete(false);
    },
  );
}

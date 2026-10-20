// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/utils/background_startup_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'opening foreground before failure waits for old ownership cleanup',
    () async {
      final cleanup = Completer<void>();
      var starts = 0;
      final recovery = BackgroundStartupRecovery(
        startForeground: () async {
          starts++;
        },
      );
      await recovery.requestForeground();
      expect(starts, 0);
      final failing = recovery.fail(cleanup.future);
      expect(starts, 0);
      cleanup.complete();
      await failing;
      await recovery.requestForeground();
      expect(starts, 1);
    },
  );

  test(
    'opening the shared engine after late cleanup starts a fresh foreground owner',
    () async {
      var starts = 0;
      final recovery = BackgroundStartupRecovery(
        startForeground: () async {
          starts++;
        },
      );
      await recovery.fail(Future<void>.value());
      expect(starts, 0);
      await recovery.requestForeground();
      expect(starts, 1);
    },
  );

  test('failed cleanup cannot open a second database owner', () async {
    var starts = 0;
    final recovery = BackgroundStartupRecovery(
      startForeground: () async {
        starts++;
      },
    );
    await recovery.fail(
      Future<void>.error(StateError('synthetic cleanup failure')),
    );
    await expectLater(recovery.requestForeground(), throwsStateError);
    expect(starts, 0);
  });

  test(
    'returning to background during cleanup defers foreground startup',
    () async {
      final cleanup = Completer<void>();
      var starts = 0;
      final recovery = BackgroundStartupRecovery(
        startForeground: () async {
          starts++;
        },
      );
      await recovery.requestForeground();
      final failing = recovery.fail(cleanup.future);
      recovery.leaveForeground();
      cleanup.complete();
      await failing;
      expect(starts, 0);
      await recovery.requestForeground();
      expect(starts, 1);
    },
  );
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fluffychat/utils/foreground_service_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stop waits for a pending native start', () async {
    final gate = Completer<void>();
    final operations = <String>[];
    final controller = ForegroundServiceController(
      start: () async {
        operations.add('start');
        await gate.future;
      },
      stop: () async {
        operations.add('stop');
      },
    );
    final start = controller.start('push');
    final stop = controller.stop('push');
    await Future<void>.value();
    expect(operations, ['start']);
    gate.complete();
    await Future.wait([start, stop]);
    expect(operations, ['start', 'stop']);
    expect(controller.runningServices, isEmpty);
  });

  test('overlapping pushes and uploads retain independent leases', () async {
    var starts = 0;
    var stops = 0;
    final controller = ForegroundServiceController(
      start: () async {
        starts++;
      },
      stop: () async {
        stops++;
      },
    );
    await Future.wait([
      controller.start('push'),
      controller.start('push'),
      controller.start('upload'),
    ]);
    await controller.stop('push');
    await controller.stop('upload');
    expect(starts, 1);
    expect(stops, 0);
    expect(controller.runningServices, ['push']);
    await controller.stop('push');
    await controller.stop('push');
    expect(stops, 1);
  });

  test('failed start leaves no lease and does not poison the queue', () async {
    var starts = 0;
    var stops = 0;
    final controller = ForegroundServiceController(
      start: () async {
        if (++starts == 1) throw StateError('synthetic start failure');
      },
      stop: () async {
        stops++;
      },
    );
    await expectLater(controller.start('failed'), throwsStateError);
    expect(controller.runningServices, isEmpty);
    await controller.start('success');
    await controller.stop('success');
    expect(starts, 2);
    expect(stops, 2);
  });

  test(
    'failed stop can be retried without forgetting the running backend',
    () async {
      var stops = 0;
      final controller = ForegroundServiceController(
        start: () async {},
        stop: () async {
          if (++stops == 1) throw StateError('synthetic stop failure');
        },
      );
      await controller.start('push');
      await expectLater(controller.stop('push'), throwsStateError);
      await controller.stop('push');
      expect(stops, 2);
      expect(controller.runningServices, isEmpty);
    },
  );

  test(
    'timed out start releases now and after its late native completion',
    () async {
      final nativeStart = Completer<void>();
      var stops = 0;
      final controller = ForegroundServiceController(
        operationTimeout: const Duration(milliseconds: 10),
        start: () => nativeStart.future,
        stop: () async {
          stops++;
        },
      );
      await expectLater(
        controller.start('expired'),
        throwsA(isA<TimeoutException>()),
      );
      expect(stops, 1);
      expect(controller.runningServices, isEmpty);
      nativeStart.complete();
      await Future<void>.delayed(Duration.zero);
      expect(stops, 2);
    },
  );

  test('late old start cannot stop a newer active lease', () async {
    final oldStart = Completer<void>();
    var starts = 0;
    var stops = 0;
    final controller = ForegroundServiceController(
      operationTimeout: const Duration(milliseconds: 10),
      start: () async {
        if (++starts == 1) await oldStart.future;
      },
      stop: () async {
        stops++;
      },
    );
    await expectLater(
      controller.start('expired'),
      throwsA(isA<TimeoutException>()),
    );
    await controller.start('current');
    oldStart.complete();
    await Future<void>.delayed(Duration.zero);
    expect(stops, 1);
    expect(controller.runningServices, ['current']);
    await controller.stop('current');
    expect(stops, 2);
  });

  test('late stop reconciles the backend for an active newer lease', () async {
    final oldStop = Completer<void>();
    var starts = 0;
    var stops = 0;
    final controller = ForegroundServiceController(
      operationTimeout: const Duration(milliseconds: 10),
      start: () async {
        starts++;
      },
      stop: () async {
        if (++stops == 1) await oldStop.future;
      },
    );
    await controller.start('old');
    await expectLater(controller.stop('old'), throwsA(isA<TimeoutException>()));
    await controller.start('new');
    oldStop.complete();
    await Future<void>.delayed(Duration.zero);
    expect(starts, 2);
    expect(controller.runningServices, ['new']);
    await controller.stop('new');
    expect(stops, 2);
  });

  test(
    'late failed start still retires a native service started after timeout',
    () async {
      final response = Completer<void>();
      var nativeRunning = false;
      var stops = 0;
      final controller = ForegroundServiceController(
        operationTimeout: const Duration(milliseconds: 10),
        start: () => response.future,
        stop: () async {
          stops++;
          nativeRunning = false;
        },
      );
      await expectLater(
        controller.start('expired'),
        throwsA(isA<TimeoutException>()),
      );
      expect(stops, 1);
      nativeRunning = true;
      response.completeError(
        StateError('Native state check failed after starting'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(nativeRunning, isFalse);
      expect(stops, 2);
      expect(controller.runningServices, isEmpty);
    },
  );
}

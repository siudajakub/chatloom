// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/utils/foreground_service_controller.dart';
import 'package:chatloom/utils/start_push_foreground_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the ongoing notification says what is running, user work first '
      '(not "Loading messages" for everything)', () {
    expect(
      foregroundServiceText([ForegroundServiceTasks.push]),
      'Checking for new messages…',
    );
    expect(
      foregroundServiceText([
        ForegroundServiceTasks.push,
        ForegroundServiceTasks.sendFiles,
      ]),
      'Sending files…',
    );
    expect(
      foregroundServiceText([ForegroundServiceTasks.notificationReply]),
      'Sending your reply…',
    );
    expect(
      foregroundServiceText([ForegroundServiceTasks.notificationAction]),
      'Marking as read…',
    );
    // The existing lease names stay valid for the push and upload callers.
    expect(ForegroundServiceTasks.push, 'background_push');
    expect(ForegroundServiceTasks.sendFiles, 'send_files');
    // Renamed in place: the channel id stays.
    expect(ForegroundServiceChannel.id, 'fluffychat_sync');
    expect(ForegroundServiceChannel.name, 'Background activity');
  });

  test('the start sees the lease it starts for; later lease changes update '
      'the running service, the last stop does not', () async {
    final starting = <String?>[];
    final updates = <List<String>>[];
    late ForegroundServiceController controller;
    controller = ForegroundServiceController(
      start: () async => starting.add(controller.starting),
      stop: () async {},
      update: (running) async => updates.add(running),
    );
    await controller.start('push');
    expect(starting, ['push']);
    expect(controller.starting, isNull);
    expect(updates, isEmpty);
    await controller.start('upload');
    await controller.stop('upload');
    await controller.stop('push');
    expect(updates, [
      ['push', 'upload'],
      ['push'],
    ]);
  });

  test('a failing update never breaks the leases', () async {
    var stops = 0;
    final controller = ForegroundServiceController(
      start: () async {},
      stop: () async => stops++,
      update: (_) async => throw StateError('synthetic update failure'),
    );
    await controller.start('push');
    await controller.start('upload');
    await controller.stop('upload');
    await controller.stop('push');
    expect(controller.runningServices, isEmpty);
    expect(stops, 1);
  });

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

  test('a service the system ended (short-service timeout) is started again '
      'by the next lease instead of being assumed running', () async {
    var nativeRunning = false;
    var starts = 0;
    var stops = 0;
    final controller = ForegroundServiceController(
      start: () async {
        starts++;
        nativeRunning = true;
      },
      stop: () async {
        stops++;
        nativeRunning = false;
      },
      isRunning: () async => nativeRunning,
    );
    await controller.start('upload');
    expect(starts, 1);
    // Android's timeout: the plugin stops itself, the lease is still held.
    nativeRunning = false;
    await controller.start('round');
    expect(starts, 2);
    expect(nativeRunning, isTrue);
    expect(controller.runningServices, ['upload', 'round']);
    // Still running: a further lease joins it.
    await controller.start('push');
    expect(starts, 2);
    await controller.stop('upload');
    await controller.stop('round');
    await controller.stop('push');
    expect(stops, 1);
    expect(nativeRunning, isFalse);
  });

  test('an unanswered running check keeps the current service', () async {
    var starts = 0;
    final controller = ForegroundServiceController(
      operationTimeout: const Duration(milliseconds: 10),
      start: () async => starts++,
      stop: () async {},
      isRunning: () => Completer<bool>().future,
    );
    await controller.start('upload');
    await controller.start('round');
    expect(starts, 1);
    expect(controller.runningServices, ['upload', 'round']);
  });

  group('ForegroundLease', () {
    test('the first hold takes the lease, the last release gives it back; '
        'a release counts once', () async {
      final calls = <String>[];
      final lease = ForegroundLease(
        start: () async {
          calls.add('start');
          return true;
        },
        stop: () async => calls.add('stop'),
      );
      final first = lease.hold();
      final second = lease.hold();
      expect(lease.holds, 2);
      expect(lease.leased, isTrue);
      first();
      first();
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['start']);
      second();
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['start', 'stop']);
      expect(lease.holds, 0);
      expect(lease.leased, isFalse);
    });

    test('a refused start is never given back (it would drop a lease of the '
        'same name that other work holds)', () async {
      var stops = 0;
      final lease = ForegroundLease(
        start: () async => throw StateError('synthetic refusal'),
        stop: () async => stops++,
      );
      lease.hold()();
      await Future<void>.delayed(Duration.zero);
      expect(stops, 0);
      expect(lease.leased, isFalse);
    });

    test('maxHold gives the lease back while work still holds it; the next '
        'hold takes it again', () async {
      final calls = <String>[];
      final lease = ForegroundLease(
        start: () async {
          calls.add('start');
          return true;
        },
        stop: () async => calls.add('stop'),
        maxHold: const Duration(milliseconds: 20),
      );
      final upload = lease.hold();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(calls, ['start', 'stop']);
      expect(lease.holds, 1);
      expect(lease.leased, isFalse);
      final retry = lease.hold();
      expect(lease.leased, isTrue);
      upload();
      retry();
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['start', 'stop', 'start', 'stop']);
    });

    test('released before maxHold: no late stop', () async {
      var stops = 0;
      final lease = ForegroundLease(
        start: () async => true,
        stop: () async => stops++,
        maxHold: const Duration(milliseconds: 20),
      );
      lease.hold()();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(stops, 1);
    });
  });
}

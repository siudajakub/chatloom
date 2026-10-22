// SPDX-License-Identifier: AGPL-3.0-or-later
// Wave 5 push lane: a notification action of a closed app ends before the
// app may open the same storage (CC-10); a tapped notification is never
// opened again by a later launch check (CC-21). Offline, no device.
import 'dart:io';

import 'package:chatloom/utils/background_push.dart';
import 'package:chatloom/utils/notification_background_handler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the action budget, its close reserve and the service stop fit in '
      'the time the app waits at start', () {
    const serviceStop = Duration(seconds: 2);
    expect(notificationActionBudget + serviceStop, lessThan(pushIsolateWait));
    expect(notificationActionCloseReserve, lessThan(notificationActionBudget));
  });

  test('the closed-app action holds a foreground service and releases it '
      'before the storage port', () {
    final source = File(
      'lib/utils/notification_background_handler.dart',
    ).readAsStringSync();
    final start = source.indexOf('ForegroundServices.startService(lease)');
    final stop = source.indexOf('ForegroundServices.stopService(');
    final release = source.lastIndexOf(
      'removePortNameMapping(AppConfig.pushIsolatePortName)',
    );
    expect(start, greaterThan(0));
    expect(stop, greaterThan(start));
    expect(release, greaterThan(stop));
  });

  group('launch notification replay guard', () {
    NotificationResponse tap(String payload, {int id = 1}) =>
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotification,
          id: id,
          payload: payload,
        );

    test('a response opened once (a warm tap Android keeps as the activity '
        'intent) is not opened again; a new notification is', () {
      final handled = HandledNotificationResponses();
      expect(handled.add(tap('a|!room:example.invalid|\$one')), isTrue);
      expect(handled.add(tap('a|!room:example.invalid|\$one')), isFalse);
      expect(handled.contains(tap('a|!room:example.invalid|\$one')), isTrue);
      expect(handled.add(tap('a|!room:example.invalid|\$two')), isTrue);
      expect(handled.add(tap('a|!room:example.invalid|\$one', id: 2)), isTrue);
    });

    test('bounded memory', () {
      final handled = HandledNotificationResponses();
      for (var i = 0; i < 40; i++) {
        handled.add(tap('a|!room:example.invalid|\$e$i'));
      }
      expect(handled.contains(tap('a|!room:example.invalid|\$e0')), isFalse);
      expect(handled.contains(tap('a|!room:example.invalid|\$e39')), isTrue);
    });

    test('only a new app surface checks the launch notification; settings '
        'pages that ask for the shared instance do not', () {
      final source = File('lib/utils/background_push.dart').readAsStringSync();
      expect(
        source,
        contains(
          'if (attached) unawaited(instance._openLaunchNotification());',
        ),
      );
      expect(source, contains('handledLaunchNotifications.add(response);'));
    });
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/push_helper.dart';
import 'package:fluffychat/utils/start_push_foreground_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected fixture I/O');
}

class _UnavailableEventClient extends Client {
  _UnavailableEventClient()
    : super('synthetic push account', database: _NoDatabase());
  @override
  Future<Event?> getEventByPushNotification(
    PushNotification notification, {
    bool storeInDatabase = true,
    Duration timeoutForServerRequests = const Duration(seconds: 8),
    bool returnNullIfSeen = true,
  }) async => throw TimeoutException('Synthetic unresolved event');
}

class _Notifications implements FlutterLocalNotificationsPlugin {
  int shown = 0;
  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    shown++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected notification operation');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });
  test(
    'a background timeout cannot bypass unknown private rules with a generic alert',
    () async {
      final plugin = _Notifications();
      final l10n = await L10n.delegate.load(const Locale('en'));
      // Keep the real service-finalizer away from platform plugins in this fixture.
      const sentinel = 'synthetic-service';
      ForegroundServices.runningServices.add(sentinel);
      try {
        await expectLater(
          pushHelper(
            const PushNotification(
              roomId: '!fixture:example.invalid',
              eventId: r'$fixture',
            ),
            clients: [_UnavailableEventClient()],
            l10n: l10n,
            flutterLocalNotificationsPlugin: plugin,
          ),
          throwsA(isA<TimeoutException>()),
        );
        expect(plugin.shown, 0);
      } finally {
        ForegroundServices.runningServices.remove(sentinel);
      }
    },
  );
}

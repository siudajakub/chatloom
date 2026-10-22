// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/storage/personal_store.dart';
import 'package:chatloom/utils/push_helper.dart';
import 'package:chatloom/utils/start_push_foreground_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected fixture I/O');
}

class _EmptyStore implements PersonalStore {
  @override
  Future<Map<String, Map<String, dynamic>>> readPrefix(String prefix) async =>
      {};
  @override
  Future<Map<String, dynamic>?> get(String key) async => null;
  @override
  Future<void> put(String key, Map<String, dynamic> value) async {}
  @override
  Future<void> delete(String key) async {}
  @override
  Future<void> close() async {}
}

class _UnavailableEventClient extends Client {
  _UnavailableEventClient()
    : super('synthetic push account', database: _NoDatabase());
  @override
  bool isLogged() => true;
  @override
  String? get userID => '@synthetic:example.invalid';
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
      // Keep the real service-finalizer away from platform plugins in this fixture.
      const sentinel = 'synthetic-service';
      ForegroundServices.runningServices.add(sentinel);
      final client = _UnavailableEventClient();
      final personal = PersonalClient.forTesting(
        client,
        openStore: () async => _EmptyStore(),
      );
      pushPersonalClientOf = (_) => personal;
      try {
        await expectLater(
          pushHelper(
            const PushNotification(
              roomId: '!fixture:example.invalid',
              eventId: r'$fixture',
            ),
            clients: [client],
            flutterLocalNotificationsPlugin: plugin,
          ),
          throwsA(isA<TimeoutException>()),
        );
        expect(plugin.shown, 0);
      } finally {
        ForegroundServices.runningServices.remove(sentinel);
        pushPersonalClientOf = PersonalClient.of;
        personal.dispose();
      }
    },
  );
}

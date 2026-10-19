// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/notification_background_handler.dart';
import 'package:fluffychat/utils/notification_client_routing.dart';
import 'package:fluffychat/utils/push_helper.dart';
import 'package:fluffychat/utils/push_work_policy.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

class _SummaryNotifications implements FlutterLocalNotificationsPlugin {
  final gate = Completer<List<ActiveNotification>>();
  int shown = 0;
  int cancelled = 0;
  @override
  Future<List<ActiveNotification>> getActiveNotifications() => gate.future;
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
  Future<void> cancel({required int id, String? tag}) async {
    cancelled++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected notification operation');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'stale explicit notification account never falls back to another account',
    () {
      expect(
        selectNotificationClient(['current'], 'removed', (name) => name),
        isNull,
      );
      expect(
        selectNotificationClient(<String>[], 'removed', (name) => name),
        isNull,
      );
      expect(
        selectNotificationClient(['first', 'second'], 'second', (name) => name),
        'second',
      );
    },
  );

  test('legacy notification account must be unambiguous', () {
    expect(selectNotificationClient(['only'], null, (name) => name), 'only');
    expect(
      selectNotificationClient(['first', 'second'], null, (name) => name),
      isNull,
    );
    expect(selectNotificationClient(<String>[], null, (name) => name), isNull);
  });

  test('a push without an account picks the single signed-in account', () {
    bool signedIn(String name) => name.startsWith('in-');
    expect(
      selectNotificationClient(
        ['out-restoring', 'in-only'],
        null,
        (name) => name,
        isLoggedIn: signedIn,
      ),
      'in-only',
    );
    expect(
      selectNotificationClient(
        ['in-first', 'in-second'],
        null,
        (name) => name,
        isLoggedIn: signedIn,
      ),
      isNull,
    );
    expect(
      selectNotificationClient(
        ['out-a', 'out-b'],
        null,
        (name) => name,
        isLoggedIn: signedIn,
      ),
      isNull,
    );
    // An explicit account is never replaced by the signed-in heuristic.
    expect(
      selectNotificationClient(
        ['in-only'],
        'removed',
        (name) => name,
        isLoggedIn: signedIn,
      ),
      isNull,
    );
  });

  test('push, cancel and summary share one id scheme per account', () {
    expect(
      messageNotificationId('account', '!room:invalid'),
      'account_!room:invalid'.hashCode,
    );
    expect(
      messageNotificationId('account', '!room:invalid'),
      isNot(messageNotificationId('other', '!room:invalid')),
    );
    expect(summaryNotificationId('account'), 'account'.hashCode);
    expect(reminderNotificationId('entity'), 'reminder_entity'.hashCode);
  });

  test('reminder payloads keep their message and stay compatible', () {
    final reminder = FluffyChatPushPayload(
      'synthetic',
      '!fixture:invalid',
      r'$anchor',
      reminder: true,
    );
    final parsed = FluffyChatPushPayload.fromString(reminder.toString());
    expect(parsed.reminder, isTrue);
    expect(parsed.eventId, r'$anchor');
    expect(parsed.roomId, '!fixture:invalid');
    final legacy = FluffyChatPushPayload.fromString(
      'synthetic|!fixture:invalid|null',
    );
    expect(legacy.reminder, isFalse);
    expect(legacy.roomId, '!fixture:invalid');
    expect(
      FluffyChatPushPayload.fromString('a|b|c|other').roomId,
      isNull,
      reason: 'Unknown payload suffixes are rejected',
    );
  });

  test('incognito Dismiss and legacy mute exist as actions', () {
    expect(
      FluffyChatNotificationActions.values.map((a) => a.name),
      containsAll(['dismiss', 'markAsRead', 'mute']),
    );
  });

  test('optional payload values round trip as null, not the string null', () {
    final original = FluffyChatPushPayload(
      'synthetic',
      '!fixture:invalid',
      null,
    );
    final parsed = FluffyChatPushPayload.fromString(original.toString());
    expect(parsed.clientName, original.clientName);
    expect(parsed.roomId, original.roomId);
    expect(parsed.eventId, isNull);
    final invalid = FluffyChatPushPayload.fromString('malformed');
    expect(invalid.clientName, isNull);
    expect(invalid.roomId, isNull);
    expect(invalid.eventId, isNull);
  });

  test('background action JSON accepts an absent plugin data map', () {
    final action = NotificationResponseJson.fromJsonString(
      '{"type":"selectedNotificationAction","actionId":"markAsRead","data":null}',
    );
    expect(
      action.notificationResponseType,
      NotificationResponseType.selectedNotificationAction,
    );
    expect(action.actionId, 'markAsRead');
    expect(action.data, isEmpty);
  });

  for (final notifications in [
    <ActiveNotification>[],
    [const ActiveNotification(id: 42, groupKey: 'synthetic')],
  ]) {
    test(
      'late summary query cannot publish or cancel notifications (${notifications.length})',
      () async {
        final plugin = _SummaryNotifications();
        final locale = await L10n.delegate.load(const Locale('en'));
        await expectLater(
          updateSummaryNotification(
            flutterLocalNotificationsPlugin: plugin,
            clientName: 'synthetic',
            l10n: locale,
            work: PushWorkBudget(limit: const Duration(milliseconds: 10)),
          ),
          throwsA(isA<TimeoutException>()),
        );
        plugin.gate.complete(notifications);
        await Future<void>.value();
        expect(plugin.shown, 0);
        expect(plugin.cancelled, 0);
      },
    );
  }

  test('a stuck background action never blocks startup: bounded wait, '
      'stale mapping removed, no exception', () async {
    final port = ReceivePort();
    addTearDown(() {
      IsolateNameServer.removePortNameMapping(AppConfig.pushIsolatePortName);
      port.close();
    });
    IsolateNameServer.removePortNameMapping(AppConfig.pushIsolatePortName);
    expect(
      await waitForPushIsolateDone(timeout: Duration.zero),
      isTrue,
    );
    IsolateNameServer.registerPortWithName(
      port.sendPort,
      AppConfig.pushIsolatePortName,
    );
    expect(
      await waitForPushIsolateDone(
        timeout: const Duration(milliseconds: 50),
        poll: const Duration(milliseconds: 5),
      ),
      isFalse,
    );
    expect(
      IsolateNameServer.lookupPortByName(AppConfig.pushIsolatePortName),
      isNull,
    );
  });
}

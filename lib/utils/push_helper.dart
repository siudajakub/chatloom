// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:collection/collection.dart';
import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/personal/inbox_projection.dart';
import 'package:fluffychat/personal/notification_eligibility.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/personal/round_video/telegram_media_protocol.dart';
import 'package:fluffychat/utils/call_kit_params.dart';
import 'package:fluffychat/utils/client_manager.dart';
import 'package:fluffychat/utils/matrix_live_kit_calls/matrix_live_kit_call.dart';
import 'package:fluffychat/utils/notification_background_handler.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/start_push_foreground_service.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_new_badger/flutter_new_badger.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart' hide Result;
import 'package:shared_preferences/shared_preferences.dart';

final Map<String, DateTime> lastReceivedPushNotification = {};

Future<void> pushHelper(
  PushNotification notification, {
  List<Client>? clients,
  L10n? l10n,
  String? activeRoomId,
  required FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin,
}) async {
  PersonalPrivacy.installLogging();
  l10n ??= await lookupL10n(PlatformDispatcher.instance.locale);

  try {
    await _tryPushHelper(
      notification,
      clients: clients,
      l10n: l10n,
      activeRoomId: activeRoomId,
      flutterLocalNotificationsPlugin: flutterLocalNotificationsPlugin,
    ).timeout(const Duration(seconds: 30));
  } catch (e, s) {
    if (PlatformInfos.isAndroid &&
        e is! TimeoutException &&
        e is! IOException &&
        e is! http.ClientException) {
      Logs().e('Push Helper has crashed! Writing into temporary file...', e, s);
      final store = await SharedPreferences.getInstance();
      await store.setStringList(AppConfig.pushHelperCrashReportKey, [
        'push_failed',
        e.runtimeType.toString(),
      ]);
    }

    if (notification.roomId != null) {
      await flutterLocalNotificationsPlugin.show(
        id: notification.notificationId,
        title: 'Personal Chat',
        body: l10n.openAppToReadMessages,
        notificationDetails: NotificationDetails(
          iOS: DarwinNotificationDetails(
            threadIdentifier:
                '${notification.clientName}_${notification.roomId}',
          ),
          android: AndroidNotificationDetails(
            AppConfig.pushNotificationsChannelId,
            l10n.incomingMessages,
            number: notification.counts?.unread,
            ticker: l10n.unreadChatsInApp(
              AppSettings.applicationName.value,
              (notification.counts?.unread ?? 0).toString(),
            ),
            importance: Importance.high,
            priority: Priority.max,
            shortcutId: notification.roomId,
            category: AndroidNotificationCategory.message,
            groupKey: notification.clientName,
          ),
        ),
      );
    }
    rethrow;
  } finally {
    ForegroundServices.stopService('background_push');
  }
}

/// Content-free FCM wake; decrypt journal before selecting a target.
Future<void> personalReminderWake({
  required List<Client> clients,
  required FlutterLocalNotificationsPlugin plugin,
}) async {
  PersonalPrivacy.installLogging();
  try {
    for (final client in clients) {
      await client.oneShotSync().timeout(const Duration(seconds: 20));
      final personal = PersonalClient.of(client);
      await personal.load();
      await personal.retry();
      for (final event in personal.dueReminderEvents) {
        final target = await PersonalPrivacy.reminderTarget(event);
        if (target == null) {
          continue;
        }
        await personal.presentReminder(
          event,
          () => plugin.show(
            id: ('reminder_${event.content['entityId']}').hashCode,
            title: 'Personal Chat',
            body: 'Masz przypomnienie o rozmowie.',
            notificationDetails: NotificationDetails(
              android: AndroidNotificationDetails(
                AppConfig.pushNotificationsChannelId,
                'Przypomnienia',
                importance: Importance.high,
                visibility: NotificationVisibility.private,
              ),
              macOS: const DarwinNotificationDetails(),
            ),
            payload: FluffyChatPushPayload(
              client.clientName,
              target.id,
              null,
            ).toString(),
          ),
        );
      }
    }
  } finally {
    ForegroundServices.stopService('background_push');
  }
}

Future<void> _tryPushHelper(
  PushNotification notification, {
  List<Client>? clients,
  L10n? l10n,
  String? activeRoomId,
  required FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin,
}) async {
  final isBackgroundMessage = clients == null;
  Logs().v(
    'Push helper has been started (background=$isBackgroundMessage).',
    notification.toJson(),
  );

  final clientName = notification.clientName;
  final store = await AppSettings.init();

  final client = clientName == null
      ? (clients?.first ??
            (await ClientManager.getClients(
              initialize: false,
              store: store,
            )).first)
      : (clients?.firstWhereOrNull(
              (client) => client.clientName == clientName,
            ) ??
            await ClientManager.createClient(clientName, store));

  lastReceivedPushNotification[client.clientName] = DateTime.now();

  l10n ??= await L10n.delegate.load(PlatformDispatcher.instance.locale);

  Logs().v('Load event...');
  final event = await client.getEventByPushNotification(
    notification,
    storeInDatabase: false,
  );

  // Known bridge controls are internal state, including background pushes.
  if (event != null && isTelegramMediaControl(event.type)) return;
  updateAppBadge(notification.counts?.unread ?? 0);

  if (event == null) {
    Logs().v('Notification is a clearing indicator.');
    if (clients?.length == 1 && (notification.counts?.unread == 0)) {
      await flutterLocalNotificationsPlugin.cancelAll();
    } else {
      // Make sure client is fully loaded and synced before dismiss notifications:
      await client.roomsLoading;
      await client
          .oneShotSync()
          .timeout(const Duration(seconds: 8))
          .catchError((_) => null);

      final activeNotifications = await flutterLocalNotificationsPlugin
          .getActiveNotifications();
      activeNotifications.removeWhere(
        (notification) => notification.groupKey != client.clientName,
      );
      var needsUpdateForSummaryNotification = false;
      for (final activeNotification in activeNotifications) {
        final room = client.rooms.singleWhereOrNull(
          (room) =>
              '${client.clientName}_${room.id}'.hashCode ==
              activeNotification.id,
        );
        if (room != null && !room.isUnreadOrInvited) {
          flutterLocalNotificationsPlugin.cancel(id: activeNotification.id!);
          if (PlatformInfos.isAndroid) needsUpdateForSummaryNotification = true;
        }
      }
      if (needsUpdateForSummaryNotification) {
        await updateSummaryNotification(
          clientName: client.clientName,
          l10n: l10n,
          flutterLocalNotificationsPlugin: flutterLocalNotificationsPlugin,
        );
      }
    }
    return;
  }

  Logs().v('Push helper got notification event of type ${event.type}.');

  if (!client.pushruleEvaluator.match(event).notify) {
    Logs().i('Push helper: filtered by client-side push rules.');
    return;
  }

  if (event.type == RtcNotificationContent.eventType &&
      event.tryParseRtcNotificationContent()?.notificationType == .ring &&
      PlatformInfos.isMobile) {
    _showIncomingCall(event, l10n);
    return;
  }

  if (notification.roomId != null &&
      activeRoomId == notification.roomId &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
    Logs().v('Room is in foreground. Stop push helper here.');
    return;
  }

  if (PersonalPrivacy.isJournal(event.room)) {
    final target = await PersonalPrivacy.reminderTarget(event);
    if (target == null) {
      return;
    }
    await PersonalClient.of(client).presentReminder(
      event,
      () => flutterLocalNotificationsPlugin.show(
        id: ('reminder_${event.content['entityId']}').hashCode,
        title: 'Personal Chat',
        body: 'Masz przypomnienie o rozmowie.',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            AppConfig.pushNotificationsChannelId,
            'Przypomnienia',
            importance: Importance.high,
            visibility: NotificationVisibility.private,
          ),
          macOS: const DarwinNotificationDetails(),
        ),
        payload: FluffyChatPushPayload(
          client.clientName,
          target.id,
          null,
        ).toString(),
      ),
    );
    return;
  }
  final personal = PersonalClient.of(client);
  await personal.load();
  if (!await personalNotificationEligible(
    event,
    InboxProjection(personal).metadataFor(event.room),
  )) {
    return;
  }
  await flutterLocalNotificationsPlugin.show(
    id: notification.notificationId,
    title: 'Personal Chat',
    body: 'Open the app to read your message.',
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        AppConfig.pushNotificationsChannelId,
        l10n.incomingMessages,
        importance: Importance.high,
        priority: Priority.high,
        visibility: NotificationVisibility.private,
        groupKey: client.clientName,
        actions: [
          AndroidNotificationAction(
            FluffyChatNotificationActions.markAsRead.name,
            l10n.markAsRead,
          ),
        ],
      ),
      iOS: const DarwinNotificationDetails(),
      macOS: const DarwinNotificationDetails(),
    ),
    payload: FluffyChatPushPayload(
      client.clientName,
      event.room.id,
      event.eventId,
    ).toString(),
  );
}

void updateAppBadge(int unreadCount) {
  if (PlatformInfos.isAndroid || PlatformInfos.isMacOS || PlatformInfos.isIOS) {
    if (unreadCount == 0) {
      FlutterNewBadger.removeBadge();
    } else {
      FlutterNewBadger.setBadge(unreadCount);
    }
    return;
  }
}

Future<void> updateSummaryNotification({
  required FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin,
  required String clientName,
  required L10n l10n,
}) async {
  final activeNotifications =
      (await flutterLocalNotificationsPlugin.getActiveNotifications())
          .where((n) => n.groupKey == clientName && n.id != clientName.hashCode)
          .toList();

  if (activeNotifications.isEmpty) {
    await flutterLocalNotificationsPlugin.cancel(id: clientName.hashCode);
    return;
  }

  if (activeNotifications.any(
    (notification) => notification.id == clientName.hashCode,
  )) {
    // Already have a visible summary notification!
    return;
  }

  await flutterLocalNotificationsPlugin.show(
    id: clientName.hashCode,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        AppConfig.pushNotificationsChannelId,
        l10n.incomingMessages,
        groupKey: clientName,
        setAsGroupSummary: true,
        styleInformation: InboxStyleInformation(
          activeNotifications.map((n) => n.body ?? '').toList(),
        ),
        autoCancel: false,
        silent: true,
      ),
    ),
  );
}

class FluffyChatPushPayload {
  final String? clientName, roomId, eventId;

  FluffyChatPushPayload(this.clientName, this.roomId, this.eventId);

  factory FluffyChatPushPayload.fromString(String payload) {
    final parts = payload.split('|');
    if (parts.length != 3) {
      return FluffyChatPushPayload(null, null, null);
    }
    return FluffyChatPushPayload(parts.first, parts[1], parts[2]);
  }

  @override
  String toString() => '$clientName|$roomId|$eventId';
}

extension on PushNotification {
  String? get clientName =>
      devices?.firstOrNull?.data?.tryGet<String>('client_name');
  int get notificationId {
    final roomId = this.roomId;
    if (roomId == null) return 0;
    final clientName = this.clientName;
    if (clientName == null) return roomId.hashCode;
    return '${clientName}_$roomId'.hashCode;
  }
}

Future<void> _showIncomingCall(Event event, L10n l10n) async {
  final callId = '${event.room.id}|${event.room.client.clientName}';
  final activeCalls = await FlutterCallkitIncoming.activeCalls();
  if (activeCalls.any((call) => call.id == callId)) {
    Logs().d(
      'Call with this ID is already active. Ignoring this Push Notification...',
      callId,
    );
    return;
  }
  final intentStr = event.content.tryGet<String>('m.call.intent');
  final intent =
      MatrixRtcCallIntent.values.singleWhereOrNull(
        (i) => i.name == intentStr,
      ) ??
      .video;
  final timeout =
      event.tryParseRtcNotificationContent()?.lifetime ??
      RtcNotificationContent.defaultLifetime;
  final params = await buildFluffyChatCallKitParams(
    event.room,
    l10n: l10n,
    intent: intent,
    timeout: timeout,
  );
  final timeoutDateTime = DateTime.now().add(timeout);
  await FlutterCallkitIncoming.showCallkitIncoming(params);

  while (DateTime.now().isBefore(timeoutDateTime)) {
    await event.room.client.oneShotSync();
    if (!event.room.hasActiveMatrixRtcCall) {
      Logs().i('The other party has ended the call');
      await FlutterCallkitIncoming.endCall(params.id);
      break;
    }
    if (event.room.ownMatrixRtcMembership != null) {
      Logs().d('User has joined the call.');
      break;
    }
    if (event.room.getActiveMatrixRtcMembers().any(
      (member) =>
          member.senderId == event.room.client.userID! &&
          member.deviceId != event.room.client.deviceID!,
    )) {
      Logs().i('User has accepted the call on a different device');
      await FlutterCallkitIncoming.endCall(params.id);
      break;
    }
  }
}

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
import 'package:fluffychat/personal/diagnostics.dart';
import 'package:personal_core/personal_core.dart' show PersonalNotificationMode;
import 'package:fluffychat/personal/notification_eligibility.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/personal/round_video/telegram_media_protocol.dart';
import 'package:fluffychat/utils/call_kit_params.dart';
import 'package:fluffychat/utils/client_manager.dart';
import 'package:fluffychat/utils/matrix_live_kit_calls/matrix_live_kit_call.dart';
import 'package:fluffychat/utils/notification_background_handler.dart';
import 'package:fluffychat/utils/notification_client_routing.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/push_work_policy.dart';
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

  var allowFallback = false;
  final work = PushWorkBudget();
  try {
    await _tryPushHelper(
      notification,
      clients: clients,
      l10n: l10n,
      activeRoomId: activeRoomId,
      onFallbackEligibility: (allowed) => allowFallback = allowed,
      work: work,
      flutterLocalNotificationsPlugin: flutterLocalNotificationsPlugin,
    );
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

    if (notification.roomId != null && allowFallback && work.active) {
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
  }
}

/// Content-free FCM wake; decrypt journal before selecting a target.
Future<void> personalReminderWake({
  required List<Client> clients,
  required FlutterLocalNotificationsPlugin plugin,
}) async {
  PersonalPrivacy.installLogging();
  final work = PushWorkBudget();
    for (final client in clients) {
      if (!client.isLogged()) continue;
      await work.wait(() => client.oneShotSync(timeout: Duration.zero));
      final personal = PersonalClient.of(client);
      await work.wait(personal.load);
      await work.wait(personal.retry);
      for (final event in personal.dueReminderEvents) {
        final target = await work.wait(() => PersonalPrivacy.reminderTarget(event));
        if (target == null) {
          continue;
        }
        work.check();
        await work.wait(() => personal.presentReminder(
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
        ));
      }
    }
}

Future<void> _tryPushHelper(
  PushNotification notification, {
  List<Client>? clients,
  L10n? l10n,
  String? activeRoomId,
  void Function(bool)? onFallbackEligibility,
  required PushWorkBudget work,
  required FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin,
}) async {
  final isBackgroundMessage = clients == null;
  Logs().v('Push helper has been started (background=$isBackgroundMessage).');

  final clientName = notification.clientName;
  final store = await work.wait(AppSettings.init);

  // A removed account must never open a new database or fall back to another
  // account merely because a delayed push carries its old client name.
  final availableClients = clients ??
      await work.wait(() => ClientManager.getClients(initialize: false, store: store));
  final client = selectNotificationClient(availableClients, clientName, (client) => client.clientName);
  if (client == null) return;

  lastReceivedPushNotification[client.clientName] = DateTime.now();

  l10n ??= await L10n.delegate.load(PlatformDispatcher.instance.locale);

  Logs().v('Load event...');
  final event = await work.wait(() => client.getEventByPushNotification(
    notification,
    storeInDatabase: false,
  ));

  // Known bridge controls are internal state, including background pushes.
  if (event != null && isTelegramMediaControl(event.type)) return;
  updateAppBadge(notification.counts?.unread ?? 0);

  if (event == null) {
    Logs().v('Notification is a clearing indicator.');
    if (clients?.length == 1 && (notification.counts?.unread == 0)) {
      await work.wait(flutterLocalNotificationsPlugin.cancelAll);
    } else {
      // Make sure client is fully loaded and synced before dismiss notifications:
      await work.wait(() async => await client.roomsLoading);
      await work.wait(() => client
          .oneShotSync(timeout: Duration.zero)
          .timeout(const Duration(seconds: 8))
          .catchError((_) => null));

      final activeNotifications = await work.wait(flutterLocalNotificationsPlugin
          .getActiveNotifications);
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
          await work.wait(() => flutterLocalNotificationsPlugin.cancel(id: activeNotification.id!));
          if (PlatformInfos.isAndroid) needsUpdateForSummaryNotification = true;
        }
      }
      if (needsUpdateForSummaryNotification) {
        await work.wait(() => updateSummaryNotification(
          clientName: client.clientName,
          l10n: l10n,
          flutterLocalNotificationsPlugin: flutterLocalNotificationsPlugin,
        ));
      }
    }
    return;
  }

  Logs().v('Push helper got notification event of type ${event.type}.');

  if (!client.pushruleEvaluator.match(event).notify) {
    Logs().i('Push helper: filtered by client-side push rules.');
    return;
  }

  final incomingCall =
      event.type == RtcNotificationContent.eventType &&
      event.tryParseRtcNotificationContent()?.notificationType == .ring &&
      PlatformInfos.isMobile;

  if (!incomingCall &&
      notification.roomId != null &&
      activeRoomId == notification.roomId &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
    Logs().v('Room is in foreground. Stop push helper here.');
    return;
  }

  if (PersonalPrivacy.isJournal(event.room)) {
    final target = await work.wait(() => PersonalPrivacy.reminderTarget(event));
    if (target == null) {
      return;
    }
    await work.wait(() => PersonalClient.of(client).presentReminder(
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
    ));
    return;
  }
  final personal = PersonalClient.of(client);
  await work.wait(personal.load);
  if (personal.syncFailure == PrivateSyncFailure.storageUnavailable) return;
  final projection = InboxProjection(personal);
  if (!await work.wait(() => personalNotificationEligible(
    event,
    projection.metadataFor(event.room),
    notificationMode: projection.notificationModeFor(event.room),
  ))) {
    return;
  }
  // An error cannot turn unknown, ignored or mentions-only state into a generic alert.
  onFallbackEligibility?.call(
    projection.notificationModeFor(event.room) == PersonalNotificationMode.all,
  );
  if (incomingCall) {
    await work.wait(() => _showIncomingCall(event, l10n!, work));
    return;
  }
  await work.wait(() => flutterLocalNotificationsPlugin.show(
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
  ));
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
    String? value(String part) => part.isEmpty || part == 'null' ? null : part;
    return FluffyChatPushPayload(value(parts.first), value(parts[1]), value(parts[2]));
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

Future<void> _showIncomingCall(Event event, L10n l10n, PushWorkBudget work) async {
  final callId = '${event.room.id}|${event.room.client.clientName}';
  final activeCalls = await work.wait(FlutterCallkitIncoming.activeCalls);
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
  final params = await work.wait(() => buildFluffyChatCallKitParams(
    event.room,
    l10n: l10n,
    intent: intent,
    timeout: timeout,
  ));
  await work.wait(() => FlutterCallkitIncoming.showCallkitIncoming(params));

  await pollIncomingCall(
    lifetime: timeout < work.remaining ? timeout : work.remaining,
    sync: () => event.room.client.oneShotSync(timeout: Duration.zero),
    finished: () async {
    if (!event.room.hasActiveMatrixRtcCall) {
      Logs().i('The other party has ended the call');
      await FlutterCallkitIncoming.endCall(params.id);
      return true;
    }
    if (event.room.ownMatrixRtcMembership != null) {
      Logs().d('User has joined the call.');
      return true;
    }
    if (event.room.getActiveMatrixRtcMembers().any(
      (member) =>
          member.senderId == event.room.client.userID! &&
          member.deviceId != event.room.client.deviceID!,
    )) {
      Logs().i('User has accepted the call on a different device');
      await FlutterCallkitIncoming.endCall(params.id);
      return true;
    }
    return false;
  });
}

// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/person_location.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/utils/client_manager.dart';
import 'package:chatloom/utils/notification_client_routing.dart';
import 'package:chatloom/utils/push_helper.dart';
import 'package:collection/collection.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import '../config/app_config.dart';
import '../config/setting_keys.dart';

bool _vodInitialized = false;

extension NotificationResponseJson on NotificationResponse {
  String toJsonString() => jsonEncode({
    'type': notificationResponseType.name,
    'id': id,
    'actionId': actionId,
    'input': input,
    'payload': payload,
    'data': data,
  });

  static NotificationResponse fromJsonString(String jsonString) {
    final json = jsonDecode(jsonString) as Map<String, Object?>;
    return NotificationResponse(
      notificationResponseType: NotificationResponseType.values.singleWhere(
        (t) => t.name == json['type'],
      ),
      id: json['id'] as int?,
      actionId: json['actionId'] as String?,
      input: json['input'] as String?,
      payload: json['payload'] as String?,
      data: json['data'] is Map
          ? Map<String, dynamic>.from(json['data'] as Map)
          : const <String, dynamic>{},
    );
  }
}

/// Waits (bounded) for a background notification action to release storage.
///
/// Never throws: startup awaits this before `runApp`, so a slow or crashed
/// action must not leave the app on a frozen splash. After [timeout] the
/// mapping is treated as stale and removed (a still-running action only ever
/// removes its own port), and startup continues. Returns whether the action
/// finished in time.
Future<bool> waitForPushIsolateDone({
  Duration timeout = const Duration(seconds: 30),
  Duration poll = const Duration(milliseconds: 100),
}) async {
  final clock = Stopwatch()..start();
  try {
    while (IsolateNameServer.lookupPortByName(AppConfig.pushIsolatePortName) !=
        null) {
      if (clock.elapsed >= timeout) {
        Logs().w('[Push] background_action_wait_timeout');
        IsolateNameServer.removePortNameMapping(AppConfig.pushIsolatePortName);
        return false;
      }
      await Future<void>.delayed(poll);
    }
    return true;
  } catch (error) {
    Logs().w('[Push] background_action_wait_failed', error.runtimeType);
    return false;
  }
}

@pragma('vm:entry-point')
Future<void> notificationTapBackground(
  NotificationResponse notificationResponse,
) async {
  PersonalPrivacy.installLogging();
  final sendPort = IsolateNameServer.lookupPortByName(
    AppConfig.mainIsolatePortName,
  );
  if (sendPort != null) {
    sendPort.send(notificationResponse.toJsonString());
    Logs().i('Notification tap sent to main isolate!');
    return;
  }
  Logs().i(
    'Main isolate no up - Create temporary client for notification tap intend!',
  );

  // Opening a notification without a running UI has no background action.
  // Validate before opening storage or initializing crypto/network resources.
  if (notificationResponse.notificationResponseType !=
      NotificationResponseType.selectedNotificationAction) {
    return;
  }
  final action = ChatLoomNotificationActions.values.singleWhereOrNull(
    (action) => action.name == notificationResponse.actionId,
  );
  // Dismiss needs no account; legacy mute never changes server push rules.
  if (action == null ||
      action == ChatLoomNotificationActions.open ||
      action == ChatLoomNotificationActions.enterCall ||
      action == ChatLoomNotificationActions.dismiss ||
      action == ChatLoomNotificationActions.mute) {
    return;
  }
  final payload = ChatLoomPushPayload.fromString(
    notificationResponse.payload ?? '',
  );
  if (payload.roomId == null) return;
  if (action == ChatLoomNotificationActions.reply &&
      (notificationResponse.input?.isEmpty ?? true)) {
    return;
  }

  final pushIsolateReceivePort = ReceivePort();
  final ownsPort = IsolateNameServer.registerPortWithName(
    pushIsolateReceivePort.sendPort,
    AppConfig.pushIsolatePortName,
  );
  if (!ownsPort) {
    pushIsolateReceivePort.close();
    Logs().w('[Push] background_action_busy');
    return;
  }
  Client? client;
  try {
    if (!_vodInitialized) {
      await vod.init();
      _vodInitialized = true;
    }
    final store = await AppSettings.init();
    final names = store.getStringList(ClientManager.clientNamespace) ?? [];
    // Notification payloads always carry the account that showed them.
    final clientName = selectNotificationClient(
      names,
      payload.clientName,
      (name) => name,
    );
    if (clientName == null) return;
    client = await ClientManager.createClient(clientName, store);
    client.backgroundSync = false;
    await client.init(
      waitForFirstSync: false,
      waitUntilLoadCompletedLoaded: true,
      preserveSessionOnInitFailure: true,
    );
    unawaited(client.firstSyncReceived?.catchError((Object _) {}));
    if (!client.isLogged()) return;
    await notificationTap(notificationResponse, clients: [client]);
  } catch (error) {
    Logs().w('[Push] background_action_failed', error.runtimeType.toString());
  } finally {
    try {
      await client?.dispose();
    } finally {
      if (IsolateNameServer.lookupPortByName(AppConfig.pushIsolatePortName) ==
          pushIsolateReceivePort.sendPort) {
        IsolateNameServer.removePortNameMapping(AppConfig.pushIsolatePortName);
      }
      pushIsolateReceivePort.close();
    }
  }
  return;
}

Future<void> notificationTap(
  NotificationResponse notificationResponse, {
  GoRouter? router,
  required List<Client> clients,
  L10n? l10n,
}) async {
  Logs().d(
    'Notification action handler started',
    notificationResponse.notificationResponseType.name,
  );
  final payload = ChatLoomPushPayload.fromString(
    notificationResponse.payload ?? '',
  );
  if (payload.roomId == null) return;
  final client = selectNotificationClient(
    clients,
    payload.clientName,
    (client) => client.clientName,
    isLoggedIn: (client) => client.isLogged(),
  );
  if (client == null || !client.isLogged()) return;

  try {
    await updateSummaryNotification(
      flutterLocalNotificationsPlugin: FlutterLocalNotificationsPlugin(),
      clientName: client.clientName,
      l10n: l10n ?? await lookupL10n(AppConfig.appLocale),
    );
  } catch (_) {
    // A stale summary must not block opening the chat.
  }

  switch (notificationResponse.notificationResponseType) {
    case NotificationResponseType.selectedNotification:
      final roomId = payload.roomId;
      if (roomId == null) return;

      if (router == null) {
        Logs().v('Ignore select notification action in background mode');
        return;
      }
      Logs().v('Open room from notification tap', roomId);
      await client.roomsLoading;
      await client.accountDataLoading;
      if (client.getRoomById(roomId) == null) {
        await client
            .waitForRoomInSync(roomId)
            .timeout(const Duration(seconds: 30));
      }
      router.go(
        notificationRoute(
          client,
          roomId,
          payload,
          personGroupId: await personGroupIdForNotification(client, roomId),
        ),
      );
    case NotificationResponseType.selectedNotificationAction:
      final actionType = ChatLoomNotificationActions.values.singleWhereOrNull(
        (action) => action.name == notificationResponse.actionId,
      );
      if (actionType == null) {
        throw Exception('Selected notification with action but no action ID');
      }
      // The plugin already removed the notification; nothing is sent.
      if (actionType == ChatLoomNotificationActions.dismiss ||
          actionType == ChatLoomNotificationActions.mute) {
        return;
      }
      final roomId = payload.roomId;
      if (roomId == null) {
        throw Exception('Selected notification with action but no payload');
      }
      await client.roomsLoading;
      await client.accountDataLoading;
      await client.userDeviceKeysLoading;
      final room = client.getRoomById(roomId);
      if (room == null) {
        throw Exception(
          'Selected notification with action but unknown room $roomId',
        );
      }
      switch (actionType) {
        case ChatLoomNotificationActions.markAsRead:
          final readEvent = payload.eventId ?? room.lastEvent?.eventId;
          if (readEvent != null) {
            await PersonalPrivacy.markRead(room, readEvent, manual: true);
          }
        case ChatLoomNotificationActions.reply:
          final input = notificationResponse.input;
          if (input == null || input.isEmpty) {
            throw Exception(
              'Selected notification with reply action but without input',
            );
          }

          await room.sendTextEvent(
            input,
            parseCommands: false,
            displayPendingEvent: false,
          );
        case ChatLoomNotificationActions.dismiss:
        case ChatLoomNotificationActions.mute:
          // Handled above: never a receipt and never a server push rule.
          return;
        case ChatLoomNotificationActions.open:
          router?.go(
            notificationRoute(
              client,
              roomId,
              payload,
              personGroupId: await personGroupIdForNotification(client, roomId),
            ),
          );
        case ChatLoomNotificationActions.enterCall:
          router?.go('/rooms/$roomId?client=${client.clientName}&action=call');
      }
    case NotificationResponseType.notificationDismissed:
      return;
  }
}

/// Where tapping a notification leads. Reminders open their message. A room
/// merged into a person ([personGroupId]) opens the person's conversation
/// with that room as the initial send source.
String notificationRoute(
  Client client,
  String roomId,
  ChatLoomPushPayload payload, {
  String? personGroupId,
}) {
  if (client.getRoomById(roomId)?.membership == Membership.invite) {
    return '/rooms?client=${client.clientName}';
  }
  final event = payload.reminder ? payload.eventId : null;
  if (personGroupId != null) {
    return personChatLocation(
      personGroupId,
      clientName: client.clientName,
      sourceRoomId: roomId,
      eventId: event,
    );
  }
  return '/rooms/$roomId?client=${client.clientName}'
      '${event == null ? '' : '&event=${Uri.encodeQueryComponent(event)}'}';
}

/// `mute` is kept only so actions on old notifications parse; it no longer
/// changes the account's server push rules (Personal Chat modes are private).
enum ChatLoomNotificationActions {
  markAsRead,
  reply,
  mute,
  open,
  enterCall,
  dismiss,
}

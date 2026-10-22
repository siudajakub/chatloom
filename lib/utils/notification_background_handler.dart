// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/message_notification.dart';
import 'package:chatloom/personal/notification_reply.dart';
import 'package:chatloom/personal/notification_threads.dart';
import 'package:chatloom/personal/person_location.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/read_targets.dart';
import 'package:chatloom/utils/client_manager.dart';
import 'package:chatloom/utils/notification_client_routing.dart';
import 'package:chatloom/utils/push_helper.dart';
import 'package:chatloom/utils/start_push_foreground_service.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
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

/// How long the app waits at start for a notification action of a closed app
/// to release storage ([waitForPushIsolateDone]).
const pushIsolateWait = Duration(seconds: 30);

/// Upper bound of a notification action handled without the running app,
/// from the action's start until its temporary client is closed. Below
/// [pushIsolateWait], so the app never opens the database while the action
/// still holds it (code-client CC-10).
const notificationActionBudget = Duration(seconds: 22);

/// Part of [notificationActionBudget] kept for closing the temporary client.
const notificationActionCloseReserve = Duration(seconds: 4);

/// Waits (bounded) for a background notification action to release storage.
///
/// Never throws: startup awaits this before `runApp`, so a slow or crashed
/// action must not leave the app on a frozen splash. After [timeout] the
/// mapping is treated as stale and removed (a still-running action only ever
/// removes its own port), and startup continues. Returns whether the action
/// finished in time.
Future<bool> waitForPushIsolateDone({
  Duration timeout = pushIsolateWait,
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

/// Key in a forwarded reply's `data`: the name of its claim port.
const _replyClaimKey = 'chatloom_reply_claim';

/// How long a reply forwarded to the running app may wait to be taken.
@visibleForTesting
Duration notificationReplyClaimTimeout = const Duration(seconds: 10);

bool _isReply(NotificationResponse response) =>
    response.notificationResponseType ==
        NotificationResponseType.selectedNotificationAction &&
    response.actionId == ChatLoomNotificationActions.reply.name;

/// Hands a typed reply to the running app exactly once. The app takes it by
/// removing the claim port's name ([claimNotificationReply]). If it does not
/// within [notificationReplyClaimTimeout] (a stale port of a UI engine that
/// is gone, or a stuck start), this isolate removes the name itself and the
/// caller reports "not sent": opening a second client next to a possibly
/// live one could corrupt the encryption state, and a silent loss is worse.
/// Returns whether the running app took the reply.
@visibleForTesting
Future<bool> forwardNotificationReply(
  SendPort main,
  NotificationResponse response,
) async {
  final claim = ReceivePort();
  final name =
      'chatloom_reply_${DateTime.now().microsecondsSinceEpoch}_'
      '${Random.secure().nextInt(1 << 32)}';
  if (!IsolateNameServer.registerPortWithName(claim.sendPort, name)) {
    claim.close();
    return false;
  }
  try {
    main.send(
      NotificationResponse(
        notificationResponseType: response.notificationResponseType,
        id: response.id,
        actionId: response.actionId,
        input: response.input,
        payload: response.payload,
        data: {...response.data, _replyClaimKey: name},
      ).toJsonString(),
    );
    await claim.first.timeout(notificationReplyClaimTimeout);
    return true;
  } on TimeoutException {
    // Whoever removes the name owns the reply.
    return !IsolateNameServer.removePortNameMapping(name);
  } finally {
    IsolateNameServer.removePortNameMapping(name);
    claim.close();
  }
}

/// Takes a reply forwarded by [forwardNotificationReply]. False when the
/// background isolate already gave up on it (and told the user).
@visibleForTesting
bool claimNotificationReply(NotificationResponse response) {
  final name = response.data[_replyClaimKey];
  if (name is! String) return true;
  final port = IsolateNameServer.lookupPortByName(name);
  if (port == null || !IsolateNameServer.removePortNameMapping(name)) {
    return false;
  }
  port.send(true);
  return true;
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
    if (_isReply(notificationResponse)) {
      if (!await forwardNotificationReply(sendPort, notificationResponse)) {
        final id = notificationResponse.id;
        final payload = ChatLoomPushPayload.fromString(
          notificationResponse.payload ?? '',
        );
        if (id != null) {
          await showNotificationReplyResult(
            plugin: FlutterLocalNotificationsPlugin(),
            id: id,
            outcome: NotificationReplyOutcome.unavailable,
            clientName: payload.clientName,
            roomId: payload.roomId,
          );
        }
      }
      return;
    }
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
      action == ChatLoomNotificationActions.dismiss ||
      action == ChatLoomNotificationActions.mute) {
    return;
  }
  final payload = ChatLoomPushPayload.fromString(
    notificationResponse.payload ?? '',
  );
  if (payload.roomId == null) return;
  if (action == ChatLoomNotificationActions.reply &&
      (notificationResponse.input?.trim().isEmpty ?? true)) {
    // Nothing to send: end Android's sending state without opening storage.
    final id = notificationResponse.id;
    if (id != null) {
      await showNotificationReplyResult(
        plugin: FlutterLocalNotificationsPlugin(),
        id: id,
        outcome: NotificationReplyOutcome.empty,
      );
    }
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
  // The plugin's receiver returns at once; the short foreground service keeps
  // the process alive while the action runs, with an accurate text. Best
  // effort: the bound below holds without it.
  final clock = Stopwatch()..start();
  final lease = action == ChatLoomNotificationActions.reply
      ? ForegroundServiceTasks.notificationReply
      : ForegroundServiceTasks.notificationAction;
  unawaited(ForegroundServices.startService(lease));
  final work = notificationActionBudget - notificationActionCloseReserve;
  Client? client;
  var acting = false;
  try {
    await () async {
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
      final created = client = await ClientManager.createClient(
        clientName,
        store,
      );
      created.backgroundSync = false;
      await created.init(
        waitForFirstSync: false,
        waitUntilLoadCompletedLoaded: true,
        preserveSessionOnInitFailure: true,
      );
      unawaited(created.firstSyncReceived?.catchError((Object _) {}));
      if (!created.isLogged()) return;
      acting = true;
      await notificationTap(
        notificationResponse,
        clients: [created],
        // The reply reports its own outcome before the outer bound.
        actionLimit: work - clock.elapsed - const Duration(seconds: 2),
      );
    }().timeout(work - clock.elapsed);
  } on TimeoutException {
    Logs().w('[Push] background_action_timeout');
    final id = notificationResponse.id;
    if (action == ChatLoomNotificationActions.reply && id != null) {
      await showNotificationReplyResult(
        plugin: FlutterLocalNotificationsPlugin(),
        id: id,
        outcome: acting
            ? NotificationReplyOutcome.notConfirmed
            : NotificationReplyOutcome.unavailable,
        clientName: payload.clientName,
        roomId: payload.roomId,
      );
    }
  } catch (error) {
    Logs().w('[Push] background_action_failed', error.runtimeType.toString());
  } finally {
    try {
      // A reply opened the encrypted private store of this temporary client.
      // Closing also ends any request still running after the bound.
      final opened = client;
      if (opened != null) PersonalClient.of(opened).dispose();
      await opened?.dispose().timeout(notificationActionCloseReserve);
    } catch (_) {
      Logs().w('[Push] background_action_close_failed');
    } finally {
      // Before releasing the port: an app start waiting for it may take the
      // same native service for its push and must keep it.
      try {
        await ForegroundServices.stopService(
          lease,
        ).timeout(const Duration(seconds: 2));
      } catch (_) {}
      if (IsolateNameServer.lookupPortByName(AppConfig.pushIsolatePortName) ==
          pushIsolateReceivePort.sendPort) {
        IsolateNameServer.removePortNameMapping(AppConfig.pushIsolatePortName);
      }
      pushIsolateReceivePort.close();
    }
  }
  return;
}

/// [actionLimit] bounds a reply (a closed app's action budget); the running
/// app uses [notificationReplyLimit].
Future<void> notificationTap(
  NotificationResponse notificationResponse, {
  GoRouter? router,
  required List<Client> clients,
  L10n? l10n,
  Duration? actionLimit,
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
  // Take a forwarded reply before any other work.
  if (_isReply(notificationResponse) &&
      !claimNotificationReply(notificationResponse)) {
    return;
  }
  // Opening a chat from its notification clears it (Android's auto-cancel
  // does on tap; explicit for every platform and the summary below). A
  // merged person opens all its networks: its shared notification and any
  // per-network one posted before the merge go together.
  if (notificationResponse.notificationResponseType ==
          NotificationResponseType.selectedNotification &&
      !payload.reminder) {
    final thread = await loadNotificationThread(client, payload.roomId!);
    final ids = {
      ?notificationResponse.id,
      ...thread.cancelIds,
      // A merge that changed or broke since the notification was posted.
      ...notificationIdsForRooms(
        client.clientName,
        thread.roomIds,
        personal: PersonalClient.of(client),
      ),
    };
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      for (final id in ids) {
        await plugin.cancel(id: id);
      }
    } catch (_) {}
    NotificationThreads.forget(ids);
  }

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
      if (actionType == ChatLoomNotificationActions.reply) {
        // Typed by the user: the durable outbox, a kept draft on failure.
        await sendNotificationReply(
          client: client,
          roomId: roomId,
          input: notificationResponse.input,
          plugin: FlutterLocalNotificationsPlugin(),
          notificationId: notificationResponse.id,
          eventId: payload.eventId,
          limit: actionLimit ?? notificationReplyLimit,
        );
        return;
      }
      await client.roomsLoading;
      await client.accountDataLoading;
      await client.userDeviceKeysLoading;
      final room = client.getRoomById(roomId);
      if (room == null) {
        throw Exception('Selected notification with action but unknown room');
      }
      switch (actionType) {
        case ChatLoomNotificationActions.markAsRead:
          // Incognito (read at action time, so a notification posted before
          // it was turned on follows it too, CC-29): a private read that
          // clears the unread state without telling the sender (CS-32).
          await markNotificationRead(
            client,
            room,
            payload.eventId,
            privateReceipt: AppSettings.personalIncognito.value,
          );
        case ChatLoomNotificationActions.reply:
          // Handled above, never straight to the room.
          return;
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
      }
    case NotificationResponseType.notificationDismissed:
      return;
  }
}

/// "Mark as read" on a message notification: the notified message, and for
/// a merged person (one notification for all networks) every other network
/// up to that message's time. Never a local echo, never past what the
/// notification showed, never back behind a newer read position. The
/// receipt follows the receipt setting (manual action); [privateReceipt]
/// (incognito) keeps it private regardless.
@visibleForTesting
Future<void> markNotificationRead(
  Client client,
  Room room,
  String? eventId, {
  PersonalClient Function(Client client)? personalOf,
  bool privateReceipt = false,
}) async {
  final targets = <(Room, String)>[];
  DateTime? cutoff;
  if (eventId != null && eventId.startsWith(r'$')) {
    targets.add((room, eventId));
    final preview = room.lastEvent;
    if (preview?.eventId == eventId) cutoff = preview!.originServerTs;
    try {
      cutoff ??= (await client.database
              .getEventById(eventId, room)
              .timeout(const Duration(seconds: 2)))
          ?.originServerTs;
    } catch (_) {}
  } else {
    targets.addAll(conversationReadTargets([room]));
  }
  if (cutoff != null) {
    final thread = await loadNotificationThread(
      client,
      room.id,
      personalOf: personalOf,
    );
    for (final id in thread.roomIds.difference({room.id})) {
      final other = client.getRoomById(id);
      if (other == null) continue;
      var loaded = const <Event>[];
      try {
        loaded = await client.database
            .getEventList(other, limit: 30)
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
      final target = conversationReadTarget(
        other,
        loaded: loaded,
        notAfter: cutoff,
      );
      if (target == null) continue;
      var seen = true;
      try {
        seen = await personalNotificationSeen(target);
      } catch (_) {}
      if (!seen) targets.add((other, target.eventId));
    }
  }
  await markConversationRead(targets, privateReceipt: privateReceipt);
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
enum ChatLoomNotificationActions { markAsRead, reply, mute, open, dismiss }

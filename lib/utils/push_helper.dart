// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/personal/diagnostics.dart';
import 'package:fluffychat/personal/inbox_projection.dart';
import 'package:fluffychat/personal/message_notification.dart';
import 'package:fluffychat/personal/message_preview.dart';
import 'package:fluffychat/personal/notification_eligibility.dart';
import 'package:fluffychat/personal/own_sender.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/personal/private_avatar.dart';
import 'package:fluffychat/personal/push_diagnostics.dart';
import 'package:fluffychat/personal/reminder_notification.dart';
import 'package:fluffychat/personal/round_video/telegram_media_protocol.dart';
import 'package:fluffychat/utils/call_kit_params.dart';
import 'package:fluffychat/utils/client_manager.dart';
import 'package:fluffychat/utils/matrix_live_kit_calls/matrix_live_kit_call.dart';
import 'package:fluffychat/utils/notification_avatar_extension.dart';
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
import 'package:personal_core/personal_core.dart'
    show ChatPlacement, PersonalNotificationMode;
import 'package:shared_preferences/shared_preferences.dart';

final Map<String, DateTime> lastReceivedPushNotification = {};

/// Time reserved after loading a message for a generic alert.
const _fallbackReserve = Duration(seconds: 5);

/// Test seam: the private client used for eligibility and previews.
@visibleForTesting
PersonalClient Function(Client client) pushPersonalClientOf = PersonalClient.of;

/// Handles one Matrix push (`event_id_only`, possibly without an account).
///
/// Eligibility and the fallback alert are decided from local private state
/// before any network fetch. The fetch is bounded so a generic alert still
/// fits; that alert has its own small budget. [test] marks the diagnostics
/// test notification: it bypasses only the "already read" and "chat open on
/// screen" checks and adds "(test)" to the title.
Future<void> pushHelper(
  PushNotification notification, {
  List<Client>? clients,
  L10n? l10n,
  String? activeRoomId,
  required FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin,
  bool test = false,
}) async {
  PersonalPrivacy.installLogging();
  final clock = Stopwatch()..start();
  final kind = test
      ? PushKind.test
      : notification.eventId == null || notification.roomId == null
      ? PushKind.countOnly
      : PushKind.message;
  final run = _PushRun(test: test, unread: notification.counts?.unread);
  final work = PushWorkBudget();
  var outcome = PushOutcome.error;
  Object? failure;
  try {
    final locale =
        l10n ?? await work.wait<L10n>(() => lookupL10n(AppConfig.appLocale));
    outcome = await _tryPushHelper(
      notification,
      clients: clients,
      l10n: locale,
      activeRoomId: activeRoomId,
      run: run,
      work: work,
      flutterLocalNotificationsPlugin: flutterLocalNotificationsPlugin,
    );
  } catch (e) {
    failure = e;
    outcome = e is TimeoutException
        ? PushOutcome.timeout
        : run.fetching || e is IOException || e is http.ClientException
        ? PushOutcome.fetchFailed
        : PushOutcome.error;
    if (PlatformInfos.isAndroid &&
        e is! TimeoutException &&
        e is! IOException &&
        e is! http.ClientException) {
      Logs().w('[Push] processing_failed', e.runtimeType.toString());
      try {
        final store = await SharedPreferences.getInstance().timeout(
          const Duration(seconds: 2),
        );
        await store
            .setStringList(AppConfig.pushHelperCrashReportKey, [
              'push_failed',
              e.runtimeType.toString(),
            ])
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    final fallback = run.fallback;
    if (fallback != null) {
      try {
        await _showFallback(fallback, flutterLocalNotificationsPlugin);
        outcome = PushOutcome.shownFallback;
      } catch (_) {
        Logs().w('[Push] fallback_failed');
      }
    }
    rethrow;
  } finally {
    await PushDiagnostics.record(
      kind,
      outcome,
      error: failure,
      elapsed: clock.elapsed,
    );
  }
}

/// Content-free FCM reminder wake: decrypt the journal before selecting a
/// target, then present each due reminder once.
Future<void> personalReminderWake({
  required List<Client> clients,
  required FlutterLocalNotificationsPlugin plugin,
}) async {
  PersonalPrivacy.installLogging();
  final clock = Stopwatch()..start();
  final work = PushWorkBudget();
  var shown = 0;
  Object? failure;
  try {
    for (final client in clients) {
      if (!client.isLogged()) continue;
      await work.wait(() => client.oneShotSync(timeout: Duration.zero));
      final personal = PersonalClient.of(client);
      // The journal timeline is needed to find due results; the message
      // path only ever opens local private storage.
      await work.wait(personal.load);
      await work.wait(personal.retry);
      for (final event in personal.dueReminderEvents) {
        try {
          final result = await presentDueReminder(
            event,
            plugin: plugin,
            work: work,
          );
          if (result == PushOutcome.reminderShown) shown++;
        } on TimeoutException {
          rethrow;
        } catch (error) {
          failure ??= error;
        }
      }
    }
  } catch (error) {
    failure = error;
    await PushDiagnostics.record(
      PushKind.reminder,
      shown > 0
          ? PushOutcome.reminderShown
          : error is TimeoutException
          ? PushOutcome.timeout
          : PushOutcome.error,
      error: error,
      elapsed: clock.elapsed,
    );
    rethrow;
  }
  await PushDiagnostics.record(
    PushKind.reminder,
    shown > 0
        ? PushOutcome.reminderShown
        : failure != null
        ? PushOutcome.error
        : PushOutcome.reminderNone,
    error: failure,
    elapsed: clock.elapsed,
  );
}

class _PushRun {
  final bool test;
  final int? unread;
  _Fallback? fallback;
  bool fetching = false;
  _PushRun({required this.test, required this.unread});
}

class _Fallback {
  final Client client;
  final String roomId;
  final String? chatName;
  final bool group;
  final bool test;
  final int? unread;
  const _Fallback({
    required this.client,
    required this.roomId,
    required this.chatName,
    required this.group,
    required this.test,
    required this.unread,
  });
}

Future<PushOutcome> _tryPushHelper(
  PushNotification notification, {
  List<Client>? clients,
  required L10n l10n,
  String? activeRoomId,
  required _PushRun run,
  required PushWorkBudget work,
  required FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin,
}) async {
  final isBackgroundMessage = clients == null;
  Logs().v('Push helper has been started (background=$isBackgroundMessage).');

  final store = await work.wait(AppSettings.init);

  // A removed account must never open a new database or fall back to another
  // account merely because a delayed push carries its old client name. The
  // Personal gateway sends no account: the single signed-in account is used.
  final availableClients =
      clients ??
      await work.wait<List<Client>>(
        () => ClientManager.getClients(initialize: false, store: store),
      );
  final client = selectNotificationClient<Client>(
    availableClients,
    notification.clientName,
    (client) => client.clientName,
    isLoggedIn: clients == null ? null : (client) => client.isLogged(),
  );
  if (client == null) return PushOutcome.noClient;

  lastReceivedPushNotification[client.clientName] = DateTime.now();

  final roomId = notification.roomId;
  if (notification.eventId == null || roomId == null) {
    updateAppBadge(notification.counts?.unread ?? 0);
    await _clearReadNotifications(
      client,
      unread: notification.counts?.unread,
      single: clients?.length == 1,
      plugin: flutterLocalNotificationsPlugin,
      work: work,
    );
    return PushOutcome.cleared;
  }

  // Decide eligibility and the fallback from local private state first. Only
  // local storage is opened here, never the journal timeline.
  await work.wait(() async => await client.roomsLoading);
  final knownRoom = client.getRoomById(roomId);
  final personal = pushPersonalClientOf(client);
  InboxProjection? projection;
  if (knownRoom == null || !PersonalPrivacy.isJournal(knownRoom)) {
    try {
      await work.wait(personal.loadLocal);
    } on TimeoutException {
      rethrow;
    } catch (_) {
      return PushOutcome.storageUnavailable;
    }
    if (personal.syncFailure == PrivateSyncFailure.storageUnavailable) {
      return PushOutcome.storageUnavailable;
    }
    projection = InboxProjection(personal);
    if (knownRoom != null) {
      final blocked = _blockedOutcome(projection, knownRoom);
      if (blocked != null) return blocked;
      // An error cannot turn unknown, ignored or mentions-only state into a
      // generic alert: only chats that notify for every message fall back.
      if (projection.notificationModeFor(knownRoom) ==
          PersonalNotificationMode.all) {
        run.fallback = _Fallback(
          client: client,
          roomId: roomId,
          chatName: _chatName(projection, knownRoom),
          group: !knownRoom.isDirectChatForDisplay,
          test: run.test,
          unread: run.unread,
        );
      }
    }
  }

  Logs().v('Load event...');
  final fetchBudget = work.remaining - _fallbackReserve;
  if (fetchBudget <= Duration.zero) {
    throw TimeoutException('No time left to load the message');
  }
  run.fetching = true;
  final event = await work.wait(
    () => client
        .getEventByPushNotification(
          notification,
          storeInDatabase: false,
          // Own read-position check below; the SDK one uses timestamps only.
          returnNullIfSeen: false,
          timeoutForServerRequests: fetchBudget < const Duration(seconds: 8)
              ? fetchBudget
              : const Duration(seconds: 8),
        )
        .timeout(fetchBudget),
  );
  run.fetching = false;
  if (event == null) return PushOutcome.cleared;

  // Known bridge controls are internal state, including background pushes.
  if (isTelegramMediaControl(event.type)) return PushOutcome.control;
  updateAppBadge(notification.counts?.unread ?? 0);

  if (PersonalPrivacy.isJournal(event.room)) {
    final outcome = await presentDueReminder(
      event,
      plugin: flutterLocalNotificationsPlugin,
      work: work,
    );
    return outcome == PushOutcome.reminderShown ? outcome : PushOutcome.journal;
  }

  Logs().v('Push helper got notification event of type ${event.type}.');

  // Messages sent by the account or its own bridge ghost never alert.
  if (_isOwnEvent(client, event)) return PushOutcome.own;

  if (!run.test && await _seen(event, work)) {
    await _cancelChatNotification(
      client,
      event.room.id,
      plugin: flutterLocalNotificationsPlugin,
      work: work,
    );
    return PushOutcome.seen;
  }

  if (!client.pushruleEvaluator.match(event).notify) {
    Logs().i('Push helper: filtered by client-side push rules.');
    return PushOutcome.pushRules;
  }

  final incomingCall =
      event.type == RtcNotificationContent.eventType &&
      event.tryParseRtcNotificationContent()?.notificationType == .ring &&
      PlatformInfos.isMobile;

  if (!run.test &&
      !incomingCall &&
      activeRoomId == event.room.id &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
    Logs().v('Room is in foreground. Stop push helper here.');
    return PushOutcome.activeRoom;
  }

  final private = projection ?? InboxProjection(personal);
  final blocked = _blockedOutcome(private, event.room);
  if (blocked != null) return blocked;
  if (!await work.wait(
    () => personalNotificationEligible(
      event,
      private.metadataFor(event.room),
      notificationMode: private.notificationModeFor(event.room),
    ),
  )) {
    return PushOutcome.mentionsOnly;
  }
  if (incomingCall) {
    await work.wait(() => _showIncomingCall(event, l10n, work));
    return PushOutcome.shown;
  }
  await _showMessageNotification(
    client: client,
    event: event,
    projection: private,
    personal: personal,
    unread: notification.counts?.unread,
    test: run.test,
    plugin: flutterLocalNotificationsPlugin,
    work: work,
  );
  return PushOutcome.shown;
}

/// A read-position lookup failure never hides a message.
Future<bool> _seen(Event event, PushWorkBudget work) async {
  try {
    return await work.wait(() => personalNotificationSeen(event));
  } on TimeoutException {
    rethrow;
  } catch (_) {
    return false;
  }
}

PushOutcome? _blockedOutcome(InboxProjection projection, Room room) {
  final metadata = projection.metadataFor(room);
  if (metadata.ignored || metadata.placement == ChatPlacement.ignored) {
    return PushOutcome.ignored;
  }
  if (projection.placementFor(room) == ChatPlacement.ignored) {
    return PushOutcome.ignored;
  }
  if (projection.notificationModeFor(room) == PersonalNotificationMode.muted) {
    return PushOutcome.muted;
  }
  return null;
}

bool _isOwnEvent(Client client, Event event) {
  if (event.senderId == client.userID) return true;
  try {
    return OwnSenderResolver.of(client).isStronglyOwnEvent(event);
  } catch (_) {
    return false;
  }
}

String? _chatName(InboxProjection projection, Room room) {
  try {
    return projection.displayName(room);
  } catch (_) {
    return room.getLocalizedDisplayname();
  }
}

/// Opaque per-sender key for Android conversation ranking; never the
/// Matrix ID itself.
String _personKey(String senderId) =>
    sha256.convert(utf8.encode(senderId)).toString().substring(0, 16);

List<AndroidNotificationAction> _messageActions() =>
    AppSettings.personalIncognito.value
    // Incognito never sends a read receipt from a notification.
    ? [
        AndroidNotificationAction(
          FluffyChatNotificationActions.dismiss.name,
          'Dismiss',
          cancelNotification: true,
        ),
      ]
    : [
        AndroidNotificationAction(
          FluffyChatNotificationActions.markAsRead.name,
          'Mark as read',
          cancelNotification: true,
        ),
      ];

AndroidNotificationDetails _messageDetails({
  required String clientName,
  StyleInformation? style,
  int? unread,
  DateTime? when,
  Uint8List? largeIcon,
}) => AndroidNotificationDetails(
  PersonalNotificationChannels.messagesId,
  PersonalNotificationChannels.messagesName,
  channelDescription: PersonalNotificationChannels.messagesDescription,
  importance: Importance.high,
  priority: Priority.high,
  visibility: NotificationVisibility.private,
  category: AndroidNotificationCategory.message,
  groupKey: clientName,
  ticker: messagePublicTitle,
  number: unread,
  styleInformation: style,
  when: when?.millisecondsSinceEpoch,
  largeIcon: largeIcon == null ? null : ByteArrayAndroidBitmap(largeIcon),
  actions: _messageActions(),
);

/// Avatars of one message notification; null parts were unavailable in time.
class _NotificationAvatars {
  /// Conversation avatar (large icon).
  final Uint8List? chat;

  /// Message sender (MessagingStyle person icon).
  final Uint8List? sender;

  const _NotificationAvatars({this.chat, this.sender});
}

/// Upper bound for avatar loading; a slow media server only drops the icon.
const _avatarBudget = Duration(seconds: 4);

/// Private avatar first, then the room (or bridge partner) avatar, then the
/// sender's profile, which is requested when it is not in memory: the push
/// isolate usually has no members loaded.
Future<_NotificationAvatars> _loadNotificationAvatars({
  required Event event,
  required bool group,
  required String entityId,
  required PersonalClient personal,
  required String senderKey,
  required PushWorkBudget work,
}) async {
  final client = event.room.client;
  final budget = work.remaining - _fallbackReserve;
  if (budget <= Duration.zero) return const _NotificationAvatars();
  final limit = budget < _avatarBudget ? budget : _avatarBudget;
  Future<Uri?> senderAvatarUrl() async {
    final known = event.senderFromMemoryOrFallback.avatarUrl;
    if (known != null) return known;
    final user = await event.room.requestUser(
      event.senderId,
      ignoreErrors: true,
    );
    return user?.avatarUrl;
  }

  try {
    return await () async {
      final roomAvatar = event.room.avatar;
      final results = await Future.wait([
        downloadPrivateAvatar(personal, entityId),
        client.tryDownloadNotificationAvatar(roomAvatar),
        senderAvatarUrl().then(
          (url) => url == roomAvatar
              ? null
              : client.tryDownloadNotificationAvatar(url),
        ),
      ]);
      final roomBytes = results[1];
      final senderBytes = results[2] ?? (group ? null : roomBytes);
      final chat = results[0] ?? roomBytes ?? (group ? null : senderBytes);
      final sender = group ? senderBytes : chat;
      if (sender != null) {
        unawaited(_storePersonIcon(client, senderKey, sender));
      }
      return _NotificationAvatars(chat: chat, sender: sender);
    }().timeout(limit);
  } catch (e) {
    Logs().v('Notification avatars unavailable', e);
    return const _NotificationAvatars();
  }
}

/// Earlier senders' icons live only in the encrypted media cache, keyed by
/// the opaque person key.
Uri _personIconKey(String personKey) =>
    Uri(scheme: 'personal-notification-avatar', host: 'person', path: personKey);

Future<void> _storePersonIcon(
  Client client,
  String personKey,
  Uint8List bytes,
) async {
  try {
    await client.database.storeFile(_personIconKey(personKey), bytes, 0);
  } catch (_) {}
}

Future<Map<String, AndroidIcon<Object>>> _cachedPersonIcons(
  Client client,
  Set<String> keys,
) async {
  final icons = <String, AndroidIcon<Object>>{};
  for (final key in keys) {
    try {
      final bytes = await client.database
          .getFile(_personIconKey(key))
          .timeout(const Duration(seconds: 1));
      if (bytes != null) icons[key] = ByteArrayAndroidIcon(bytes);
    } catch (_) {}
  }
  return icons;
}

Future<void> _showMessageNotification({
  required Client client,
  required Event event,
  required InboxProjection projection,
  required PersonalClient personal,
  required int? unread,
  required bool test,
  required FlutterLocalNotificationsPlugin plugin,
  required PushWorkBudget work,
}) async {
  final room = event.room;
  // The app lock hides names and previews even when previews are on.
  final locked = await work.wait(personalAppLockConfigured);
  final previews = !locked && AppSettings.personalNotificationPreviews.value;
  // Bridged chats are often missing from `m.direct`.
  final group = !room.isDirectChatForDisplay;
  final chatName = _chatName(projection, room);
  final senderName = event.senderFromMemoryOrFallback.calcDisplayname();
  String? preview;
  if (previews && notificationContentAvailable(event)) {
    try {
      preview = personalPreviewLabel(event);
    } catch (_) {
      preview = null;
    }
  }
  final text = messageNotificationText(
    previews: previews,
    chatName: chatName,
    senderName: senderName,
    preview: preview,
    group: group,
    test: test,
    locked: locked,
  );
  final id = messageNotificationId(client.clientName, room.id);
  final senderKey = _personKey(event.senderId);
  // Avatars identify the chat, so they follow the names: never with the
  // generic or locked text.
  final avatars = previews && PlatformInfos.isAndroid
      ? await _loadNotificationAvatars(
          event: event,
          group: group,
          entityId: projection.entityFor(room),
          personal: personal,
          senderKey: senderKey,
          work: work,
        )
      : const _NotificationAvatars();
  MessagingStyleInformation? style;
  if (text.detailed && preview != null && PlatformInfos.isAndroid) {
    MessagingStyleInformation? previous;
    try {
      previous = await work.wait(
        () async => await plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.getActiveNotificationMessagingStyle(id: id),
      );
    } on TimeoutException {
      rethrow;
    } catch (_) {
      previous = null;
    }
    style = messagingStyle(
      text: text,
      chatName: chatName,
      group: group,
      senderName: senderName,
      senderKey: senderKey,
      timestamp: event.originServerTs,
      preview: preview,
      senderIcon: avatars.sender == null
          ? null
          : ByteArrayAndroidIcon(avatars.sender!),
      knownIcons: await _cachedPersonIcons(
        client,
        notificationKeysWithoutIcon(previous)..remove(senderKey),
      ),
      previous: previous,
    );
  }
  await work.wait(() => PersonalNotificationChannels.ensure(plugin));
  await work.wait(
    () => plugin.show(
      id: id,
      title: text.title,
      body: text.body,
      notificationDetails: NotificationDetails(
        android: _messageDetails(
          clientName: client.clientName,
          style: style,
          unread: unread,
          when: event.originServerTs,
          largeIcon: avatars.chat,
        ),
        iOS: DarwinNotificationDetails(
          threadIdentifier: '${client.clientName}_${room.id}',
        ),
        macOS: DarwinNotificationDetails(
          threadIdentifier: '${client.clientName}_${room.id}',
        ),
      ),
      payload: FluffyChatPushPayload(
        client.clientName,
        room.id,
        event.eventId,
      ).toString(),
    ),
  );
  if (PlatformInfos.isAndroid) {
    try {
      await updateSummaryNotification(
        flutterLocalNotificationsPlugin: plugin,
        clientName: client.clientName,
        work: work,
      );
    } on TimeoutException {
      // The chat notification is already shown.
    } catch (_) {}
  }
}

/// Generic alert after a failed or timed-out fetch, with its own budget.
Future<void> _showFallback(
  _Fallback target,
  FlutterLocalNotificationsPlugin plugin,
) async {
  final budget = PushWorkBudget(limit: _fallbackReserve);
  final locked = await budget.wait(personalAppLockConfigured);
  final text = messageNotificationText(
    previews: AppSettings.personalNotificationPreviews.value,
    chatName: target.chatName,
    senderName: null,
    preview: null,
    group: target.group,
    test: target.test,
    locked: locked,
  );
  await budget.wait(() => PersonalNotificationChannels.ensure(plugin));
  await budget.wait(
    () => plugin.show(
      id: messageNotificationId(target.client.clientName, target.roomId),
      title: text.title,
      body: text.body,
      notificationDetails: NotificationDetails(
        android: _messageDetails(
          clientName: target.client.clientName,
          unread: target.unread,
        ),
        iOS: DarwinNotificationDetails(
          threadIdentifier: '${target.client.clientName}_${target.roomId}',
        ),
      ),
      payload: FluffyChatPushPayload(
        target.client.clientName,
        target.roomId,
        null,
      ).toString(),
    ),
  );
}

Future<void> _cancelChatNotification(
  Client client,
  String roomId, {
  required FlutterLocalNotificationsPlugin plugin,
  required PushWorkBudget work,
}) async {
  try {
    await work.wait(
      () => plugin.cancel(id: messageNotificationId(client.clientName, roomId)),
    );
    if (PlatformInfos.isAndroid) {
      await updateSummaryNotification(
        flutterLocalNotificationsPlugin: plugin,
        clientName: client.clientName,
        work: work,
      );
    }
  } on TimeoutException {
    rethrow;
  } catch (_) {}
}

/// Count-only push (read elsewhere): remove notifications of chats that are
/// no longer unread. Reminder notifications are never touched.
Future<void> _clearReadNotifications(
  Client client, {
  required int? unread,
  required bool single,
  required FlutterLocalNotificationsPlugin plugin,
  required PushWorkBudget work,
}) async {
  Logs().v('Notification is a clearing indicator.');
  final active = (await work.wait(
    plugin.getActiveNotifications,
  )).where((n) => n.groupKey == client.clientName && n.id != null).toList();
  if (active.isEmpty) return;
  if (single && unread == 0) {
    for (final notification in active) {
      await work.wait(() => plugin.cancel(id: notification.id!));
    }
    return;
  }
  // Make sure client is fully loaded and synced before dismiss notifications:
  await work.wait(() async => await client.roomsLoading);
  await work.wait(
    () => client
        .oneShotSync(timeout: Duration.zero)
        .timeout(const Duration(seconds: 8))
        .catchError((_) => null),
  );
  var changed = false;
  for (final notification in active) {
    final room = client.rooms.firstWhereOrNull(
      (room) =>
          messageNotificationId(client.clientName, room.id) == notification.id,
    );
    if (room != null && !room.isUnreadOrInvited) {
      await work.wait(() => plugin.cancel(id: notification.id!));
      changed = true;
    }
  }
  if (changed && PlatformInfos.isAndroid) {
    await updateSummaryNotification(
      clientName: client.clientName,
      flutterLocalNotificationsPlugin: plugin,
      work: work,
    );
  }
}

void updateAppBadge(int unreadCount) {
  if (PlatformInfos.isAndroid || PlatformInfos.isMacOS || PlatformInfos.isIOS) {
    // A launcher without badge support must not fail push handling.
    unawaited(
      (unreadCount == 0
              ? FlutterNewBadger.removeBadge()
              : FlutterNewBadger.setBadge(unreadCount))
          .catchError((Object _) {}),
    );
  }
}

/// Keeps one silent group summary ("3 messages in 2 chats") while two or more
/// chats of [clientName] have notifications; removes it otherwise.
Future<void> updateSummaryNotification({
  required FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin,
  required String clientName,
  L10n? l10n,
  PushWorkBudget? work,
}) async {
  final budget = work ?? PushWorkBudget();
  final summaryId = summaryNotificationId(clientName);
  final chats = (await budget.wait(
    flutterLocalNotificationsPlugin.getActiveNotifications,
  )).where((n) => n.groupKey == clientName && n.id != summaryId).toList();

  if (chats.length < 2) {
    await budget.wait(
      () => flutterLocalNotificationsPlugin.cancel(id: summaryId),
    );
    return;
  }

  final android = flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();
  var messages = 0;
  for (final chat in chats) {
    var count = 1;
    if (android != null && chat.id != null) {
      try {
        final style = await budget.wait(
          () => android.getActiveNotificationMessagingStyle(id: chat.id!),
        );
        count = style?.messages?.length ?? 1;
      } on TimeoutException {
        rethrow;
      } catch (_) {}
    }
    messages += count < 1 ? 1 : count;
  }
  final line = notificationSummaryLine(messages, chats.length);
  // Chat titles only without the app lock (older notifications may still
  // carry names from before the lock was set).
  final previews =
      AppSettings.personalNotificationPreviews.value &&
      !await budget.wait(personalAppLockConfigured);
  await budget.wait(
    () => flutterLocalNotificationsPlugin.show(
      id: summaryId,
      title: genericNotificationTitle,
      body: line,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          PersonalNotificationChannels.messagesId,
          PersonalNotificationChannels.messagesName,
          channelDescription: PersonalNotificationChannels.messagesDescription,
          groupKey: clientName,
          setAsGroupSummary: true,
          groupAlertBehavior: GroupAlertBehavior.children,
          visibility: NotificationVisibility.private,
          styleInformation: InboxStyleInformation(
            previews
                ? chats
                      .map((n) => n.title ?? '')
                      .where((title) => title.isNotEmpty)
                      .toList()
                : const [],
            contentTitle: line,
            summaryText: genericNotificationTitle,
          ),
          autoCancel: false,
          silent: true,
          onlyAlertOnce: true,
        ),
      ),
    ),
  );
}

class FluffyChatPushPayload {
  final String? clientName, roomId, eventId;

  /// Opens the reminder's message ([eventId]) instead of the chat bottom.
  final bool reminder;

  FluffyChatPushPayload(
    this.clientName,
    this.roomId,
    this.eventId, {
    this.reminder = false,
  });

  factory FluffyChatPushPayload.fromString(String payload) {
    final parts = payload.split('|');
    if (parts.length != 3 && !(parts.length == 4 && parts[3] == 'reminder')) {
      return FluffyChatPushPayload(null, null, null);
    }
    String? value(String part) => part.isEmpty || part == 'null' ? null : part;
    return FluffyChatPushPayload(
      value(parts.first),
      value(parts[1]),
      value(parts[2]),
      reminder: parts.length == 4,
    );
  }

  @override
  String toString() =>
      '$clientName|$roomId|$eventId${reminder ? '|reminder' : ''}';
}

extension on PushNotification {
  String? get clientName =>
      devices?.firstOrNull?.data?.tryGet<String>('client_name');
}

Future<void> _showIncomingCall(
  Event event,
  L10n l10n,
  PushWorkBudget work,
) async {
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
  final params = await work.wait(
    () => buildFluffyChatCallKitParams(
      event.room,
      l10n: l10n,
      intent: intent,
      timeout: timeout,
    ),
  );
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
    },
  );
}

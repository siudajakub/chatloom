// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/diagnostics.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/message_notification.dart';
import 'package:chatloom/personal/message_preview.dart';
import 'package:chatloom/personal/notification_eligibility.dart';
import 'package:chatloom/personal/notification_reply.dart';
import 'package:chatloom/personal/notification_threads.dart';
import 'package:chatloom/personal/own_sender.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/private_avatar.dart';
import 'package:chatloom/personal/push_diagnostics.dart';
import 'package:chatloom/personal/push_rule_check.dart';
import 'package:chatloom/personal/reminder_notification.dart';
import 'package:chatloom/personal/round_video/telegram_media_protocol.dart';
import 'package:chatloom/personal/seen_chat_notifications.dart';
import 'package:chatloom/utils/client_manager.dart';
import 'package:chatloom/utils/notification_avatar_extension.dart';
import 'package:chatloom/utils/notification_background_handler.dart';
import 'package:chatloom/utils/notification_client_routing.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/utils/push_work_policy.dart';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
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
/// screen" checks and adds "(test)" to the title. Returns the recorded
/// outcome (a failure is rethrown after recording it).
Future<PushOutcome> pushHelper(
  PushNotification notification, {
  List<Client>? clients,
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
    outcome = await _tryPushHelper(
      notification,
      clients: clients,
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
  return outcome;
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

  /// The conversation's notification (a merged person shares one).
  final NotificationThread thread;

  /// A bot or service chat: the quiet channel (see [personalNotificationQuiet]).
  final bool quiet;
  const _Fallback({
    required this.client,
    required this.roomId,
    required this.chatName,
    required this.group,
    required this.test,
    required this.unread,
    required this.thread,
    this.quiet = false,
  });
}

Future<PushOutcome> _tryPushHelper(
  PushNotification notification, {
  List<Client>? clients,
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
          thread: notificationThreadOf(
            client.clientName,
            knownRoom,
            projection,
          ),
          // The sender is unknown before the fetch: the room decides.
          quiet: personalNotificationQuiet(
            technical: _technical(projection, knownRoom),
            fromService: false,
            now: DateTime.now(),
            lastOwnMessage: _ownLastEvent(client, knownRoom),
          ),
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
      event.room,
      projection: projection,
      plugin: flutterLocalNotificationsPlugin,
      work: work,
    );
    return PushOutcome.seen;
  }

  // The server already matched its rules; the phone re-checks the decrypted
  // event with the server's member counts and never vetoes on rules it
  // cannot evaluate (see push_rule_check.dart).
  if (!personalPushRuleVerdict(client, event).allows) {
    Logs().i('Push helper: filtered by client-side push rules.');
    return PushOutcome.pushRules;
  }

  // A merged person page shows its rooms without one room id in the route.
  // Behind the app lock the open chat is not visible, so it still alerts
  // (and is cleared locally once the chat is seen after unlocking).
  if (!run.test &&
      (activeRoomId == event.room.id ||
          SeenChatNotifications.isOpen(client.clientName, event.room.id)) &&
      PersonalPrivacy.surfaceUnlocked &&
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
  await _showMessageNotification(
    client: client,
    event: event,
    projection: private,
    personal: personal,
    unread: notification.counts?.unread,
    test: run.test,
    quiet: await _quiet(client, event, private, work),
    plugin: flutterLocalNotificationsPlugin,
    work: work,
  );
  return PushOutcome.shown;
}

bool _technical(InboxProjection projection, Room room) {
  try {
    return projection.classifier.classify(room).technical;
  } catch (_) {
    return false;
  }
}

/// The room's preview when it is the account's own message (local, no I/O).
DateTime? _ownLastEvent(Client client, Room room) {
  final last = room.lastEvent;
  return last != null && last.senderId == client.userID
      ? last.originServerTs
      : null;
}

/// Bot and service messages alert quietly unless the user just wrote there
/// (see [personalNotificationQuiet]). Only those chats read their recent
/// local history; any failure keeps the normal alert decision on the room.
Future<bool> _quiet(
  Client client,
  Event event,
  InboxProjection projection,
  PushWorkBudget work,
) async {
  final technical = _technical(projection, event.room);
  bool fromService;
  try {
    fromService = projection.classifier.isServiceMember(event.senderId);
  } catch (_) {
    fromService = false;
  }
  if (!technical && !fromService) return false;
  final now = DateTime.now();
  var own = _ownLastEvent(client, event.room);
  if (own == null && work.remaining > _fallbackReserve * 2) {
    try {
      final recent = await client.database
          .getEventList(event.room, limit: 20)
          .timeout(const Duration(seconds: 1));
      for (final candidate in recent) {
        if (candidate.senderId != client.userID) continue;
        if (own == null || candidate.originServerTs.isAfter(own)) {
          own = candidate.originServerTs;
        }
      }
    } catch (_) {}
  }
  return personalNotificationQuiet(
    technical: technical,
    fromService: fromService,
    now: now,
    lastOwnMessage: own,
  );
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

/// Person key of the generic "new message" line of a fallback alert.
const _genericSenderKey = 'chatloom-generic';

/// Inline Reply only where the notification names the chat (previews on, no
/// app lock) and the account can write there; never on the diagnostics test.
/// The reply itself is user-initiated and goes through the durable outbox
/// (`notification_reply.dart`).
bool _offersReply(Room? room, {required bool previews, required bool test}) =>
    previews && !test && room != null && room.canSendDefaultMessages;

List<AndroidNotificationAction> _messageActions({required bool reply}) => [
  if (reply)
    AndroidNotificationAction(
      ChatLoomNotificationActions.reply.name,
      notificationReplyActionLabel,
      inputs: const [
        AndroidNotificationActionInput(label: notificationReplyInputLabel),
      ],
      semanticAction: SemanticAction.reply,
      // The notification shows Android's sending state until the outcome
      // replaces or removes it.
      cancelNotification: false,
    ),
  AppSettings.personalIncognito.value
      // Incognito never sends a read receipt from a notification.
      ? AndroidNotificationAction(
          ChatLoomNotificationActions.dismiss.name,
          'Dismiss',
          cancelNotification: true,
        )
      : AndroidNotificationAction(
          ChatLoomNotificationActions.markAsRead.name,
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
  bool reply = false,
  bool quiet = false,
}) => AndroidNotificationDetails(
  quiet
      ? PersonalNotificationChannels.serviceId
      : PersonalNotificationChannels.messagesId,
  quiet
      ? PersonalNotificationChannels.serviceName
      : PersonalNotificationChannels.messagesName,
  channelDescription: quiet
      ? PersonalNotificationChannels.serviceDescription
      : PersonalNotificationChannels.messagesDescription,
  importance: quiet ? Importance.low : Importance.high,
  priority: quiet ? Priority.low : Priority.high,
  visibility: NotificationVisibility.private,
  category: AndroidNotificationCategory.message,
  groupKey: clientName,
  ticker: messagePublicTitle,
  number: unread,
  styleInformation: style,
  when: when?.millisecondsSinceEpoch,
  largeIcon: largeIcon == null ? null : ByteArrayAndroidBitmap(largeIcon),
  actions: _messageActions(reply: reply),
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
  required PushWorkBudget work,
  required FlutterLocalNotificationsPlugin plugin,
  bool quiet = false,
}) async {
  final room = event.room;
  // The app lock hides names and previews even when previews are on.
  final locked = await work.wait(personalAppLockConfigured);
  final previews = !locked && AppSettings.personalNotificationPreviews.value;
  // Bridged chats are often missing from `m.direct`.
  final group = !room.isDirectChatForDisplay;
  final chatName = _chatName(projection, room);
  // A merged person is one conversation: one notification for all its
  // networks, titled and keyed by the person, not by each network's profile.
  final thread = notificationThreadOf(client.clientName, room, projection);
  final person = thread.group != null && !group;
  final profileName = event.senderFromMemoryOrFallback.calcDisplayname();
  final senderName = person && chatName?.trim().isNotEmpty == true
      ? chatName!
      : profileName;
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
  final id = thread.id;
  final senderKey = _personKey(person ? thread.key : event.senderId);
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
  final replyRoom = notificationReplyRoom(
    personal,
    room,
    eventId: event.eventId,
  );
  // The MessagingStyle line of this message (previews on, content shown).
  final line = text.detailed && PlatformInfos.isAndroid ? preview : null;
  // Read the shown history, add this message, show: one push at a time per
  // notification, so concurrent pushes neither drop nor reorder lines.
  await NotificationThreads.serialize(id, () async {
    MessagingStyleInformation? style;
    MessagingStyleInformation? previous;
    if (line != null) {
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
        preview: line,
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
    // An older message handled last keeps the newer one as tap target.
    final newest = NotificationThreads.newest(
      id,
      NotificationNewest(event.originServerTs, room.id, event.eventId),
    );
    var when = newest.timestamp;
    for (final line in previous?.messages ?? const <Message>[]) {
      if (line.timestamp.isAfter(when)) when = line.timestamp;
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
            when: when,
            largeIcon: avatars.chat,
            reply: _offersReply(replyRoom, previews: previews, test: test),
            quiet: quiet,
          ),
          iOS: DarwinNotificationDetails(
            threadIdentifier: thread.threadIdentifier,
          ),
          macOS: DarwinNotificationDetails(
            threadIdentifier: thread.threadIdentifier,
          ),
        ),
        payload: ChatLoomPushPayload(
          client.clientName,
          newest.roomId,
          newest.eventId,
        ).toString(),
      ),
    );
  });
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
///
/// An earlier message of the same conversation keeps its lines: the generic
/// "new message" is added to the shown history instead of replacing it.
Future<void> _showFallback(
  _Fallback target,
  FlutterLocalNotificationsPlugin plugin,
) async {
  final budget = PushWorkBudget(limit: _fallbackReserve);
  final locked = await budget.wait(personalAppLockConfigured);
  final previews = AppSettings.personalNotificationPreviews.value;
  final text = messageNotificationText(
    previews: previews,
    chatName: target.chatName,
    senderName: null,
    preview: null,
    group: target.group,
    test: target.test,
    locked: locked,
  );
  final thread = target.thread;
  final id = thread.id;
  await budget.wait(() => PersonalNotificationChannels.ensure(plugin));
  await NotificationThreads.serialize(id, () async {
    MessagingStyleInformation? style;
    if (previews && !locked && PlatformInfos.isAndroid) {
      try {
        final previous = await budget.wait(
          () async => await plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.getActiveNotificationMessagingStyle(id: id),
        );
        if (previous?.messages?.isNotEmpty == true) {
          style = messagingStyle(
            text: text,
            chatName: target.chatName,
            group: target.group,
            senderName: target.chatName ?? genericNotificationTitle,
            senderKey: _genericSenderKey,
            timestamp: DateTime.now(),
            preview: genericNotificationBody,
            previous: previous,
          );
        }
      } on TimeoutException {
        rethrow;
      } catch (_) {
        style = null;
      }
    }
    await budget.wait(
      () => plugin.show(
        id: id,
        title: text.title,
        body: text.body,
        notificationDetails: NotificationDetails(
          android: _messageDetails(
            clientName: target.client.clientName,
            style: style,
            unread: target.unread,
            reply: _offersReply(
              target.client.getRoomById(target.roomId),
              previews: previews && !locked,
              test: target.test,
            ),
            quiet: target.quiet,
          ),
          iOS: DarwinNotificationDetails(
            threadIdentifier: thread.threadIdentifier,
          ),
        ),
        payload: ChatLoomPushPayload(
          target.client.clientName,
          target.roomId,
          null,
        ).toString(),
      ),
    );
  });
}

/// Read on another device: removes the room's notification. A merged
/// person's shared notification goes only when no other network of the
/// person still has an unread message in it.
Future<void> _cancelChatNotification(
  Client client,
  Room room, {
  required InboxProjection? projection,
  required FlutterLocalNotificationsPlugin plugin,
  required PushWorkBudget work,
}) async {
  try {
    final thread = notificationThreadOf(client.clientName, room, projection);
    final ids = {messageNotificationId(client.clientName, room.id)};
    final members = thread.roomIds.difference({room.id});
    var othersRead = true;
    for (final member in members) {
      final last = client.getRoomById(member)?.lastEvent;
      if (last == null || last.senderId == client.userID) continue;
      if (!await _seen(last, work)) {
        othersRead = false;
        break;
      }
    }
    if (othersRead) ids.addAll(thread.cancelIds);
    for (final id in ids) {
      await work.wait(() => plugin.cancel(id: id));
    }
    NotificationThreads.forget(ids);
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
/// no longer unread; a merged person's once none of its networks is unread.
/// Reminder notifications are never touched.
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
    NotificationThreads.forget(active.map((n) => n.id!));
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
  // Which rooms each notification can show: single chats and the person
  // merges of the private store (when it opens in time).
  final shows = <int, List<Room>>{
    for (final room in client.rooms)
      messageNotificationId(client.clientName, room.id): [room],
  };
  try {
    final personal = pushPersonalClientOf(client);
    await personal.loadLocal().timeout(const Duration(seconds: 3));
    for (final group in personal.groups) {
      shows[personNotificationId(client.clientName, group.id)] = [
        for (final member in group.members)
          ?client.getRoomById(member.roomId),
      ];
    }
  } catch (_) {}
  var changed = false;
  for (final notification in active) {
    final rooms = shows[notification.id];
    if (rooms != null &&
        rooms.isNotEmpty &&
        rooms.every((room) => !room.isUnreadOrInvited)) {
      await work.wait(() => plugin.cancel(id: notification.id!));
      NotificationThreads.forget([notification.id!]);
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
  if (!PlatformInfos.supportsSystemNotifications) return;
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

class ChatLoomPushPayload {
  final String? clientName, roomId, eventId;

  /// Opens the reminder's message ([eventId]) instead of the chat bottom.
  final bool reminder;

  ChatLoomPushPayload(
    this.clientName,
    this.roomId,
    this.eventId, {
    this.reminder = false,
  });

  factory ChatLoomPushPayload.fromString(String payload) {
    final parts = payload.split('|');
    if (parts.length != 3 && !(parts.length == 4 && parts[3] == 'reminder')) {
      return ChatLoomPushPayload(null, null, null);
    }
    String? value(String part) => part.isEmpty || part == 'null' ? null : part;
    return ChatLoomPushPayload(
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

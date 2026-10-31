// SPDX-License-Identifier: AGPL-3.0-or-later

/// "Anna deleted a message" (Keep deleted messages, J 2026-10-31): one extra
/// notification per message somebody else deleted, with its kept text,
/// grouped with the chat's notifications. Notifications already shown are
/// never rewritten. The same privacy rules as message notifications apply:
/// previews off → no names or text, app lock → the locked text only,
/// `NotificationVisibility.private` on Android lock screens, and a chat that
/// is muted or ignored (or mentions-only) gets none.
library;

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/deleted_messages.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/kept_messages.dart';
import 'package:chatloom/personal/message_notification.dart';
import 'package:chatloom/personal/message_preview.dart';
import 'package:chatloom/personal/notification_eligibility.dart';
import 'package:chatloom/personal/notification_threads.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/utils/push_helper.dart' show ChatLoomPushPayload;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:matrix/matrix.dart';

/// Title and body of a deletion notification.
MessageNotificationText deletionNotificationText({
  required bool previews,
  required bool locked,
  required String? chatName,
  required String deleterName,
  required String? preview,
  required bool group,
  L10n? l10n,
}) {
  final words = l10n ?? englishL10n;
  if (locked) {
    return const MessageNotificationText(
      messagePublicTitle,
      lockedNotificationBody,
    );
  }
  if (!previews) {
    return MessageNotificationText(
      genericNotificationTitle,
      words.aMessageWasDeleted,
    );
  }
  final who = words.userDeletedAMessage(deleterName);
  final chat = chatName?.trim().isNotEmpty == true ? chatName!.trim() : null;
  final quote = preview == null || preview.trim().isEmpty
      ? null
      : '“${preview.trim()}”';
  if (group) {
    return MessageNotificationText(
      chat ?? who,
      quote == null ? who : '$who: $quote',
      detailed: true,
    );
  }
  return MessageNotificationText(who, quote ?? who, detailed: true);
}

/// The id of [kept]'s deletion notification: one per deleted message,
/// never the chat's own notification.
int deletionNotificationId(String clientName, String roomId, String eventId) =>
    '${clientName}_${roomId}_deleted_$eventId'.hashCode;

/// Posts the deletion notification of [kept] in [room] unless the chat's
/// notification policy says no. [chatOpen] skips it while the user is
/// looking at that chat.
Future<void> showKeptDeletionNotification(
  Room room,
  KeptMessage kept, {
  FlutterLocalNotificationsPlugin? plugin,
  bool Function(Room room)? chatOpen,
  L10n? l10n,
}) async {
  if (!PlatformInfos.supportsSystemNotifications) return;
  if (chatOpen?.call(room) ?? false) return;
  final client = room.client;
  final personal = PersonalClient.of(client);
  try {
    await personal.loadLocal();
  } catch (_) {
    return;
  }
  final projection = InboxProjection(personal);
  final event = kept.toEvent(room);
  if (!await personalNotificationEligible(
    event,
    projection.metadataFor(room),
    notificationMode: projection.notificationModeFor(room),
  )) {
    return;
  }
  final locked = await personalAppLockConfigured();
  final previews = !locked && AppSettings.personalNotificationPreviews.value;
  final text = deletionNotificationText(
    previews: previews,
    locked: locked,
    chatName: projection.displayName(room),
    deleterName: room
        .unsafeGetUserFromMemoryOrFallback(kept.deletedBy)
        .calcDisplayname(),
    preview: previews ? personalPreviewLabel(event) : null,
    group: !room.isDirectChatForDisplay,
    l10n: l10n,
  );
  final notifications = plugin ?? FlutterLocalNotificationsPlugin();
  if (PlatformInfos.isAndroid) {
    await PersonalNotificationChannels.ensure(notifications);
  }
  final thread = notificationThreadOf(client.clientName, room, projection);
  await notifications.show(
    id: deletionNotificationId(client.clientName, room.id, kept.eventId),
    title: text.title,
    body: text.body,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        PersonalNotificationChannels.messagesId,
        PersonalNotificationChannels.messagesName,
        channelDescription: PersonalNotificationChannels.messagesDescription,
        importance: Importance.high,
        priority: Priority.high,
        visibility: NotificationVisibility.private,
        category: AndroidNotificationCategory.message,
        groupKey: client.clientName,
        ticker: messagePublicTitle,
        when: kept.deletedAt.millisecondsSinceEpoch,
      ),
      macOS: DarwinNotificationDetails(
        threadIdentifier: thread.threadIdentifier,
      ),
    ),
    payload: ChatLoomPushPayload(
      client.clientName,
      room.id,
      kept.eventId,
    ).toString(),
  );
}

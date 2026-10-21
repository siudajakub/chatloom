// SPDX-License-Identifier: AGPL-3.0-or-later

/// The single presenter for due conversation reminders.
///
/// Used by the content-free FCM reminder wake, by a Matrix push of a journal
/// result and by the foreground journal listener. The reminder target and the
/// anchored message are resolved and decrypted on this device only; the
/// worker relay and the gateway stay content-free. Trust checks
/// ([PersonalPrivacy.reminderTarget]) and the once-only claim
/// ([PersonalClient.presentReminder]) are unchanged.
library;

import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/message_notification.dart';
import 'package:chatloom/personal/message_preview.dart';
import 'package:chatloom/personal/own_sender.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/push_diagnostics.dart';
import 'package:chatloom/utils/notification_client_routing.dart';
import 'package:chatloom/utils/push_helper.dart';
import 'package:chatloom/utils/push_work_policy.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart' show PersonalOperation;

const reminderTitlePrefix = '⏰ Reminder';
const reminderFallbackBody = 'Reminder about this chat';
const reminderUnavailableBody = 'Open to see the message';

/// Content-free ticker title; Android provides the lock-screen placeholder.
const reminderPublicTitle = 'Reminder';

class ReminderNotificationText {
  final String title;
  final String body;
  const ReminderNotificationText(this.title, this.body);
}

/// [preview] already carries its sender prefix ("You: Photo", "Anna: Hi").
/// [messageKnown]: an anchored or latest message exists but may be
/// unreadable on this device.
///
/// [locked] (app lock configured) shows neither the chat nor the message.
ReminderNotificationText reminderNotificationText({
  required bool previews,
  required String? chatName,
  required String? preview,
  required bool messageKnown,
  bool locked = false,
}) {
  if (locked) {
    return const ReminderNotificationText(
      reminderTitlePrefix,
      lockedNotificationBody,
    );
  }
  final chat = chatName?.trim().isNotEmpty == true ? chatName!.trim() : null;
  if (!previews) {
    return const ReminderNotificationText(
      reminderTitlePrefix,
      reminderFallbackBody,
    );
  }
  return ReminderNotificationText(
    chat == null ? reminderTitlePrefix : '$reminderTitlePrefix · $chat',
    preview?.trim().isNotEmpty == true
        ? preview!.trim()
        : messageKnown
        ? reminderUnavailableBody
        : reminderFallbackBody,
  );
}

/// The message a reminder was created for, if the payload names a valid one.
String? reminderAnchorEventId(Object? payload) {
  if (payload is! Map) return null;
  final anchor = payload['anchorEventId'];
  return anchor is String && anchor.startsWith(r'$') && anchor.length <= 255
      ? anchor
      : null;
}

/// "You: …" for own messages (account or own bridge ghost), otherwise
/// "`<sender>`: …". Null when this device cannot show the content.
String? reminderMessagePreview(Event event, {required bool own}) {
  if (!notificationContentAvailable(event)) return null;
  try {
    return personalPreview(
      event,
      own: own,
      group: true,
      senderName: own
          ? null
          : event.senderFromMemoryOrFallback.calcDisplayname(),
    );
  } catch (_) {
    return null;
  }
}

/// Anchor (local database first, then the server, decrypted locally),
/// bounded by [timeout]. Without an anchor, the conversation's latest event.
///
/// An anchored reminder never falls back to the latest event: that would
/// show a different message than the one the reminder was set on. Null then
/// means "anchored message not available on this device yet".
Future<Event?> resolveReminderMessage(
  Room target,
  String? anchorEventId, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  if (anchorEventId == null) return target.lastEvent;
  if (timeout <= Duration.zero) return null;
  try {
    final event = await target.getEventById(anchorEventId).timeout(timeout);
    if (event != null && event.roomId == target.id) return event;
  } catch (_) {
    // Unreachable or not yet synced.
  }
  return null;
}

/// Presents [resultEvent] (a trusted, due `reminder.result`) at most once.
Future<PushOutcome> presentDueReminder(
  Event resultEvent, {
  required FlutterLocalNotificationsPlugin plugin,
  PushWorkBudget? work,
}) async {
  final budget = work ?? PushWorkBudget();
  final target = await budget.wait(
    () => PersonalPrivacy.reminderTarget(resultEvent),
  );
  if (target == null) return PushOutcome.reminderNone;
  final client = resultEvent.room.client;
  final personal = PersonalClient.of(client);
  var shown = false;
  await budget.wait(
    () => personal.presentReminder(resultEvent, () async {
      final payload = _resultPayload(resultEvent);
      final anchorEventId = reminderAnchorEventId(payload);
      final remaining = budget.remaining - const Duration(seconds: 3);
      final message = await resolveReminderMessage(
        target,
        anchorEventId,
        timeout: remaining > const Duration(seconds: 8)
            ? const Duration(seconds: 8)
            : remaining,
      );
      budget.check();
      String? chatName;
      try {
        chatName = InboxProjection(personal).displayName(target);
      } catch (_) {
        chatName = target.getLocalizedDisplayname();
      }
      bool own;
      try {
        own =
            message != null && OwnSenderResolver.of(client).isOwnEvent(message);
      } catch (_) {
        own = message?.senderId == client.userID;
      }
      final locked = await budget.wait(personalAppLockConfigured);
      final text = reminderNotificationText(
        locked: locked,
        previews: AppSettings.personalNotificationPreviews.value,
        chatName: chatName,
        preview: message == null
            ? null
            : reminderMessagePreview(message, own: own),
        messageKnown: message != null || anchorEventId != null,
      );
      await PersonalNotificationChannels.ensure(plugin);
      await budget.wait(
        () => plugin.show(
          id: reminderNotificationId(resultEvent.content['entityId']),
          title: text.title,
          body: text.body,
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              PersonalNotificationChannels.remindersId,
              PersonalNotificationChannels.remindersName,
              channelDescription:
                  PersonalNotificationChannels.remindersDescription,
              importance: Importance.high,
              priority: Priority.high,
              visibility: NotificationVisibility.private,
              category: AndroidNotificationCategory.reminder,
              ticker: reminderPublicTitle,
              styleInformation: BigTextStyleInformation(
                text.body,
                contentTitle: text.title,
              ),
            ),
            macOS: const DarwinNotificationDetails(),
          ),
          payload: ChatLoomPushPayload(
            client.clientName,
            target.id,
            message?.eventId,
            reminder: true,
          ).toString(),
        ),
      );
      shown = true;
    }),
  );
  return shown ? PushOutcome.reminderShown : PushOutcome.reminderNone;
}

Map<String, Object?> _resultPayload(Event event) {
  try {
    return PersonalOperation.fromJson(event.content).payload;
  } catch (_) {
    final payload = event.content['payload'];
    return payload is Map ? Map<String, Object?>.from(payload) : const {};
  }
}

// SPDX-License-Identifier: AGPL-3.0-or-later

/// Content and policy of message notifications, independent of the push
/// transport so it can be tested without a device.
///
/// Message text is decrypted on this device only. The gateway and FCM never
/// carry it. Lock-screen redaction relies on `NotificationVisibility.private`:
/// flutter_local_notifications 22 cannot attach a custom public version, so
/// Android shows its own placeholder ("Contents hidden") on secure lock screens
/// when the user hides sensitive content. While the app lock is configured,
/// notifications never carry names or previews at all.
library;

import 'dart:async';

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/utils/personal_secure_storage.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:matrix/matrix.dart';

const genericNotificationTitle = 'ChatLoom';
const genericNotificationBody = 'Open the app to read your message.';

/// Body of every notification while the app lock is configured.
const lockedNotificationBody = 'Open the app to read';

/// Secure-storage key of the app lock PIN (`lib/widgets/app_lock.dart`).
const appLockStorageKey = 'chat.fluffy.app_lock';

/// Test seam replacing [personalAppLockConfigured].
@visibleForTesting
Future<bool> Function()? debugAppLockConfigured;

/// Whether the app lock (PIN, optionally unlocked with biometrics) is set.
///
/// Read from secure storage on every notification, so it works in the
/// background push isolate (which already reads the database key from the
/// same storage) and follows a PIN change without a restart. Fails closed.
Future<bool> personalAppLockConfigured() {
  final override = debugAppLockConfigured;
  if (override != null) return override();
  if (!PlatformInfos.supportsAppLock) return Future.value(false);
  return appLockPinConfigured(
    () => personalSecureStorage.read(key: appLockStorageKey),
  );
}

/// Same validity rule as the lock screen (`AppLock.isActive`): at least four
/// digits. Unreadable storage counts as locked, so content is never shown by
/// accident.
@visibleForTesting
Future<bool> appLockPinConfigured(Future<String?> Function() read) async {
  try {
    final pin = await read().timeout(const Duration(seconds: 2));
    return pin != null && pin.length >= 4 && int.tryParse(pin) != null;
  } catch (_) {
    return true;
  }
}

/// Intended lock-screen text (see the library comment for the platform limit).
const messagePublicTitle = 'New message';
const messagePublicBody = 'Unlock to view';

/// Separate Android channels so users can tune messages and reminders apart.
abstract final class PersonalNotificationChannels {
  static const messagesId = AppConfig.pushNotificationsChannelId;
  static const messagesName = 'Messages';
  static const messagesDescription = 'New messages in your chats';
  static const remindersId = AppConfig.personalRemindersChannelId;
  static const remindersName = 'Reminders';
  static const remindersDescription = 'Conversation reminders you set';

  static const messages = AndroidNotificationChannel(
    messagesId,
    messagesName,
    description: messagesDescription,
    importance: Importance.high,
  );
  static const reminders = AndroidNotificationChannel(
    remindersId,
    remindersName,
    description: remindersDescription,
    importance: Importance.high,
  );

  static bool _ensured = false;

  /// Creates both channels, or renames them in place (Android keeps the
  /// user's importance and sound choices). Retried until it succeeds once per
  /// isolate; never throws.
  static Future<void> ensure(FlutterLocalNotificationsPlugin plugin) async {
    if (_ensured) return;
    try {
      final android = plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android == null) return;
      await android.createNotificationChannel(messages);
      await android.createNotificationChannel(reminders);
      _ensured = true;
    } catch (_) {
      // The channel is also created with these names by the first show().
    }
  }
}

/// Title and body of one message notification.
class MessageNotificationText {
  final String title;
  final String body;

  /// Sender and preview are shown (MessagingStyle); otherwise generic text.
  final bool detailed;
  const MessageNotificationText(this.title, this.body, {this.detailed = false});
}

/// [preview] is null when the content is unavailable on this device
/// (undecryptable, redacted). Previews off keep the fully generic text;
/// [locked] (app lock configured) shows no sender, chat or preview at all.
MessageNotificationText messageNotificationText({
  required bool previews,
  required String? chatName,
  required String? senderName,
  required String? preview,
  required bool group,
  bool test = false,
  bool locked = false,
}) {
  String mark(String title) => test ? '$title (test)' : title;
  if (locked) {
    return MessageNotificationText(
      mark(messagePublicTitle),
      lockedNotificationBody,
    );
  }
  final chat = chatName?.trim().isNotEmpty == true ? chatName!.trim() : null;
  final sender = senderName?.trim().isNotEmpty == true
      ? senderName!.trim()
      : null;
  if (!previews) {
    return MessageNotificationText(
      mark(genericNotificationTitle),
      genericNotificationBody,
    );
  }
  if (preview == null || preview.trim().isEmpty) {
    return MessageNotificationText(
      mark(chat ?? genericNotificationTitle),
      genericNotificationBody,
    );
  }
  if (group) {
    return MessageNotificationText(
      mark(chat ?? sender ?? genericNotificationTitle),
      sender == null ? preview : '$sender: $preview',
      detailed: true,
    );
  }
  return MessageNotificationText(
    mark(sender ?? chat ?? genericNotificationTitle),
    preview,
    detailed: true,
  );
}

/// Whether this device can show the event's content.
bool notificationContentAvailable(Event event) =>
    !event.redacted &&
    event.type != EventTypes.Encrypted &&
    event.messageType != MessageTypes.BadEncrypted;

/// Builds the MessagingStyle, keeping earlier messages of the same chat
/// notification (newest last, bounded, without duplicates).
///
/// Android does not return bitmap icons of an active notification, so earlier
/// senders get theirs back from [knownIcons] (by person key).
MessagingStyleInformation messagingStyle({
  required MessageNotificationText text,
  required String? chatName,
  required bool group,
  required String senderName,
  required String senderKey,
  required DateTime timestamp,
  required String preview,
  AndroidIcon<Object>? senderIcon,
  Map<String, AndroidIcon<Object>> knownIcons = const {},
  MessagingStyleInformation? previous,
  int maxMessages = 6,
}) {
  final sender = Person(name: senderName, key: senderKey, icon: senderIcon);
  final message = Message(preview, timestamp, sender);
  final history = [
    ...?previous?.messages
        ?.where(
          (m) =>
              !(m.text == message.text &&
                  m.timestamp.millisecondsSinceEpoch ==
                      message.timestamp.millisecondsSinceEpoch),
        )
        .map(
          (m) => _withIcon(
            m,
            m.person?.key == senderKey
                ? senderIcon
                : knownIcons[m.person?.key],
          ),
        ),
    message,
  ];
  return MessagingStyleInformation(
    const Person(name: 'You'),
    conversationTitle: group ? (chatName ?? text.title) : null,
    groupConversation: group,
    messages: history.length > maxMessages
        ? history.sublist(history.length - maxMessages)
        : history,
  );
}

/// Person keys of earlier messages whose icon Android did not return.
Set<String> notificationKeysWithoutIcon(MessagingStyleInformation? style) => {
  for (final m in style?.messages ?? const <Message>[])
    if (m.person?.icon == null && m.person?.key != null) m.person!.key!,
};

Message _withIcon(Message message, AndroidIcon<Object>? icon) {
  final person = message.person;
  if (person == null || person.icon != null || icon == null) return message;
  return Message(
    message.text,
    message.timestamp,
    Person(
      bot: person.bot,
      icon: icon,
      important: person.important,
      key: person.key,
      name: person.name,
      uri: person.uri,
    ),
    dataMimeType: message.dataMimeType,
    dataUri: message.dataUri,
  );
}

/// "3 messages in 2 chats" for the group summary.
String notificationSummaryLine(int messages, int chats) =>
    '$messages ${messages == 1 ? 'message' : 'messages'} in '
    '$chats ${chats == 1 ? 'chat' : 'chats'}';

/// Own read position check for a push event, replacing the SDK's
/// `returnNullIfSeen` heuristic.
///
/// Seen when the fully-read marker or one of the account's own read receipts
/// points at this event, or when a locally known read position is strictly
/// newer than the event. An unknown read position never hides a message.
Future<bool> personalNotificationSeen(
  Event event, {
  Future<Event?> Function(String eventId)? lookup,
}) async {
  final room = event.room;
  final positions = <String>{};
  if (room.fullyRead.isNotEmpty) positions.add(room.fullyRead);
  final receipts = room.receiptState;
  for (final timeline in [receipts.global, receipts.mainThread]) {
    if (timeline == null) continue;
    for (final receipt in [
      timeline.latestOwnReceipt,
      timeline.ownPublic,
      timeline.ownPrivate,
    ]) {
      if (receipt != null) positions.add(receipt.eventId);
    }
  }
  if (positions.contains(event.eventId)) return true;
  final find =
      lookup ?? (String id) => room.client.database.getEventById(id, room);
  for (final position in positions) {
    if (!position.startsWith(r'$')) continue;
    Event? marker;
    try {
      marker = await find(position);
    } catch (_) {
      marker = null;
    }
    if (marker != null && marker.originServerTs.isAfter(event.originServerTs)) {
      return true;
    }
  }
  return false;
}

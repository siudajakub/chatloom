// SPDX-License-Identifier: AGPL-3.0-or-later

/// Inline Reply from a message notification (Android RemoteInput).
///
/// The typed text is the user's own message, so sending it is user-initiated
/// (automatic replies stay forbidden). It goes through the same durable,
/// encrypted outbox as the composer ([PersonalClient.sendImmediate]), never
/// straight to the room, and follows the composer's fail-closed rules:
///
/// * no encrypted local store: nothing is sent;
/// * the text is written to the chat's private draft *before* the send and
///   taken out again only after the outbox accepted it, so a rejection, an
///   unconfirmed send or a killed process never loses it;
/// * an encrypted chat whose members need a trust review (the composer's
///   dialog) is not sent from the shade;
/// * with the app lock configured nothing is sent: the text waits in the
///   draft until the app is unlocked (Telegram allows reply without unlocking
///   only when its passcode is off). The Reply action is not even offered
///   then, and the check is repeated here for a lock set later.
///
/// Success removes the chat's notification (Telegram); any other outcome
/// replaces it with a "not sent" notice that opens the chat. The typed text
/// is never logged or put into a notification.
///
/// A merged person has one notification for all its networks; the reply goes
/// where the person's composer would send it ([notificationReplyRoom]). The
/// whole reply is bounded ([sendNotificationReply] `limit`): a reply from a
/// closed app must finish before the app may open the same storage.
library;

import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/immediate_outbox.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/message_notification.dart';
import 'package:chatloom/personal/notification_threads.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/utils/push_helper.dart';
import 'package:chatloom/utils/push_work_policy.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart'
    show
        MergedEvent,
        MergedSendRouter,
        PersonGroup,
        PersonRouting,
        SendTarget,
        SourceEventRef;

/// What happened to a reply typed into a notification.
enum NotificationReplyOutcome {
  /// Accepted by the server through the durable outbox.
  sent,

  /// Possibly sent, not confirmed; the outbox keeps the attempt (same
  /// transaction ID on retry) and the text waits in the draft.
  notConfirmed,

  /// Not sent; the text waits in the draft.
  notSent,

  /// Not sent: the chat's encryption needs a review first (composer rule).
  needsReview,

  /// Not sent: the app lock is configured; the text waits in the draft.
  locked,

  /// Not sent and not kept: the chat or the private store is unavailable.
  unavailable,

  /// Nothing to send.
  empty,
}

const notificationReplyActionLabel = 'Reply';
const notificationReplyInputLabel = 'Message';

/// Body of the notice that replaces the notification (never the typed text).
String? notificationReplyNotice(NotificationReplyOutcome outcome) =>
    switch (outcome) {
      NotificationReplyOutcome.sent || NotificationReplyOutcome.empty => null,
      NotificationReplyOutcome.notConfirmed =>
        'Reply not confirmed. Open the chat to check before sending it again.',
      NotificationReplyOutcome.notSent =>
        'Reply not sent. Tap to retry from your draft.',
      NotificationReplyOutcome.needsReview =>
        'Reply not sent. Open the chat to review who can read it.',
      NotificationReplyOutcome.locked =>
        'Reply not sent. Unlock ChatLoom to send your draft.',
      NotificationReplyOutcome.unavailable =>
        'Reply not sent. Open ChatLoom and try again.',
    };

/// Test seam replacing [PersonalClient.of].
@visibleForTesting
PersonalClient Function(Client client)? debugNotificationReplyPersonalOf;

/// Test seam replacing [replyNeedsTrustReview].
@visibleForTesting
Future<bool> Function(Room room)? debugNotificationReplyNeedsReview;

/// Test seam replacing the bounded catch-up sync before sending.
@visibleForTesting
Future<void> Function(Client client)? debugNotificationReplySync;

/// Test seam: whether the Android group summary is maintained.
@visibleForTesting
bool? debugNotificationReplySummary;

/// Upper bound of a reply handled by the running app (Android's sending state
/// must end even when the network hangs).
const notificationReplyLimit = Duration(seconds: 90);

/// Time kept for the send itself: the catch-up sync never eats into it.
const _sendReserve = Duration(seconds: 6);

/// The room a reply typed into the notification of [room] is sent to.
///
/// A single chat: the chat itself. A merged person: the person composer's
/// router ([MergedSendRouter.resolve]) with the notified incoming message as
/// the most recent event and the person's "Send messages via" choice
/// (`person-prefs:<id>`, FT-03): Automatic answers on the network the person
/// just wrote on, "Always Telegram" (fixed) on that network. Chats that cannot
/// receive the person's messages now (left, or shown by another person) are
/// never picked, as in the merged composer. A target that is gone or not
/// writable falls back to [room].
Room notificationReplyRoom(
  PersonalClient personal,
  Room room, {
  String? eventId,
  DateTime? now,
}) {
  InboxProjection projection;
  PersonGroup? group;
  try {
    projection = InboxProjection(personal);
    group = projection.groupFor(room);
  } catch (_) {
    return room;
  }
  if (group == null) return room;
  try {
    final at = now ?? DateTime.now();
    final routed = MergedSendRouter.resolve(
      group: group,
      now: at,
      recentEvent: MergedEvent<Object?>(
        source: SourceEventRef(
          conversation: personal.ref(room),
          eventId: eventId ?? '',
        ),
        timestamp: at,
        isOutgoing: false,
        value: null,
      ),
      automatic:
          projection.preferencesFor(group.id).routing ==
          PersonRouting.automatic,
      available: {
        for (final source in projection.sourcesOf(group))
          if (source.sendable) source.member,
      },
    );
    final target = personal.client.getRoomById(routed.conversation.roomId);
    if (target == null ||
        target.membership != Membership.join ||
        !target.canSendDefaultMessages) {
      return room;
    }
    return target;
  } catch (_) {
    return room;
  }
}

/// Same rule as the composer's `showTrustUserInRoomDialog`: an encrypted chat
/// with a member whose cross-signing identity is neither verified nor trusted
/// on first use asks before sending. The shade cannot ask, so it does not send.
Future<bool> replyNeedsTrustReview(Room room) async {
  if (!room.encrypted) return false;
  final client = room.client;
  await client.userDeviceKeysLoading;
  final users = await room.requestParticipants().timeout(
    const Duration(seconds: 10),
  );
  return users.any((user) {
    if (user.id == client.userID) return false;
    final masterKey = client.userDeviceKeys[user.id]?.masterKey;
    return masterKey != null &&
        !masterKey.verified &&
        masterKey.trustOnFirstUseSince == null;
  });
}

/// Device lists come with sync. While the app is not in the foreground no sync
/// loop runs (and a notification action's own client has none), so catch up
/// once, bounded, before checking permissions/trust and encrypting. Restart a
/// pending long-poll rather than waiting behind a socket from an old network.
/// A failure still sends to known devices, like the composer while offline.
Future<void> _syncIfIdle(Client client) async {
  if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
    return;
  }
  // Restart instead of joining a long poll that may be minutes old; the
  // caller bounds the wait.
  await client.restartSync(timeout: Duration.zero);
}

/// Sends [input] typed into the notification of [roomId] and updates that
/// notification ([notificationId], the id the user replied on; otherwise the
/// conversation's thread id). [eventId] is the notified message. Everything,
/// including the send, ends within [limit]: a send cut off by it is reported
/// as not confirmed (the outbox keeps the attempt). Never throws.
Future<NotificationReplyOutcome> sendNotificationReply({
  required Client client,
  required String roomId,
  required String? input,
  required FlutterLocalNotificationsPlugin plugin,
  int? notificationId,
  String? eventId,
  Duration limit = notificationReplyLimit,
}) async {
  final budget = PushWorkBudget(limit: limit);
  final text = input ?? '';
  var outcome = NotificationReplyOutcome.unavailable;
  // Unknown lock state shows no chat name on the notice.
  var locked = true;
  Room? room;
  PersonalClient? personal;
  try {
    if (text.trim().isEmpty) {
      outcome = NotificationReplyOutcome.empty;
    } else {
      locked = await budget.wait(personalAppLockConfigured);
      await budget.wait(() async => await client.roomsLoading);
      await budget.wait(() async => await client.accountDataLoading);
      room = client.getRoomById(roomId);
      if (room != null) {
        personal = (debugNotificationReplyPersonalOf ?? PersonalClient.of)(
          client,
        );
        outcome = await _reply(
          personal,
          room,
          text,
          locked: locked,
          eventId: eventId,
          budget: budget,
        );
      }
    }
  } catch (_) {
    outcome = NotificationReplyOutcome.unavailable;
  }
  Logs().i('[Push] notification_reply', outcome.name);
  String? title;
  if (!locked &&
      room != null &&
      AppSettings.personalNotificationPreviews.value) {
    try {
      title = InboxProjection(personal!).displayName(room);
    } catch (_) {
      title = null;
    }
  }
  final thread = room == null || personal == null
      ? NotificationThread(clientName: client.clientName, roomId: roomId)
      : notificationThreadOf(
          client.clientName,
          room,
          InboxProjection(personal),
        );
  await showNotificationReplyResult(
    plugin: plugin,
    id: notificationId ?? thread.id,
    clientName: client.clientName,
    roomId: roomId,
    outcome: outcome,
    title: title,
  );
  return outcome;
}

Future<NotificationReplyOutcome> _reply(
  PersonalClient personal,
  Room notified,
  String text, {
  required bool locked,
  required PushWorkBudget budget,
  String? eventId,
}) async {
  // Fail closed: without the encrypted local store there is neither a draft
  // nor a durable outbox record (throws → unavailable).
  await budget.wait(personal.loadLocal);
  final room = notificationReplyRoom(personal, notified, eventId: eventId);
  final draft = _ReplyDraft.of(personal, room);
  final previous = draft.read();
  final kept = previous.text.trim().isEmpty ? text : '${previous.text}\n$text';
  await budget.wait(() => draft.write(kept));
  // From here on the text is in the draft: no outcome loses it.
  var sending = false;
  try {
    if (locked) return NotificationReplyOutcome.locked;
    // A shade reply can run hours after the last foreground sync. Refresh
    // membership, power levels and device identities before deciding whether
    // sending is allowed. Checking first can reject a send using stale state
    // and leave it in the draft without ever attempting the outbox.
    // The catch-up is optional: skipped or cut short when the send needs
    // the time. A failure still decides on the known state.
    final syncTime = budget.remaining - _sendReserve;
    if (syncTime > Duration.zero) {
      try {
        await (debugNotificationReplySync ?? _syncIfIdle)(room.client).timeout(
          syncTime < const Duration(seconds: 8)
              ? syncTime
              : const Duration(seconds: 8),
        );
      } catch (_) {}
    }
    if (!room.canSendDefaultMessages) return NotificationReplyOutcome.notSent;
    if (await budget.wait(
      () => (debugNotificationReplyNeedsReview ?? replyNeedsTrustReview)(room),
    )) {
      return NotificationReplyOutcome.needsReview;
    }
    sending = true;
    final result = await budget.wait(() => personal.sendImmediate(room, text));
    switch (result.state) {
      case ImmediateSendState.accepted:
        // Composer order: restore the draft, then retire the attempt. If the
        // draft cannot be restored the attempt stays accepted, so sending the
        // same text again from that draft returns the accepted attempt
        // instead of a second message.
        try {
          if (draft.read().text == kept) {
            await draft.write(previous.text, previous.target);
          }
          await personal.completeImmediate(result.actionId);
        } catch (_) {}
        return NotificationReplyOutcome.sent;
      case ImmediateSendState.unknown:
        return NotificationReplyOutcome.notConfirmed;
      case ImmediateSendState.failed:
        return NotificationReplyOutcome.notSent;
    }
  } on TimeoutException {
    // Cut off while sending: the attempt may have reached the server.
    return sending
        ? NotificationReplyOutcome.notConfirmed
        : NotificationReplyOutcome.notSent;
  } catch (_) {
    return NotificationReplyOutcome.notSent;
  }
}

/// The private draft a reply waits in: the chat's own, or the merged person's
/// draft when it is empty or already aimed at this chat (a person draft has a
/// single send source, so another network's draft is never retargeted).
class _ReplyDraft {
  final PersonalClient personal;
  final String key;
  final SendTarget target;
  const _ReplyDraft(this.personal, this.key, this.target);

  factory _ReplyDraft.of(PersonalClient personal, Room room) {
    final target = SendTarget(conversation: personal.ref(room));
    final group = InboxProjection(personal).groupFor(room);
    if (group != null) {
      final key = 'draft:person:${group.id}';
      final current = _ReplyDraft(personal, key, target).read();
      if (current.text.trim().isEmpty ||
          current.target?.conversation == target.conversation) {
        return _ReplyDraft(personal, key, target);
      }
    }
    return _ReplyDraft(personal, 'draft:${room.id}', target);
  }

  ({String text, SendTarget? target}) read() {
    final value = personal.values[key];
    final text = value?['text'];
    SendTarget? target;
    final json = value?['target'];
    if (json is Map) {
      try {
        target = SendTarget.fromJson(Map<String, dynamic>.from(json));
      } catch (_) {
        target = null;
      }
    }
    return (text: text is String ? text : '', target: target);
  }

  Future<void> write(String text, [SendTarget? target]) =>
      personal.savePersonalDraft(key, target ?? this.target, text);
}

/// Removes the replied notification, or replaces it (same id, so Android's
/// sending spinner ends) with the notice for [outcome]. Never throws.
Future<void> showNotificationReplyResult({
  required FlutterLocalNotificationsPlugin plugin,
  required int id,
  required NotificationReplyOutcome outcome,
  String? clientName,
  String? roomId,
  String? title,
}) async {
  final notice = notificationReplyNotice(outcome);
  try {
    if (notice == null) {
      await plugin.cancel(id: id);
      if (clientName != null &&
          (debugNotificationReplySummary ?? PlatformInfos.isAndroid)) {
        await updateSummaryNotification(
          flutterLocalNotificationsPlugin: plugin,
          clientName: clientName,
        );
      }
      return;
    }
    await PersonalNotificationChannels.ensure(plugin);
    await plugin.show(
      id: id,
      title: title?.trim().isNotEmpty == true
          ? title!.trim()
          : genericNotificationTitle,
      body: notice,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          PersonalNotificationChannels.messagesId,
          PersonalNotificationChannels.messagesName,
          channelDescription: PersonalNotificationChannels.messagesDescription,
          importance: Importance.high,
          priority: Priority.high,
          sound: PersonalNotificationChannels.messageSound,
          vibrationPattern: PersonalNotificationChannels.messageVibration,
          visibility: NotificationVisibility.private,
          category: AndroidNotificationCategory.error,
          groupKey: clientName,
          // Replacing the notification the user just replied to does not
          // ring again.
          onlyAlertOnce: true,
        ),
      ),
      payload: roomId == null
          ? null
          : ChatLoomPushPayload(clientName, roomId, null).toString(),
    );
  } catch (_) {
    Logs().w('[Push] notification_reply_notice_failed');
  }
}

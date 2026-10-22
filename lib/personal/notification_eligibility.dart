// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/own_sender.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

/// The same private notification exceptions apply in foreground and background.
/// A parent is read only from the existing encrypted local database. Missing
/// history/keys never triggers a network lookup or changes read state.
Future<bool> personalNotificationEligible(
  Event event,
  ConversationMetadata metadata, {
  PersonalNotificationMode? notificationMode,
}) async {
  if (metadata.ignored || metadata.placement == ChatPlacement.ignored) {
    return false;
  }
  final mode =
      notificationMode ??
      (metadata.ignored || metadata.placement == ChatPlacement.ignored
          ? PersonalNotificationMode.muted
          : metadata.notificationMode == PersonalNotificationMode.muted
          ? PersonalNotificationMode.muted
          // An active (timed) mute outranks an explicit chat mode.
          : metadata.muted
          ? PersonalNotificationMode.mentionsOnly
          : metadata.notificationMode ??
                (metadata.lowPriority
                    ? PersonalNotificationMode.mentionsOnly
                    : PersonalNotificationMode.all));
  if (mode == PersonalNotificationMode.muted) return false;
  // Own messages sent from a native app arrive as the owner's bridge ghost.
  // Only account/receiver evidence may suppress an alert (or a mention):
  // weaker DM-structure or name evidence never hides a contact's message.
  if (OwnSenderResolver.of(event.room.client).isStronglyOwnEvent(event)) {
    return false;
  }
  if (mode == PersonalNotificationMode.all) return true;
  final room = event.room;
  final client = room.client;
  final account = client.userID;
  final device = client.deviceID;
  if (account == null) return false;
  final mentions = event.content['m.mentions'];
  final users = mentions is Map ? mentions['user_ids'] : null;
  if (users is List && users.contains(account)) return true;
  final relation = event.content['m.relates_to'];
  if (relation is! Map || relation['rel_type'] != RelationshipTypes.thread) {
    return false;
  }
  final root = relation['event_id'];
  final reply = relation['m.in_reply_to'];
  final parentId = reply is Map ? reply['event_id'] : null;
  if (root is! String ||
      !root.startsWith(r'$') ||
      parentId is! String ||
      !parentId.startsWith(r'$') ||
      event.senderId == account ||
      event.redacted ||
      !event.status.isSynced ||
      !{EventTypes.Message, EventTypes.Sticker}.contains(event.type)) {
    return false;
  }
  Event? parent;
  try {
    parent = await client.database.getEventById(parentId, room);
  } catch (_) {
    return false;
  }
  return client.userID == account &&
      client.deviceID == device &&
      parent != null &&
      identical(parent.room, room) &&
      identical(parent.room.client, client) &&
      parent.eventId == parentId &&
      parent.senderId == account &&
      parent.status.isSynced &&
      {EventTypes.Message, EventTypes.Sticker}.contains(parent.type);
}

/// How long after the user wrote in a bot or service chat its replies still
/// alert like a person's message.
const serviceReplyWindow = Duration(minutes: 10);

/// Bridge bots and other service chats notify quietly: in the shade, without
/// sound or pop-up (bridges/BR-10). Their messages are status, not a person
/// writing. The exception is a reply the user waits for: they wrote in that
/// chat within [serviceReplyWindow] (a sign-in, a command).
bool personalNotificationQuiet({
  required bool technical,
  required bool fromService,
  required DateTime now,
  DateTime? lastOwnMessage,
}) {
  if (!technical && !fromService) return false;
  if (lastOwnMessage == null) return true;
  final age = now.difference(lastOwnMessage);
  // A clock ahead of this device's counts as recent.
  return !age.isNegative && age > serviceReplyWindow;
}

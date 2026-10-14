// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

/// The same private notification exceptions apply in foreground and background.
/// A parent is read only from the existing encrypted local database. Missing
/// history/keys never triggers a network lookup or changes read state.
Future<bool> personalNotificationEligible(
  Event event,
  ConversationMetadata metadata,
) async {
  if (!metadata.muted && !metadata.lowPriority) return true;
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

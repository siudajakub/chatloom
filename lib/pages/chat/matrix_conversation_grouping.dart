// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';
import 'conversation_grouping.dart';

ConversationGroupingItem conversationGroupingItem(
  Event event, {
  bool boundary = false,
}) {
  final relation = event.content.tryGetMap<String, Object?>('m.relates_to');
  return ConversationGroupingItem(
    accountId: event.room.client.userID ?? '',
    sourceId: event.room.id,
    senderId: event.senderId,
    outgoing: event.senderId == event.room.client.userID,
    timestamp: event.originServerTs,
    threadId: relation?['rel_type'] == 'm.thread'
        ? relation?.tryGet<String>('event_id')
        : null,
    deliveryState: event.status.isSent ? 'sent' : event.status.name,
    boundary:
        boundary || event.redacted || !_groupedEventTypes.contains(event.type),
    startsSeries: event.inReplyToEventId(includingFallback: false) != null,
  );
}

// Undecryptable messages (still m.room.encrypted) group with the sender's
// other messages; a redacted one is a boundary like any redaction.
const _groupedEventTypes = {
  EventTypes.Message,
  EventTypes.Sticker,
  EventTypes.Encrypted,
  PollEventContent.startType,
};

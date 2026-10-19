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

const _plainMessageTypes = {
  MessageTypes.Text,
  MessageTypes.Notice,
  MessageTypes.Emote,
};

// Undecryptable messages (still m.room.encrypted) group with the sender's
// other messages; a redacted one is a boundary like any redaction.
const _groupedEventTypes = {
  EventTypes.Message,
  EventTypes.Sticker,
  EventTypes.Encrypted,
  PollEventContent.startType,
};

// Compiled once: this runs for every visible row on every timeline build.
final _interactiveLinkPattern = RegExp(r'(https?://|matrix:|www\.)');

bool conversationHasInteractiveContent(Event event) =>
    !_plainMessageTypes.contains(event.messageType) ||
    event.isRichMessage ||
    _interactiveLinkPattern.hasMatch(event.body) ||
    event.inReplyToEventId(includingFallback: false) != null;

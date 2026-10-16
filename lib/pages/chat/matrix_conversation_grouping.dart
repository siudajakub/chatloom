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
        boundary ||
        event.redacted ||
        !{
          EventTypes.Message,
          EventTypes.Sticker,
          PollEventContent.startType,
        }.contains(event.type),
  );
}

bool conversationHasInteractiveContent(Event event) =>
    !{
      MessageTypes.Text,
      MessageTypes.Notice,
      MessageTypes.Emote,
    }.contains(event.messageType) ||
    event.isRichMessage ||
    RegExp(r'(https?://|matrix:|www\.)').hasMatch(event.body) ||
    event.inReplyToEventId(includingFallback: false) != null;

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

class RoundEventView {
  final SourceEventRef source;
  final RoundVideoDescriptor? descriptor;
  final RoundMediaPolicy policy;
  final String? replyEventId, threadEventId;
  final bool redacted, undecrypted;
  const RoundEventView({
    required this.source,
    required this.descriptor,
    required this.policy,
    this.replyEventId,
    this.threadEventId,
    required this.redacted,
    required this.undecrypted,
  });
  bool get isRound => descriptor != null;
  bool get canPlay => isRound && !redacted && !undecrypted && policy.canPlay;
  @override
  String toString() => 'RoundEventView(redacted)';
}

abstract final class RoundEventAdapter {
  static RoundEventView fromEvent(Event event, {required String accountId}) {
    final content = Map<String, dynamic>.from(event.content);
    final relation = content['m.relates_to'];
    final reply = relation is Map ? relation['m.in_reply_to'] : null;
    final undecrypted = event.type == EventTypes.Encrypted;
    return RoundEventView(
      source: SourceEventRef(
        conversation: ConversationRef(
          accountId: accountId,
          roomId: event.room.id,
          network: 'telegram',
        ),
        eventId: event.eventId,
      ),
      descriptor: undecrypted
          ? null
          : RoundVideoDescriptor.fromContent(content, redacted: event.redacted),
      policy: RoundMediaPolicy.fromContent(content),
      replyEventId: reply is Map && reply['event_id'] is String
          ? reply['event_id'] as String
          : null,
      threadEventId:
          relation is Map &&
              relation['rel_type'] == 'm.thread' &&
              relation['event_id'] is String
          ? relation['event_id'] as String
          : null,
      redacted: event.redacted,
      undecrypted: undecrypted,
    );
  }
}

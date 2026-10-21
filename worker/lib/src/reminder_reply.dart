// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';
import 'ports.dart';

abstract class ReminderReplyHistory {
  List<Event> get events;
  bool get canRequestHistory;
  bool get hasGaps;
  String get progressToken;
  Future<void> requestHistory();
  void requestKeys();
}

/// A real reply from the other party after the reminder was set: a synced
/// message or sticker that is not the owner's, not a bot's or bridge notice,
/// not an edit, reaction or redaction.
///
/// [isOwnSender] additionally recognises the owner's bridge ghosts (messages
/// sent from the native Telegram/WhatsApp/Signal app without double
/// puppeting); they are never the recipient's reply. See personal_core
/// `OwnRemoteIdentity`. [isBot] recognises automated senders (the room's
/// declared bridge bots); their messages are status notices, not replies.
bool isRecipientReply(
  Event event,
  String ownUserId,
  DateTime since, {
  bool Function(String senderId)? isOwnSender,
  bool Function(String senderId)? isBot,
}) =>
    event.status.isSynced &&
    (event.type == EventTypes.Message || event.type == EventTypes.Sticker) &&
    !_ignoredSender(event.senderId, ownUserId, isOwnSender, isBot) &&
    event.originServerTs.isAfter(since) &&
    !event.redacted &&
    !_notReply(event) &&
    // m.notice is the automated message type (bots, bridge status texts).
    event.content['msgtype'] != MessageTypes.Notice;

/// Edits and reactions never answer anything. Encrypted events keep their
/// `m.relates_to` in clear, so this also holds while keys are missing.
bool _notReply(Event event) => {
  RelationshipTypes.edit,
  RelationshipTypes.reaction,
}.contains(event.relationshipType);

/// Owner (account or own ghost) or an automated sender.
bool _ignoredSender(
  String senderId,
  String ownUserId,
  bool Function(String senderId)? isOwnSender,
  bool Function(String senderId)? isBot,
) =>
    senderId == ownUserId ||
    (isOwnSender?.call(senderId) ?? false) ||
    (isBot?.call(senderId) ?? false);

/// False is returned only after a continuous history frontier is proved.
/// Missing pages or recipient keys remain unresolved rather than "no reply".
Future<bool> receivedReplySince(
  ReminderReplyHistory history,
  String ownUserId,
  DateTime since, {
  Duration timeout = const Duration(seconds: 10),
  bool Function(String senderId)? isOwnSender,
  bool Function(String senderId)? isBot,
}) async {
  final deadline = DateTime.now().add(timeout);
  var stagnantRequests = 0;
  while (true) {
    final events = List<Event>.from(history.events);
    if (events.any(
      (event) => isRecipientReply(
        event,
        ownUserId,
        since,
        isOwnSender: isOwnSender,
        isBot: isBot,
      ),
    )) {
      return true;
    }
    if (events.any(
      (event) =>
          event.status.isSynced &&
          event.type == EventTypes.Encrypted &&
          !_ignoredSender(event.senderId, ownUserId, isOwnSender, isBot) &&
          event.originServerTs.isAfter(since) &&
          !event.redacted &&
          !_notReply(event),
    )) {
      history.requestKeys();
      throw const WorkerFailure('waiting_keys');
    }
    final synced = events.where((event) => event.status.isSynced).toList();
    final reached = synced.any(
      (event) =>
          !event.originServerTs.isAfter(since) ||
          event.type == EventTypes.RoomCreate,
    );
    if (reached && !history.hasGaps) return false;
    if (!history.canRequestHistory || DateTime.now().isAfter(deadline)) {
      throw const WorkerFailure('history_unavailable');
    }
    final beforeIds = events.map((event) => event.eventId).toSet();
    final beforeToken = history.progressToken;
    try {
      await history.requestHistory().timeout(
        deadline.difference(DateTime.now()),
      );
    } catch (_) {
      throw const WorkerFailure('history_unavailable');
    }
    if (history.progressToken == beforeToken &&
        history.events.every((event) => beforeIds.contains(event.eventId))) {
      // SDK pagination can first exhaust its database without adding events;
      // the following request then reaches the server. Permit that transition,
      // while bounding truly stalled history rather than claiming absence.
      stagnantRequests++;
      if (stagnantRequests >= 2) {
        throw const WorkerFailure('history_unavailable');
      }
    } else {
      stagnantRequests = 0;
    }
  }
}

class SdkReminderReplyHistory implements ReminderReplyHistory {
  final Timeline timeline;
  SdkReminderReplyHistory(this.timeline);
  @override
  List<Event> get events => timeline.events;
  @override
  bool get canRequestHistory => timeline.canRequestHistory;
  @override
  bool get hasGaps => timeline.isFragmentedTimeline;
  @override
  String get progressToken =>
      '${timeline.chunk.prevBatch}:${timeline.room.prev_batch}';
  @override
  Future<void> requestHistory() => timeline.requestHistory();
  @override
  void requestKeys() => timeline.requestKeys(onlineKeyBackupOnly: false);
}

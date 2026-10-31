// SPDX-License-Identifier: AGPL-3.0-or-later

/// How a deleted (redacted) message reads, wherever ChatLoom draws one: the
/// timeline placeholder, inbox preview, reply quote, pinned bar, bookmarks
/// and the SDK's fallback text (`MatrixLocals.removedBy`).
///
/// Stable API:
/// ```dart
/// isDeletedForDisplay(event); // redacted, or being deleted here right now
/// deletionOf(event);          // (kind: DeletedKind.own, by: null)
/// deletedLabel(event);        // "You deleted this message", ...
/// deletedDisplayCopy(event);  // a redacted stand-in while a delete runs
/// ```
///
/// Rules (J, 2026-10-31):
/// - "Message disappeared": the redaction's reason is "Message disappeared"
///   (bridgev2 disappearing timers) or a bridge bot removed view-limited
///   media (`com.beeper.view_limited`, `bridgev2/viewlimited.go`).
/// - "You deleted this message": the redaction came from this account or
///   one of its own bridge ghosts ([OwnSenderResolver]), or the user is
///   deleting it here ([MessageDeletions]).
/// - "Deleted by {name}": only when a real person other than the author
///   (never a bridge bot, never the author's other identity) removed it, as
///   a WhatsApp group admin does. Bridges usually redact as the author's own
///   ghost, so naming the redactor otherwise would only repeat the author.
/// - "Message deleted" in every other case.
///
/// `com.beeper.dont_render_redacted_placeholder` (sent by the Telegram
/// bridge) is deliberately ignored: J wants to see deletions. "Hide deleted
/// messages" in Settings → Chats is the only switch that hides them.
library;

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/l10n/l10n_en.dart';
import 'package:chatloom/pages/chat/message_deletion.dart';
import 'package:chatloom/personal/hidden_messages.dart';
import 'package:chatloom/personal/message_delivery.dart' show bridgeBotsOf;
import 'package:chatloom/personal/own_sender.dart';
import 'package:matrix/matrix.dart';

/// Who removed a message, in the words the user sees.
enum DeletedKind {
  /// "Message deleted"
  other,

  /// "You deleted this message"
  own,

  /// "Message disappeared"
  disappeared,

  /// "Deleted by {name}" (an admin removed somebody else's message)
  byOther,
}

typedef DeletionInfo = ({DeletedKind kind, String? by});

/// Reason bridgev2 gives the redaction of a disappeared message.
const disappearedRedactionReason = 'Message disappeared';

/// Content flag of the bridge bot's redaction of view-limited media.
const viewLimitedRedactionKey = 'com.beeper.view_limited';

/// English words for callers without a [BuildContext] (notifications,
/// previews outside the widget tree, tests). The app ships English only.
final L10n englishL10n = L10nEn();

/// Whether [event] draws as deleted: redacted, or deleted by the user here
/// and waiting for the server's redaction.
bool isDeletedForDisplay(Event event) =>
    event.redacted || MessageDeletions.deleting(event);

/// Whether a bridge bot of [room] sent as [userId] (never a person).
bool isBridgeBotSender(Room room, String userId) =>
    bridgeBotsOf(room).contains(userId) ||
    room
            .getState(EventTypes.RoomMember, userId)
            ?.content['com.beeper.bridge.is_bridge_bot'] ==
        true;

/// Whether [redaction] removed a disappearing or view-limited message.
bool isDisappearingRedaction(Event redaction) {
  final reason = redaction.content['reason'];
  if (reason is String &&
      reason.trim().toLowerCase() == disappearedRedactionReason.toLowerCase()) {
    return true;
  }
  return redaction.content[viewLimitedRedactionKey] == true &&
      isBridgeBotSender(redaction.room, redaction.senderId);
}

/// Who deleted [event]. An event that is not redacted yet is being deleted
/// by the user here ([MessageDeletions.deleting]).
DeletionInfo deletionOf(Event event) {
  final redaction = event.redactedBecause;
  if (redaction == null) return (kind: DeletedKind.own, by: null);
  return deletionOfRedaction(redaction, authorId: event.senderId);
}

/// Who deleted a message, from its [redaction] alone. Without [authorId]
/// (the SDK's `removedBy` only gets the redaction) nobody is named.
DeletionInfo deletionOfRedaction(Event redaction, {String? authorId}) {
  if (isDisappearingRedaction(redaction)) {
    return (kind: DeletedKind.disappeared, by: null);
  }
  final room = redaction.room;
  final redactor = redaction.senderId;
  if (OwnSenderResolver.of(
    room.client,
  ).isOwnSender(redactor, roomId: room.id)) {
    return (kind: DeletedKind.own, by: null);
  }
  if (authorId != null &&
      redactor != authorId &&
      !isBridgeBotSender(room, redactor)) {
    final name = room
        .unsafeGetUserFromMemoryOrFallback(redactor)
        .calcDisplayname();
    final author = room
        .unsafeGetUserFromMemoryOrFallback(authorId)
        .calcDisplayname();
    // The author's other identity (a puppet and its ghost) is no admin.
    if (name.trim().isNotEmpty && name != author) {
      return (kind: DeletedKind.byOther, by: name);
    }
  }
  return (kind: DeletedKind.other, by: null);
}

/// The words for [info].
String deletionText(DeletionInfo info, L10n l10n) => switch (info.kind) {
  DeletedKind.own => l10n.youDeletedThisMessage,
  DeletedKind.disappeared => l10n.messageDisappeared,
  DeletedKind.byOther => l10n.deletedByUser(info.by ?? l10n.user),
  DeletedKind.other => l10n.messageDeleted,
};

/// "Message deleted", "You deleted this message", "Message disappeared" or
/// "Deleted by {name}" for a deleted [event].
String deletedLabel(Event event, {L10n? l10n}) =>
    deletionText(deletionOf(event), l10n ?? englishL10n);

final _copies = Expando<Event>('deleting copy');

/// [event] as it draws: a redacted stand-in while the user's delete is on
/// its way (so every check of `redacted` agrees with the placeholder),
/// otherwise [event] itself. One copy per event object.
Event deletedDisplayCopy(Event event) {
  if (event.redacted || !MessageDeletions.deleting(event)) return event;
  final cached = _copies[event];
  if (cached != null) return cached;
  final txid = event.transactionId;
  final redaction = Event(
    type: EventTypes.Redaction,
    content: {'redacts': event.eventId},
    eventId: '${event.eventId}#deleting',
    senderId: event.room.client.userID ?? event.senderId,
    originServerTs: DateTime.now(),
    room: event.room,
    redacts: event.eventId,
  );
  // A fresh, empty content map: `setRedactionEvent` would strip a content
  // map shared with the original. Built as synced, because the constructor
  // marks an old *sending* event failed (in the database, too); the real
  // status is copied afterwards.
  final copy = Event(
    content: <String, dynamic>{},
    type: event.type,
    eventId: event.eventId,
    senderId: event.senderId,
    originServerTs: event.originServerTs,
    room: event.room,
    unsigned: {'redacted_because': redaction.toJson(), 'transaction_id': ?txid},
  )..status = event.status;
  return _copies[event] = copy;
}

/// The newest message of [newestFirst] (a room's stored timeline) an inbox
/// row can show instead of its deleted newest message [deletedId], or null.
Event? previousPreviewEvent(
  Iterable<Event> newestFirst, {
  required String deletedId,
  required Set<String> previewTypes,
}) {
  for (final event in newestFirst) {
    if (event.eventId == deletedId) continue;
    if (!previewTypes.contains(event.type)) continue;
    if (event.type == EventTypes.Redaction ||
        event.type == EventTypes.Reaction) {
      continue;
    }
    final relation = event.relationshipType;
    if (relation == RelationshipTypes.edit ||
        relation == RelationshipTypes.reaction ||
        relation == RelationshipTypes.thread) {
      continue;
    }
    if (isDeletedForDisplay(event) || HiddenMessages.hides(event)) continue;
    if (event.status.isError) continue;
    return event;
  }
  return null;
}

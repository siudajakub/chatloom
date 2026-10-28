// SPDX-License-Identifier: AGPL-3.0-or-later

/// Where an explicit "Mark as read" points, and the one way to send it.
///
/// `Room.lastEvent` is the chat preview: after the user's own pending or
/// failed message it is a local echo with a transaction id, and a chat with
/// no preview has none. Every manual read action (the incognito read button,
/// "Mark all sources as read", the notification action) therefore marks the
/// newest *server* event of each source it knows: from the page's loaded
/// timeline, then the preview. A source with nothing to mark is skipped, not
/// a failure (code-client CC-12).
library;

import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';
import 'package:matrix/matrix.dart';

/// The newest event of [room] a read marker may point at: a sent or synced
/// event with a server id, from [loaded] (any order) or the room preview.
/// [notAfter] skips newer events (the notification only showed up to there).
Event? conversationReadTarget(
  Room room, {
  Iterable<Event> loaded = const [],
  DateTime? notAfter,
}) {
  Event? best;
  for (final event in [...loaded, ?room.lastEvent]) {
    if (event.room.id != room.id ||
        !event.eventId.startsWith(r'$') ||
        !event.status.isSent) {
      continue;
    }
    if (notAfter != null && event.originServerTs.isAfter(notAfter)) continue;
    if (best == null || event.originServerTs.isAfter(best.originServerTs)) {
      best = event;
    }
  }
  return best;
}

/// Freezes one target per room of [rooms] that has something to mark.
List<(Room, String)> conversationReadTargets(
  Iterable<Room> rooms, {
  Iterable<Event> Function(Room room)? loaded,
  DateTime? notAfter,
}) => [
  for (final room in rooms)
    if (conversationReadTarget(
          room,
          loaded: loaded?.call(room) ?? const [],
          notAfter: notAfter,
        )
        case final Event event)
      (room, event.eventId),
];

/// Events from someone else that make a conversation unread: what the chat
/// list previews and the timeline shows. Bridge delivery reports
/// (`com.beeper.message_send_status`), reactions, edits, redactions, state
/// and other hidden events never do.
const _unreadTypes = {
  EventTypes.Message,
  EventTypes.Encrypted,
  EventTypes.Sticker,
  EventTypes.CallInvite,
  PollEventContent.startType,
};

/// The user's own events that read everything before them (Matrix treats
/// the sender's own event as read; bridges echo messages the user wrote in
/// the network's app as the user's own, double puppeted).
const _ownActivityTypes = {
  ..._unreadTypes,
  EventTypes.Reaction,
  PollEventContent.responseType,
};

/// Whether any source of the conversation is actually unread
/// ([conversationSourceUnread]); the incognito read button shows only then.
bool conversationNeedsPublicRead(
  Iterable<Room> rooms, {
  Iterable<Event> Function(Room room)? loaded,
}) => rooms.any(
  (room) =>
      conversationSourceUnread(room, loaded: loaded?.call(room) ?? const []),
);

/// Whether [room] holds a message from someone else newer than everything
/// that already counts as read there: the user's own message, sticker or
/// reaction (also while it is still sending, so the button goes at once),
/// the account's public or private read receipt, the fully read marker, or
/// a read marked on this device ([PersonalPrivacy.readCutoff]).
///
/// Events come from [loaded] (any order) and the room preview. A failed own
/// send reads nothing. A receipt whose event is not loaded is compared by
/// its timestamp, as the SDK's `hasNewMessages` does.
bool conversationSourceUnread(Room room, {Iterable<Event> loaded = const []}) {
  final own = room.client.userID;
  final events = <String, Event>{};
  for (final event in [...loaded, ?room.lastEvent]) {
    if (event.room.id != room.id || event.status.isError) continue;
    events.putIfAbsent(event.eventId, () => event);
  }
  // A pending own echo is newer than every server event, whatever its
  // local clock says.
  int position(Event event) => event.status.isSending
      ? 8640000000000000 // DateTime's maximum.
      : event.originServerTs.millisecondsSinceEpoch;

  Event? newest;
  for (final event in events.values) {
    if (event.senderId == own ||
        !event.eventId.startsWith(r'$') ||
        !event.status.isSent ||
        !_unreadTypes.contains(event.type) ||
        !event.isVisibleInGui) {
      continue;
    }
    if (newest == null || position(event) > position(newest)) newest = event;
  }
  if (newest == null) return false;
  final unread = newest;
  final cutoff = position(unread);

  bool readsPast(String? eventId) {
    if (eventId == null) return false;
    if (eventId == unread.eventId) return true;
    final event = events[eventId];
    return event != null && position(event) >= cutoff;
  }

  if (events.values.any(
    (event) =>
        event.senderId == own &&
        _ownActivityTypes.contains(event.type) &&
        position(event) >= cutoff,
  )) {
    return false;
  }
  if (readsPast(room.fullyRead) ||
      readsPast(PersonalPrivacy.readCutoff(room))) {
    return false;
  }
  final receipts = room.receiptState;
  for (final timeline in [receipts.global, ?receipts.mainThread]) {
    for (final receipt in [timeline.ownPublic, timeline.ownPrivate]) {
      if (receipt == null) continue;
      if (events.containsKey(receipt.eventId)
          ? readsPast(receipt.eventId)
          : receipt.ts >= unread.originServerTs.millisecondsSinceEpoch) {
        return false;
      }
    }
  }
  return true;
}

/// Sends one manual read marker per target, all sources in parallel, and
/// returns how many failed. [publicReceipt] makes the receipt public even
/// when public receipts are off (the incognito read button's explicit
/// choice); [privateReceipt] keeps it private even when they are on (the
/// incognito notification action, CS-32); otherwise the receipt follows the
/// user's receipt setting.
Future<int> markConversationRead(
  List<(Room, String)> targets, {
  bool publicReceipt = false,
  bool privateReceipt = false,
}) async {
  var failed = 0;
  await Future.wait(
    targets.map((target) async {
      final (room, eventId) = target;
      try {
        if (room.client.baseUri == null) {
          throw StateError('Read target unavailable');
        }
        await PersonalPrivacy.markRead(
          room,
          eventId,
          manual: true,
          publicReceipt: publicReceipt,
          privateReceipt: privateReceipt,
        );
      } catch (_) {
        failed++;
      }
    }),
  );
  return failed;
}

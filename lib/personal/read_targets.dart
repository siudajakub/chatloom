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

/// Whether any source has a newest message from someone else that the
/// account's public read receipt does not point at yet. A newest own message
/// implies everything before it was read, so nothing is left to mark.
bool conversationNeedsPublicRead(
  Iterable<Room> rooms, {
  Iterable<Event> Function(Room room)? loaded,
}) {
  for (final room in rooms) {
    final target = conversationReadTarget(
      room,
      loaded: loaded?.call(room) ?? const [],
    );
    if (target == null || target.senderId == room.client.userID) continue;
    // Marked read here already (a manual read or an accepted reaction).
    if (PersonalPrivacy.readCutoff(room) == target.eventId) continue;
    if (room.receiptState.global.ownPublic?.eventId != target.eventId) {
      return true;
    }
  }
  return false;
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

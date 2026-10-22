// SPDX-License-Identifier: AGPL-3.0-or-later

/// One system notification per conversation (wave 5, FT-04 and CC-22).
///
/// A merged person is one conversation in ChatLoom, so all of its source
/// rooms share one notification: one id, one MessagingStyle history, one
/// Darwin thread. Rooms outside a valid merge keep their own notification.
///
/// Every cancel path removes a conversation by [notificationIdsForRooms]:
/// the per-room ids plus the person id of every saved merge that lists one
/// of the rooms (valid or not), so a notification posted before a merge, by
/// an older build, or while the merge looked different is removed too.
///
/// Showing a message is a read-modify-write of the active notification
/// (read its history, append, show). [NotificationThreads.serialize] runs
/// those steps one push at a time per notification, so pushes handled
/// together never drop or reorder lines; [NotificationThreads.newest] keeps
/// the tap target and time on the newest message when an older push is
/// handled last.
library;

import 'dart:async';

import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/utils/notification_client_routing.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart' show PersonGroup;

/// Where the messages of one room are shown.
class NotificationThread {
  final String clientName;

  /// The room of the message being shown (the tap and reply payload).
  final String roomId;

  /// The valid person merge [roomId] belongs to; null for a single chat.
  final PersonGroup? group;

  const NotificationThread({
    required this.clientName,
    required this.roomId,
    this.group,
  });

  /// Room id, or the person key for a merged person.
  String get key => group == null ? roomId : personNotificationKey(group!.id);

  /// Notification id ([messageNotificationId] of [key]).
  int get id => messageNotificationId(clientName, key);

  /// iOS/macOS thread of the notification.
  String get threadIdentifier => '${clientName}_$key';

  /// Rooms whose messages this notification can carry.
  Set<String> get roomIds => {
    roomId,
    ...?group?.members.map((member) => member.roomId),
  };

  /// Every id that may show this conversation: [id] and the per-room ids of
  /// [roomIds] (notifications posted before the merge).
  Set<int> get cancelIds => {
    id,
    for (final room in roomIds) messageNotificationId(clientName, room),
  };
}

/// The thread of [room]'s messages under [projection] (its valid merges).
NotificationThread notificationThreadOf(
  String clientName,
  Room room,
  InboxProjection? projection,
) {
  PersonGroup? group;
  try {
    group = projection?.groupFor(room);
  } catch (_) {
    group = null;
  }
  return NotificationThread(
    clientName: clientName,
    roomId: room.id,
    group: group,
  );
}

/// Same as [notificationThreadOf] after the private store had a chance to
/// load (notification actions of a cold start). A single-chat thread when
/// the store is unavailable within [timeout].
Future<NotificationThread> loadNotificationThread(
  Client client,
  String roomId, {
  PersonalClient Function(Client client)? personalOf,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final room = client.getRoomById(roomId);
  if (room == null) {
    return NotificationThread(clientName: client.clientName, roomId: roomId);
  }
  try {
    final personal = (personalOf ?? PersonalClient.of)(client);
    await personal.loadLocal().timeout(timeout);
    return notificationThreadOf(
      client.clientName,
      room,
      InboxProjection(personal),
    );
  } catch (_) {
    return NotificationThread(clientName: client.clientName, roomId: roomId);
  }
}

/// Every notification id that may show messages of [roomIds]: their own and
/// the person id of every saved merge (valid or not) that lists one of them.
/// [personal] may be unloaded; then only the per-room ids are returned.
Set<int> notificationIdsForRooms(
  String clientName,
  Iterable<String> roomIds, {
  PersonalClient? personal,
}) {
  final rooms = roomIds.toSet();
  final ids = {
    for (final room in rooms) messageNotificationId(clientName, room),
  };
  if (personal == null || rooms.isEmpty) return ids;
  try {
    for (final group in personal.groups) {
      if (group.members.any((member) => rooms.contains(member.roomId))) {
        ids.add(personNotificationId(clientName, group.id));
      }
    }
  } catch (_) {}
  return ids;
}

/// The newest message a notification shows: its tap target and time.
@immutable
class NotificationNewest {
  final DateTime timestamp;
  final String roomId;
  final String? eventId;
  const NotificationNewest(this.timestamp, this.roomId, this.eventId);
}

abstract final class NotificationThreads {
  static final _tails = <int, Future<void>>{};
  static final _newest = <int, NotificationNewest>{};

  /// Per-isolate memory of [newest]; bounded.
  static const _maxNewest = 64;

  /// Runs [action] after every earlier action for notification [id] in this
  /// isolate has finished (successfully or not). Never deadlocks on a failed
  /// action; each action still has its own time budget.
  static Future<T> serialize<T>(int id, Future<T> Function() action) {
    final previous = _tails[id] ?? Future<void>.value();
    final done = Completer<void>();
    final tail = done.future;
    _tails[id] = tail;
    return previous.then((_) => action()).whenComplete(() {
      done.complete();
      if (identical(_tails[id], tail)) _tails.remove(id);
    });
  }

  /// Records [candidate] as shown in notification [id] and returns the newest
  /// message this isolate showed there (the candidate when it is newer or
  /// the first). Call inside [serialize].
  static NotificationNewest newest(int id, NotificationNewest candidate) {
    final known = _newest[id];
    if (known != null && known.timestamp.isAfter(candidate.timestamp)) {
      return known;
    }
    _newest.remove(id);
    if (_newest.length >= _maxNewest) _newest.remove(_newest.keys.first);
    _newest[id] = candidate;
    return candidate;
  }

  /// The notification [id] was removed: its next message starts fresh.
  static void forget(Iterable<int> ids) {
    for (final id in ids) {
      _newest.remove(id);
    }
  }

  @visibleForTesting
  static void debugReset() {
    _tails.clear();
    _newest.clear();
  }
}

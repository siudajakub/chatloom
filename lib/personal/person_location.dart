// SPDX-License-Identifier: AGPL-3.0-or-later
// Locations of merged person chats. No page imports: also used by the
// notification tap handler.
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

/// Location of a merged person chat. [sourceRoomId] preselects the send
/// source (when no draft owns one); [eventId] scrolls to that source event.
String personChatLocation(
  String groupId, {
  String? sourceRoomId,
  String? eventId,
  String? clientName,
}) {
  final query = <String, String>{
    'client': ?clientName,
    'source': ?sourceRoomId,
    'event': ?eventId,
  };
  return Uri(
    path: '/rooms/person/${Uri.encodeComponent(groupId)}',
    queryParameters: query.isEmpty ? null : query,
  ).toString();
}

/// Location of a member source chat opened from its person chat. It is a
/// child of the person route, so back returns to the merged conversation.
String personSourceChatLocation(
  String groupId,
  String roomId, {
  String? eventId,
}) => Uri(
  path:
      '/rooms/person/${Uri.encodeComponent(groupId)}/${Uri.encodeComponent(roomId)}',
  queryParameters: eventId == null ? null : {'event': eventId},
).toString();

/// The valid person group [room] belongs to, read synchronously from the
/// loaded private store (null before it is loaded or for ungrouped rooms).
PersonGroup? personGroupOf(Room room) {
  try {
    return InboxProjection(PersonalClient.of(room.client)).groupFor(room);
  } catch (_) {
    return null;
  }
}

/// Where a room's conversation opens: its merged person chat when the room
/// belongs to a person group, otherwise the room itself. Used by players and
/// other shortcuts that only know a source event.
String conversationLocation(Room room, {String? eventId}) {
  final group = personGroupOf(room);
  if (group != null) {
    return personChatLocation(
      group.id,
      sourceRoomId: room.id,
      eventId: eventId,
    );
  }
  return Uri(
    path: '/rooms/${room.id}',
    queryParameters: eventId == null ? null : {'event': eventId},
  ).toString();
}

/// Same as [conversationLocation], after the private store had a chance to
/// load (cold notification taps). Falls back to the room on any failure.
Future<String?> personGroupIdForNotification(
  Client client,
  String roomId,
) async {
  final room = client.getRoomById(roomId);
  if (room == null) return null;
  try {
    await PersonalClient.of(
      client,
    ).loadLocal().timeout(const Duration(seconds: 5));
  } catch (_) {
    return null;
  }
  return personGroupOf(room)?.id;
}

/// Base location of the chat page for [roomId] in the current stack. A source
/// chat opened from a person keeps that parent, so details, search and
/// encryption pages return to it instead of dropping the merged route.
String chatLocation(BuildContext context, String roomId) {
  String? path;
  try {
    path = GoRouter.maybeOf(
      context,
    )?.routerDelegate.currentConfiguration.uri.path;
  } catch (_) {
    path = null;
  }
  final match = path == null
      ? null
      : RegExp(r'^/rooms/person/([^/]+)/([^/]+)').firstMatch(path);
  if (match != null && Uri.decodeComponent(match[2]!) == roomId) {
    return '/rooms/person/${match[1]}/${match[2]}';
  }
  return '/rooms/$roomId';
}

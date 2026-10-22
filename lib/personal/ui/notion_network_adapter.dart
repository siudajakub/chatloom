// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:matrix/matrix.dart';

/// Only eligible groups returned by InboxProjection participate; invalid or
/// foreign-account memberships cannot add a displayed network.
Set<String> notionRoomNetworks(InboxProjection projection, Room room) {
  final group = projection.groupFor(room);
  if (group == null) return {projection.classifier.classify(room).network};
  // Only the chats the person shows: a left chat or one shown by another
  // person adds no network.
  return projection
      .activeSourcesOf(group)
      .map((room) => projection.classifier.classify(room).network)
      .toSet();
}

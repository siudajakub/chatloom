// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

/// Source references only. Building a queue never downloads, decrypts media,
/// emits played/read, requests keys or consults a different account/room.
abstract final class RoundPlaybackQueue {
  static List<Event> after(Event source, Iterable<Event> history) {
    Object? thread(Event event) {
      final relation = event.content['m.relates_to'];
      return relation is Map && relation['rel_type'] == RelationshipTypes.thread
          ? relation['event_id']
          : null;
    }

    final candidates =
        history
            .where(
              (event) =>
                  identical(event.room.client, source.room.client) &&
                  event.room.id == source.room.id &&
                  thread(event) == thread(source) &&
                  event.type == EventTypes.Message &&
                  !event.redacted &&
                  event.status.isSent &&
                  event.eventId.startsWith(r'$') &&
                  event.relationshipType != RelationshipTypes.edit &&
                  RoundMediaPolicy.fromContent(event.content).canPersist &&
                  (event.messageType == MessageTypes.Audio ||
                      RoundVideoDescriptor.fromContent(event.content) != null),
            )
            .toList()
          ..sort((a, b) {
            final time = a.originServerTs.compareTo(b.originServerTs);
            return time != 0 ? time : a.eventId.compareTo(b.eventId);
          });
    final sourceIndex = candidates.indexWhere(
      (e) => e.eventId == source.eventId,
    );
    if (sourceIndex < 0) return const [];
    final seen = <String>{source.eventId};
    return List.unmodifiable(
      candidates.skip(sourceIndex + 1).where((e) => seen.add(e.eventId)),
    );
  }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

import 'round_playback_coordinator.dart';

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

/// Outcome of starting one item of a continuation.
enum RoundStartResult {
  /// Audible playback started; the item now owns the rest of the queue.
  started,

  /// This item cannot play (decryption, download, codec, expired): it shows
  /// its own inline state and the continuation moves on to the next item.
  failed,

  /// Superseded (explicit play, lock, background) or gone: stop here.
  aborted,
}

/// A mounted timeline row that can play a continuation in place: it scrolls
/// itself into view and starts audible playback, like Telegram does.
abstract interface class RoundContinuationTarget {
  Future<RoundStartResult> startContinuation(
    List<Event> rest, {
    required RoundContinuationToken token,
    required double speed,
    required bool enlarge,
  });
}

/// Mounted timeline rows by exact source (client instance, room, event).
/// Holds no media, grants no audio and never reads message content.
class RoundContinuationTargets {
  static final shared = RoundContinuationTargets();
  final _targets = <(Client, String, String), RoundContinuationTarget>{};

  static (Client, String, String) _key(Event event) =>
      (event.room.client, event.room.id, event.eventId);

  void register(Event event, RoundContinuationTarget target) =>
      _targets[_key(event)] = target;

  void unregister(Event event, RoundContinuationTarget target) {
    final key = _key(event);
    if (identical(_targets[key], target)) _targets.remove(key);
  }

  RoundContinuationTarget? targetFor(Event event) => _targets[_key(event)];

  int get length => _targets.length;
}

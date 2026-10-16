// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

/// Sort only unseen results; old heartbeat history needs no decoding or sorting.
class JournalReplayBatch {
  final results = <(Event, PersonalOperation)>[];
  (Event, PersonalOperation)? heartbeat;

  JournalReplayBatch(
    Iterable<Event> events, {
    required Set<String> acceptedEventIds,
    required bool Function(Event) trusted,
  }) {
    for (final event in events) {
      if (event.type != personalEventType ||
          event.redacted ||
          acceptedEventIds.contains(event.eventId)) {
        continue;
      }
      final kind = event.content['kind'];
      if (kind is! String ||
          (!kind.endsWith('.result') && kind != 'worker.heartbeat') ||
          !trusted(event)) {
        continue;
      }
      if (kind == 'worker.heartbeat' &&
          heartbeat != null &&
          compare(event, heartbeat!.$1) <= 0) {
        continue;
      }
      PersonalOperation op;
      try {
        op = PersonalOperation.fromJson(event.content);
      } catch (_) {
        continue;
      }
      if (kind == 'worker.heartbeat') {
        heartbeat = (event, op);
      } else {
        results.add((event, op));
      }
    }
    results.sort((a, b) => compare(a.$1, b.$1));
  }

  static int compare(Event a, Event b) {
    final time = a.originServerTs.compareTo(b.originServerTs);
    return time != 0 ? time : a.eventId.compareTo(b.eventId);
  }
}

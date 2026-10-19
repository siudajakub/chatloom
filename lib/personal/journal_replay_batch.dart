// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/personal/journal_trust.dart';
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

  /// How [event] bears on the journal watermark, once every trusted result
  /// among the replayed events has been applied by a batch built with the
  /// same [trust] (one snapshot per pass, so both always agree).
  ///
  /// Only results change client state. A result is held (re-read on every
  /// attach) while it may still be applied later: undecrypted with a chance of
  /// a trusted key, or authenticated up to a device that is not verified now
  /// ([JournalTrust.mayLaterTrust]). Events that can never be trusted (wrong
  /// sender, imported or mismatched session, keys that can no longer arrive)
  /// settle, so they cannot exhaust the held slots. [pendingAlert] holds an
  /// applied due reminder until its alert is claimed, so the alert survives a
  /// restart.
  static JournalSettlement settle(
    Event event, {
    required String? userId,
    required JournalTrust trust,
    required bool Function(Event) pendingAlert,
  }) {
    if (!event.eventId.startsWith(r'$') || !event.status.isSynced) {
      return JournalSettlement.barrier;
    }
    if (event.redacted) return JournalSettlement.settled;
    if (event.type == EventTypes.Encrypted) {
      // Kind unknown: may be a result until proven undecryptable for good.
      return trust.mayLaterTrust(event)
          ? JournalSettlement.held
          : JournalSettlement.settled;
    }
    if (event.type != personalEventType) return JournalSettlement.settled;
    final kind = event.content['kind'];
    if (kind is! String || !kind.endsWith('.result')) {
      // Commands and heartbeats: only the newest heartbeat is ever read, and
      // the resume margin keeps a fresh one loaded.
      return JournalSettlement.settled;
    }
    if (event.senderId != userId ||
        event.originalSource?.type != EventTypes.Encrypted) {
      // Never trusted, whatever devices are verified later.
      return JournalSettlement.settled;
    }
    if (!trust.trusts(event)) {
      return trust.mayLaterTrust(event)
          ? JournalSettlement.held
          : JournalSettlement.settled;
    }
    // Trusted: applied by the batch (or malformed, which stays malformed).
    return pendingAlert(event)
        ? JournalSettlement.held
        : JournalSettlement.settled;
  }
}

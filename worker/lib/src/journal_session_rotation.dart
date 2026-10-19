// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';
import 'ports.dart';

/// The worker's outbound megolm session for one room, as rotation needs it.
abstract interface class OutboundSessionPort {
  /// Creation time of the current outbound session; null when there is none.
  Future<DateTime?> createdAt();

  /// Discards the current outbound session. The next encrypted send creates a
  /// fresh one and shares it over Olm with the devices the share policy
  /// admits at that moment.
  Future<void> discard();
}

/// Why [JournalSessionRotation.rotateIfDue] rotated.
enum JournalRotationReason { startup, maxAge }

/// Rotates the worker's journal outbound megolm session so app devices can
/// trust worker results again soon.
///
/// The journal trusts only events decrypted with a session that its verified
/// sender delivered directly over Olm (see `journal_trust.dart`); a device that
/// got a session only from key backup or forwarding refuses it. A device added
/// or reinstalled after the worker's current session was created therefore
/// cannot apply worker results until the next session, which the SDK would
/// otherwise start only after 100 messages or one week. Rotating once at
/// daemon start and whenever the session is older than [maxAge] bounds that
/// gap. Cheap: one database read per process, then in-memory checks at most
/// once per [checkInterval]. Rotation never touches inbound sessions, so
/// earlier events stay decryptable.
class JournalSessionRotation {
  static const maxAge = Duration(hours: 24);
  static const checkInterval = Duration(minutes: 1);

  JournalSessionRotation(this._session, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final OutboundSessionPort _session;
  final DateTime Function() _clock;
  bool _startupDone = false;
  DateTime? _checkedAt;

  /// Call before every journal publication. Returns why it rotated, or null.
  /// Throws [WorkerFailure] `journal_session_rotation_deferred` when the
  /// session could not be read or discarded; the caller defers publication
  /// and retries on the next cycle.
  Future<JournalRotationReason?> rotateIfDue() async {
    final now = _clock();
    final checkedAt = _checkedAt;
    if (_startupDone && checkedAt != null) {
      final since = now.difference(checkedAt);
      if (!since.isNegative && since < checkInterval) return null;
    }
    try {
      final created = await _session.createdAt();
      JournalRotationReason? reason;
      if (created != null) {
        final age = now.difference(created);
        if (!_startupDone) {
          reason = JournalRotationReason.startup;
        } else if (age.isNegative || age >= maxAge) {
          // A clock stepping backwards must not pin an old session.
          reason = JournalRotationReason.maxAge;
        }
      }
      if (reason != null) await _session.discard();
      _startupDone = true;
      _checkedAt = now;
      return reason;
    } catch (_) {
      throw const WorkerFailure('journal_session_rotation_deferred');
    }
  }
}

/// [OutboundSessionPort] over the Matrix SDK key manager (public API only).
class SdkOutboundSession implements OutboundSessionPort {
  SdkOutboundSession(this.client, this.roomId);

  final Client client;
  final String roomId;

  @override
  Future<DateTime?> createdAt() async {
    final keys = client.encryption?.keyManager;
    if (keys == null) throw const WorkerFailure('journal_unavailable');
    // Loads the stored session once per process, as encryption itself does.
    if (keys.getOutboundGroupSession(roomId)?.isValid != true) {
      await keys.loadOutboundGroupSession(roomId);
    }
    final session = keys.getOutboundGroupSession(roomId);
    return session?.isValid == true ? session!.creationTime : null;
  }

  @override
  Future<void> discard() async {
    final keys = client.encryption?.keyManager;
    if (keys == null) throw const WorkerFailure('journal_unavailable');
    // Removes the session from memory and the database; the next
    // encryptGroupMessagePayload creates and shares a new one.
    await keys.clearOrUseOutboundGroupSession(roomId, wipe: true);
  }
}

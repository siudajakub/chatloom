// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

/// When the daemon writes `worker.heartbeat` to the private journal.
///
/// Every heartbeat is an encrypted journal event which each client decrypts
/// and replays, so it is sparse: a proof of life every [interval], and a
/// prompt update when the reported payload changes, at most once per
/// [minimumSpacing] so a burst of job changes cannot flood the journal.
/// Clients treat a heartbeat as fresh for two intervals plus slack.
class HeartbeatSchedule {
  static const interval = Duration(minutes: 5);
  static const minimumSpacing = Duration(minutes: 1);

  DateTime? _sentAt;
  String? _sentPayload;

  bool due(DateTime now, Map<String, Object?> payload) {
    final sentAt = _sentAt;
    if (sentAt == null) return true;
    final elapsed = now.difference(sentAt);
    // A clock stepping backwards must not silence the worker until it
    // catches up again.
    if (elapsed.isNegative || elapsed >= interval) return true;
    return elapsed >= minimumSpacing && _canonical(payload) != _sentPayload;
  }

  void sent(DateTime at, Map<String, Object?> payload) {
    _sentAt = at;
    _sentPayload = _canonical(payload);
  }

  static String _canonical(Map<String, Object?> payload) => jsonEncode(
    Map.fromEntries(
      payload.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    ),
  );
}

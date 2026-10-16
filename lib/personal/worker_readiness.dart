// SPDX-License-Identifier: AGPL-3.0-or-later

/// Only allowlisted fields of an already authenticated heartbeat are retained.
/// Unknown or older payloads never imply that optional services are ready.
class WorkerReadiness {
  final DateTime receivedAt;
  final bool? healthy;
  final bool? verified;
  final String? transcription;
  final String? reminderPush;
  final int? pending;
  final int? pendingReminderHints;

  const WorkerReadiness({
    required this.receivedAt,
    this.healthy,
    this.verified,
    this.transcription,
    this.reminderPush,
    this.pending,
    this.pendingReminderHints,
  });

  factory WorkerReadiness.fromPayload(
    Map<String, dynamic> payload,
    DateTime at,
  ) {
    int? count(Object? value) =>
        value is int && value >= 0 && value <= 1000000 ? value : null;
    String? allowed(Object? value, Set<String> values) =>
        value is String && values.contains(value) ? value : null;
    return WorkerReadiness(
      receivedAt: at,
      healthy: payload['healthy'] is bool ? payload['healthy'] as bool : null,
      verified: payload['verified'] is bool
          ? payload['verified'] as bool
          : null,
      transcription: allowed(payload['transcription'], {
        'ready',
        'not_configured',
        'blocked_codec_sandbox',
      }),
      reminderPush: allowed(payload['reminderPush'], {
        'configured',
        'not_configured',
      }),
      pending: count(payload['pending']),
      pendingReminderHints: count(payload['pendingReminderHints']),
    );
  }

  bool freshAt(DateTime now) {
    final age = now.difference(receivedAt);
    return !age.isNegative && age < const Duration(minutes: 3);
  }

  String describe(DateTime now) {
    if (!freshAt(now)) {
      return 'Worker heartbeat is stale or has an invalid time. Service readiness is unknown.';
    }
    final connection = healthy == true && verified == true
        ? 'Worker connection reported healthy and verified.'
        : 'Worker connection readiness is unknown or unavailable.';
    final transcriptionStatus = switch (transcription) {
      'ready' => 'Transcription reported ready.',
      'not_configured' => 'Transcription is not configured.',
      'blocked_codec_sandbox' =>
        'Transcription is blocked: codec sandbox required.',
      _ => 'Transcription readiness is unknown.',
    };
    final reminders = switch (reminderPush) {
      'configured' => 'Reminder relay configured; delivery unverified.',
      'not_configured' => 'Reminder relay is not configured.',
      _ => 'Reminder relay readiness is unknown.',
    };
    return [
      connection,
      transcriptionStatus,
      reminders,
      if (pending != null) 'Pending tasks: $pending.',
      if (pendingReminderHints != null)
        'Pending reminder hints: $pendingReminderHints.',
    ].join(' ');
  }
}

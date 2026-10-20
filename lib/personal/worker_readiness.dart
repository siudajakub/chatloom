// SPDX-License-Identifier: AGPL-3.0-or-later

/// Only allowlisted fields of an already authenticated heartbeat are retained.
/// Unknown or older payloads never imply that optional services are ready.
class WorkerReadiness {
  /// The worker sends a heartbeat every five minutes, and sooner when its
  /// payload changes. Fresh means at most one missed heartbeat plus slack.
  static const freshFor = Duration(minutes: 11);

  final DateTime receivedAt;
  final bool? healthy;
  final bool? verified;
  final String? transcription;
  final String? reminderPush;
  final int? pending;
  final int? pendingReminderHints;

  /// Whether the worker scans local bridges for automatic transcription
  /// (`scan`) or not (`off`); null for older workers.
  final String? autoTranscription;

  /// Media the worker transcribes: 2 = voice, rounds, any video and audio
  /// (also sent as files); null for older workers (voice notes, other
  /// `m.audio` and strict rounds only).
  final int? transcriptionMedia;

  /// True when the worker also picks up cloud-room messages from its own
  /// Matrix sync, so this device need not ask for them; null for older
  /// workers.
  final bool? autoTranscriptionLive;

  const WorkerReadiness({
    required this.receivedAt,
    this.healthy,
    this.verified,
    this.transcription,
    this.reminderPush,
    this.pending,
    this.pendingReminderHints,
    this.autoTranscription,
    this.transcriptionMedia,
    this.autoTranscriptionLive,
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
      autoTranscription: allowed(payload['autoTranscription'], {'scan', 'off'}),
      transcriptionMedia:
          payload['transcriptionMedia'] is int &&
              (payload['transcriptionMedia'] as int) > 0 &&
              (payload['transcriptionMedia'] as int) < 100
          ? payload['transcriptionMedia'] as int
          : null,
      autoTranscriptionLive: payload['autoTranscriptionLive'] is bool
          ? payload['autoTranscriptionLive'] as bool
          : null,
    );
  }

  bool freshAt(DateTime now) {
    final age = now.difference(receivedAt);
    return !age.isNegative && age < freshFor;
  }

  @override
  bool operator ==(Object other) =>
      other is WorkerReadiness &&
      other.receivedAt == receivedAt &&
      other.healthy == healthy &&
      other.verified == verified &&
      other.transcription == transcription &&
      other.reminderPush == reminderPush &&
      other.pending == pending &&
      other.pendingReminderHints == pendingReminderHints &&
      other.autoTranscription == autoTranscription &&
      other.transcriptionMedia == transcriptionMedia &&
      other.autoTranscriptionLive == autoTranscriptionLive;

  @override
  int get hashCode => Object.hash(
    receivedAt,
    healthy,
    verified,
    transcription,
    reminderPush,
    pending,
    pendingReminderHints,
    autoTranscription,
    transcriptionMedia,
    autoTranscriptionLive,
  );

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

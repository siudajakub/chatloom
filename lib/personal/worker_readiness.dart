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

  /// Curve25519 identity key of the device that sent this heartbeat (the
  /// megolm sender the trust check proved). Identifies the worker's session
  /// in the device list; never shown.
  final String? deviceKey;

  /// True when the worker answers `metadata.resync` (publishes the state of
  /// merged persons again); null for older workers.
  final bool? metadataResync;

  /// Own device ids whose journal commands the worker ignores as untrusted
  /// (not pinned, not verified or blocked); empty for older workers.
  final List<String> untrustedDevices;

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
    this.deviceKey,
    this.metadataResync,
    this.untrustedDevices = const [],
  });

  factory WorkerReadiness.fromPayload(
    Map<String, dynamic> payload,
    DateTime at, {
    String? deviceKey,
  }) {
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
      deviceKey: deviceKey,
      metadataResync: payload['metadataResync'] is int
          ? (payload['metadataResync'] as int) >= 1
          : null,
      untrustedDevices: switch (payload['untrustedDevices']) {
        final List<Object?> ids => List.unmodifiable(
          ids.whereType<String>().where((id) => id.length <= 255).take(64),
        ),
        _ => const <String>[],
      },
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
      other.autoTranscriptionLive == autoTranscriptionLive &&
      other.deviceKey == deviceKey &&
      other.metadataResync == metadataResync &&
      _sameList(other.untrustedDevices, untrustedDevices);

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

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
    deviceKey,
    metadataResync,
    Object.hashAll(untrustedDevices),
  );

  /// Short status of the background service for a settings row: a pill
  /// label, one plain line and a health level. [describe] keeps the full
  /// details for the tap-through sheet.
  WorkerStatus status(DateTime now) {
    if (!freshAt(now)) return WorkerStatus.offlineSince(receivedAt, now);
    if (healthy != true || verified != true) {
      return const WorkerStatus(
        'Needs attention',
        'The background service reported a problem.',
        WorkerHealth.attention,
      );
    }
    final waiting = pending ?? 0;
    return WorkerStatus(
      'Ready',
      waiting > 0
          ? '$waiting ${waiting == 1 ? 'task' : 'tasks'} waiting'
          : 'Running normally',
      WorkerHealth.ok,
    );
  }

  /// [status] for transcription: also says when transcription itself is
  /// not set up or blocked on the server.
  WorkerStatus transcriptionStatus(DateTime now) {
    final overall = status(now);
    if (overall.health != WorkerHealth.ok) return overall;
    return switch (transcription) {
      'ready' => const WorkerStatus(
        'Ready',
        'Transcription is available',
        WorkerHealth.ok,
      ),
      'not_configured' => const WorkerStatus(
        'Not set up',
        'Transcription is not set up on the server.',
        WorkerHealth.attention,
      ),
      'blocked_codec_sandbox' => const WorkerStatus(
        'Needs update',
        'Transcription is blocked on the server until it is updated.',
        WorkerHealth.attention,
      ),
      _ => const WorkerStatus(
        'Unknown',
        'The background service did not report transcription.',
        WorkerHealth.unknown,
      ),
    };
  }

  String describe(DateTime now) {
    if (!freshAt(now)) {
      return 'No recent check-in from the background service, so its status is unknown.';
    }
    final connection = healthy == true && verified == true
        ? 'Background service connected and verified.'
        : 'Background service connection is unknown or unavailable.';
    final transcriptionStatus = switch (transcription) {
      'ready' => 'Transcription ready.',
      'not_configured' => 'Transcription not set up.',
      'blocked_codec_sandbox' =>
        'Transcription blocked: the server needs an update (codec sandbox).',
      _ => 'Transcription status unknown.',
    };
    final reminders = switch (reminderPush) {
      'configured' => 'Reminder notifications set up; delivery not checked.',
      'not_configured' => 'Reminder notifications not set up.',
      _ => 'Reminder notification status unknown.',
    };
    return [
      connection,
      transcriptionStatus,
      reminders,
      if (pending != null) 'Waiting tasks: $pending.',
      if (pendingReminderHints != null)
        'Waiting reminders: $pendingReminderHints.',
    ].join('\n');
  }
}

/// How a [WorkerStatus] reads at a glance (the pill's dot colour).
enum WorkerHealth { ok, attention, offline, unknown }

/// A short, human status of the background service (the worker).
class WorkerStatus {
  final String label;
  final String line;
  final WorkerHealth health;
  const WorkerStatus(this.label, this.line, this.health);

  /// Private sync is not available, so nothing is known.
  static const unavailable = WorkerStatus(
    'Unknown',
    'Shown once private sync is connected.',
    WorkerHealth.unknown,
  );

  /// No authenticated check-in has ever arrived.
  static const notPaired = WorkerStatus(
    'Not connected',
    'The background service has not checked in yet.',
    WorkerHealth.attention,
  );

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// The last check-in is too old (or in the future).
  factory WorkerStatus.offlineSince(DateTime at, DateTime now) {
    final local = at.toLocal();
    final today = now.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final time = '${two(local.hour)}:${two(local.minute)}';
    final sameDay =
        local.year == today.year &&
        local.month == today.month &&
        local.day == today.day;
    return WorkerStatus(
      'Offline',
      at.isAfter(now)
          ? 'The background service clock looks wrong.'
          : sameDay
          ? 'Last seen at $time'
          : 'Last seen ${local.day} ${_months[local.month - 1]} at $time',
      WorkerHealth.offline,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WorkerStatus &&
      other.label == label &&
      other.line == line &&
      other.health == health;

  @override
  int get hashCode => Object.hash(label, line, health);
}

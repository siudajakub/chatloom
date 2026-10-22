// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:personal_core/personal_core.dart';
import 'ports.dart';
import 'store.dart';

String stableId(String namespace, String id) =>
    '$namespace-${sha256.convert(utf8.encode(id))}';

class WorkerEngine {
  /// The local index query is cheap (one read-only SQLite range scan), so a
  /// short interval keeps a fresh message's transcript a few seconds away.
  static const autoScanInterval = Duration(seconds: 3);
  static const autoScanPageLimit = 100;
  static const autoScanCheckpoint = 'auto-scan';

  /// Start of the live (Matrix sync) feed's window; cleared while off.
  static const autoLiveCheckpoint = 'auto-live-since';
  static const autoBudgetWindow = Duration(hours: 24);

  /// Transient failures (source busy, provider overloaded, keys missing) are
  /// retried with exponential backoff. Provider retries are only for answers
  /// that prove no charge; paid uncertainty is never retried.
  static const transientRetryLimit = 4;
  static const transientRetryCodes = {
    'local_source_unavailable',
    'local_source_busy',
    'source_unavailable',
    'room_unavailable',
    'openai_rate_limited',
    'openai_unavailable',
    'openai_unreachable',
    // The chat's disappearing setting could not be read: never transcribed
    // while unknown, tried again later (CB-02).
    'source_policy_unknown',
  };
  final WorkerStore store;
  final FeatureTransport transport;
  final Transcriber transcriber;
  final DateTime Function() clock;

  /// Read-only scan of newly indexed local voice/round/video messages.
  final RecentSourceScanner? recentSources;

  /// Push feed of messages received by the worker's own Matrix sync (cloud
  /// rooms that the local scan cannot see).
  final LiveSourceFeed? liveSources;

  /// Bounded parallelism: provider round trips dominate, so two jobs keep a
  /// burst moving while FFmpeg (one thread each) stays within the unit's
  /// single-CPU quota. The local adapter still serializes its exports.
  final int maxConcurrentTranscripts;

  /// Private operator switch (`autoTranscription` in the worker config).
  /// Off by default: the synced user policy alone never starts a scan.
  final bool autoTranscription;

  /// Round-robin source audit over every transcript job (redaction
  /// detection): [sourceAuditBatch] probes at most this often.
  static const sourceAuditInterval = Duration(seconds: 30);
  static const sourceAuditBatch = 4;

  /// Jobs parked on an unknown source status (`waitingSync` +
  /// `source_status_unknown`: the source could not be checked before the
  /// download, or a finished transcript waits for that check before it is
  /// published) are probed again this often, ahead of the round-robin.
  /// Before, they waited for the round-robin over every transcript job, so
  /// with a few hundred jobs a fresh voice note's transcript could wait the
  /// better part of an hour after a single slow check.
  static const parkedSourceRetry = Duration(seconds: 5);

  /// A parked job whose source still cannot be checked is probed again
  /// after a growing delay (5 s, doubling, at most this), so a source that
  /// is gone for good costs a probe every half hour instead of every 5 s.
  static const parkedSourceRetryMax = Duration(minutes: 30);

  /// A transcript waiting for room keys this long ends `keys_unavailable`;
  /// a later key for its room queues it once more.
  static const keysWaitLimit = Duration(hours: 24);

  /// A key arrival retries a room's key-waiting job at most this often.
  static const keysWakeInterval = Duration(minutes: 5);

  /// "Only if no reply" checks run beside the loop, at most this many at a
  /// time, each bounded in time, so they never delay journal publication.
  static const maxConcurrentReminderChecks = 2;
  static const reminderReplyCheckTimeout = Duration(seconds: 15);

  /// Automatic jobs refused by a rule rather than failing (a disappearing
  /// chat, media that is not speech, limits, keys that never arrived): the
  /// user never asked, so no error is shown; they end `cancelled`.
  static const silentAutoRefusals = {
    'protected_media',
    'not_audio',
    'invalid_round_format',
    'invalid_media_format',
    'invalid_media_metadata',
    'source_too_large',
    'no_audio_track',
    'keys_unavailable',
    'source_policy_unknown',
  };

  /// Worker bookkeeping in job bodies that clients never need.
  static const _internalJobKeys = {
    'pendingResult',
    'providerAttemptAt',
    'auditAt',
    'audits',
    'waitingKeysSince',
    'keysWokenAt',
    'keysRequeued',
  };
  final Map<String, Cancellation> _cancellations = {};
  final Map<String, Future<void>> _activeReminders = {};
  bool _running = false;
  bool _sourceAuditBusy = false;
  DateTime? _sourceAuditAt;
  DateTime? _parkedAuditAt;
  int _parkedCursor = 0;
  bool _autoScanBusy = false;
  DateTime? _autoScanAt;
  final Map<String, Future<void>> _activeTranscripts = {};
  Future<void> _largeSlot = Future<void>.value();
  DateTime? _mediaPrunedAt;
  Completer<void>? _wake;
  WorkerEngine(
    this.store,
    this.transport,
    this.transcriber, {
    DateTime Function()? clock,
    this.recentSources,
    this.liveSources,
    this.autoTranscription = false,
    this.maxConcurrentTranscripts = 2,
  }) : clock = clock ?? DateTime.now;

  /// True when this worker creates automatic jobs itself.
  bool get autoScanActive =>
      autoTranscription && (recentSources != null || liveSources != null);

  /// True when automatic jobs also come from the worker's own Matrix sync.
  bool get liveScanActive => autoTranscription && liveSources != null;

  /// Completes when a transcript finished (a result waits to be published)
  /// or other work became available. The daemon waits on it instead of
  /// sleeping, so results are flushed immediately.
  Future<void> get wakeup => (_wake ??= Completer<void>()).future;

  void _signal() {
    final wake = _wake;
    _wake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  /// Transcripts currently running (diagnostics and tests).
  int get activeTranscripts => _activeTranscripts.length;

  void recover() {
    store.transaction(() {
      for (final job in [
        for (final kind in ['transcript', 'schedule', 'reminder'])
          ...store.jobsWhere(kind, ['processing']),
      ]) {
        // Paid request outcomes cannot be inferred after a crash; a job that
        // never reached the provider (still downloading, measuring or
        // converting) is simply queued again.
        final paid = job['providerAttemptAt'] != null;
        job['state'] = job['kind'] == 'transcript' && paid
            ? 'unknown'
            : 'queued';
        if (job['kind'] == 'transcript') {
          job['errorCode'] = paid ? 'paid_request_unknown' : null;
          job.remove('providerAttemptAt');
        }
        store.saveJob(job);
        _result(job, 'recovery');
      }
      // Scanning is off for this run: forget the position, so switching it
      // back on later starts at the end of the index instead of sweeping
      // up what arrived meanwhile (the next scan stores the new end).
      if (!autoScanActive &&
          (store.checkpoint(autoScanCheckpoint)?.isNotEmpty ?? false)) {
        store.setCheckpoint(autoScanCheckpoint, '');
      }
      if (!liveScanActive &&
          (store.checkpoint(autoLiveCheckpoint)?.isNotEmpty ?? false)) {
        store.setCheckpoint(autoLiveCheckpoint, '');
      }
    });
  }

  void accept(PersonalOperation op) {
    if (!{
      'transcript.request',
      'transcript.cancel',
      'schedule.create',
      'schedule.update',
      'schedule.cancel',
      'schedule.sendNow',
      'metadata.put',
      'metadata.delete',
      'reminder.create',
      'reminder.cancel',
      'worker.pairing',
    }.contains(op.kind)) {
      return;
    }
    if (store.hasCommand(op.opId)) return;
    store.transaction(() {
      store.command(op.opId, Map<String, dynamic>.from(op.toJson()));
      if (op.kind == 'worker.pairing') {
        if (!transport.verified) {
          throw const WorkerFailure('device_verification_required');
        }
        if (op.entityId != 'worker' ||
            (op.payload.containsKey('schema') &&
                op.payload['schema'] != personalSchemaVersion)) {
          throw const WorkerFailure('invalid_pairing');
        }
        _publish(op, 'worker.pairing.result', {
          'state': 'done',
          'acceptedOpId': op.opId,
          'verified': true,
          'revision': 0,
        });
        return;
      }
      if (op.kind.startsWith('metadata.')) {
        _metadata(op);
        return;
      }
      final previous = store.job(op.entityId);
      final revision = previous?['revision'] as int? ?? 0;
      if (op.baseRevision != revision) {
        _reject(op, previous, 'conflict');
        return;
      }
      if (op.kind.startsWith('reminder.')) {
        if (op.kind == 'reminder.cancel') {
          if (previous == null || previous['kind'] != 'reminder') {
            _reject(op, previous, 'not_found');
            return;
          }
          previous['state'] = 'cancelled';
          previous['acceptedOpId'] = op.opId;
          previous['revision'] = revision + 1;
          store.saveJob(previous);
          _result(previous, op.opId);
          return;
        }
        if (previous != null) {
          _reject(op, previous, 'already_exists');
          return;
        }
        final ref = ConversationRef.fromJson(
          Map<String, dynamic>.from(op.payload['conversation'] as Map),
        );
        _validateConversation(ref);
        final due = DateTime.parse(op.payload['dueAt'] as String).toUtc();
        final untilReply = op.payload['untilReply'];
        final anchor = op.payload['anchorEventId'];
        // Only the documented fields are stored and echoed in results;
        // anything else is dropped. The anchor is an opaque client hint for
        // the notification; the worker never fetches or resolves it.
        if (op.payload['id'] != op.entityId ||
            (untilReply != null && untilReply is! bool) ||
            (anchor != null &&
                (anchor is! String ||
                    !anchor.startsWith(r'$') ||
                    anchor.length > 255))) {
          throw const WorkerFailure('invalid_reminder');
        }
        final body = <String, dynamic>{
          'id': op.entityId,
          'conversation': ref.toJson(),
          'untilReply': ?untilReply,
          'anchorEventId': ?anchor,
          'kind': 'reminder',
          'revision': 1,
          'state': 'queued',
          'acceptedOpId': op.opId,
          'dueAt': due.toIso8601String(),
          'createdAt': op.createdAt.toUtc().toIso8601String(),
        };
        store.saveJob(body);
        _result(body, op.opId);
        return;
      }
      if (op.kind == 'transcript.cancel') {
        if (previous == null || previous['kind'] != 'transcript') {
          _reject(op, previous, 'not_found');
          return;
        }
        if (previous['state'] == 'done') {
          _reject(op, previous, 'too_late');
          return;
        }
        previous['state'] = 'cancelled';
        previous['acceptedOpId'] = op.opId;
        previous['revision'] = revision + 1;
        _cancellations[op.entityId]?.cancel();
        store.saveJob(previous);
        _result(previous, op.opId);
        return;
      }
      if (op.kind == 'transcript.request') {
        if (previous != null &&
            (!{
                  'unknown',
                  'failed',
                  'cancelled',
                  'done',
                }.contains(previous['state']) ||
                previous['kind'] != 'transcript')) {
          _reject(op, previous, 'already_exists');
          return;
        }
        // Only automatic detection or an offered language reaches OpenAI.
        if (!validTranscriptionLanguage(op.payload['language'])) {
          throw const WorkerFailure('invalid_language');
        }
        final job = TranscriptionJob.fromJson(op.payload);
        _validateConversation(job.source.conversation);
        if (job.id != op.entityId || !job.source.eventId.startsWith(r'$')) {
          throw const WorkerFailure('invalid_source');
        }
        // Automatic work never replaces an existing job (the rule of the
        // worker's own scans): a lagging or second device asking after the
        // job finished must not pay again or erase its budget record. Only
        // an explicit request re-runs a finished job.
        if (job.automatic && previous != null) {
          _reject(op, previous, 'already_exists');
          return;
        }
        // Automatic work needs the operator switch as well as the synced
        // policy, also when a client asks on the policy's behalf.
        if (job.automatic && !autoTranscription) {
          _reject(op, previous, 'auto_disabled');
          return;
        }
        final body =
            Map<String, dynamic>.from(
              TranscriptionJob(
                id: job.id,
                source: job.source,
                state: JobState.queued,
                language: job.language,
                // A client may request on the policy's behalf (catch-up for
                // a message the worker cannot scan). Auto limits then apply.
                origin: job.origin,
              ).toJson(),
            )..addAll({
              'kind': 'transcript',
              'revision': revision + 1,
              'acceptedOpId': op.opId,
              if (job.automatic) 'createdAt': clock().toUtc().toIso8601String(),
            });
        store.saveJob(body);
        _result(body, op.opId);
        return;
      }
      if (op.kind == 'schedule.cancel' || op.kind == 'schedule.sendNow') {
        if (previous == null || previous['kind'] != 'schedule') {
          _reject(op, previous, 'not_found');
          return;
        }
        if (!{'queued', 'paused', 'waitingKeys'}.contains(previous['state']) ||
            previous['attempted'] == true) {
          _reject(op, previous, 'too_late');
          return;
        }
        previous['revision'] = revision + 1;
        previous['acceptedOpId'] = op.opId;
        previous['state'] = op.kind == 'schedule.cancel'
            ? 'cancelled'
            : 'queued';
        if (op.kind == 'schedule.sendNow') {
          previous['dueAt'] = clock().toUtc().toIso8601String();
        }
        store.saveJob(previous);
        _result(previous, op.opId);
        return;
      }
      final schedule = ScheduledSend.fromJson(op.payload);
      _validateConversation(schedule.target.conversation);
      if (schedule.id != op.entityId ||
          !{
            'm.text',
            'm.notice',
            'm.image',
            'm.video',
            'm.audio',
            'm.file',
          }.contains(schedule.content['msgtype']) ||
          schedule.content['body'] is! String ||
          (schedule.content['body'] as String).isEmpty) {
        throw const WorkerFailure('invalid_schedule');
      }
      if (schedule.content['msgtype'] != 'm.text' &&
          schedule.content['msgtype'] != 'm.notice' &&
          schedule.content['file'] is! Map) {
        throw const WorkerFailure('encrypted_media_required');
      }
      if (op.kind == 'schedule.create' && previous != null ||
          op.kind == 'schedule.update' && previous == null) {
        _reject(op, previous, 'already_exists_or_missing');
        return;
      }
      if (previous != null &&
          (!{'queued', 'paused'}.contains(previous['state']) ||
              previous['attempted'] == true)) {
        _reject(op, previous, 'too_late');
        return;
      }
      final body = Map<String, dynamic>.from(schedule.toJson())
        ..addAll({
          'kind': 'schedule',
          'revision': revision + 1,
          'state': 'queued',
          'transactionId': stableId(
            'scheduled',
            '${op.entityId}:${revision + 1}',
          ),
          'deviceId': transport.deviceId,
          'acceptedOpId': op.opId,
          'attempted': false,
        });
      store.saveJob(body);
      _result(body, op.opId);
    });
  }

  void _validateConversation(ConversationRef ref) {
    if (ref.accountId != transport.accountId || !ref.roomId.startsWith('!')) {
      throw const WorkerFailure('invalid_account_or_room');
    }
  }

  void _metadata(PersonalOperation op) {
    final old = store.metadata(op.entityId);
    final revision = old?['revision'] as int? ?? 0;
    if (revision != op.baseRevision) {
      _publish(op, 'metadata.result', {
        'state': 'conflict',
        'revision': revision,
        ...?old,
        'existingValue': old?['value'],
        'proposedValue': op.payload.containsKey('value')
            ? op.payload['value']
            : op.payload,
        'acceptedOpId': op.opId,
      });
      return;
    }
    final deleted = op.kind == 'metadata.delete';
    final value = deleted
        ? null
        : op.payload.containsKey('value')
        ? op.payload['value']
        : op.payload;
    store.saveMetadata(op.entityId, revision + 1, deleted, value);
    _publish(op, 'metadata.result', {
      'state': 'done',
      'value': value,
      'deleted': deleted,
      'revision': revision + 1,
      'acceptedOpId': op.opId,
    });
  }

  void _publish(
    PersonalOperation source,
    String kind,
    Map<String, dynamic> payload,
  ) {
    final result = PersonalOperation(
      opId: stableId('result', source.opId),
      kind: kind,
      entityId: source.entityId,
      baseRevision: payload['revision'] as int? ?? source.baseRevision,
      createdAt: clock(),
      payload: payload,
    );
    store.enqueue(result.opId, result.toJson());
  }

  void _reject(
    PersonalOperation op,
    Map<String, dynamic>? previous,
    String code,
  ) => _publish(
    op,
    op.kind == 'worker.pairing'
        ? 'worker.pairing.result'
        : op.kind.startsWith('transcript')
        ? 'transcript.result'
        : op.kind.startsWith('reminder')
        ? 'reminder.result'
        : 'schedule.result',
    {
        ...?previous,
        'id': op.entityId,
        'state': 'conflict',
        'actualState': previous?['state'],
        'errorCode': code,
        'revision': previous?['revision'] ?? 0,
        'acceptedOpId': op.opId,
      }
      ..removeWhere((key, _) => _internalJobKeys.contains(key))
      // The text was published with the job's done transition; echoing it
      // in every refusal duplicated it and could exceed the event limit.
      ..remove('text'),
  );
  void _result(Map<String, dynamic> body, String cause) {
    final kind = '${body['kind']}.result';
    final id = stableId(
      'state',
      '${body['id']}:${body['revision']}:${body['state']}:$cause',
    );
    final result = PersonalOperation(
      opId: id,
      kind: kind,
      entityId: body['id'] as String,
      baseRevision: body['revision'] as int,
      createdAt: clock(),
      payload: Map<String, dynamic>.from(body)
        ..removeWhere((key, _) => _internalJobKeys.contains(key)),
    );
    store.enqueue(id, result.toJson());
  }

  void rejectInvalid(PersonalOperation op, String code) {
    if (store.hasCommand(op.opId)) return;
    store.transaction(() {
      store.command(op.opId, Map<String, dynamic>.from(op.toJson()));
      _reject(op, store.job(op.entityId), code);
    });
  }

  Future<void> tick() async {
    if (_running) return;
    _running = true;
    try {
      final pruned = _mediaPrunedAt;
      if (pruned == null ||
          clock().difference(pruned) > const Duration(hours: 1)) {
        _mediaPrunedAt = clock();
        pruneMediaCheckpoints();
      }
      // Schedules take priority over paid audio jobs; each is independently
      // durable. Only queued schedules have anything left to do.
      for (final job in store.jobsWhere('schedule', ['queued'])) {
        await _schedule(job);
      }
      for (final job in store.jobsWhere('reminder', [
        'queued',
        'waitingKeys',
        'waitingSync',
      ])) {
        _startReminder(job);
      }
      final free = maxConcurrentTranscripts - _activeTranscripts.length;
      if (free > 0) {
        final now = clock();
        final candidates = store
            .jobsWhere('transcript', ['queued', 'waitingKeys'])
            .where(
              (j) =>
                  !_activeTranscripts.containsKey(j['id']) && _retryDue(j, now),
            )
            .toList();
        for (final next in _byPriority(candidates).take(free)) {
          final id = next['id'] as String;
          // A storage failure inside a job must never become an uncaught
          // asynchronous error that ends the process; the job stays as
          // stored and is picked up again.
          final run = _transcript(next).then<void>((_) {}, onError: (_) {});
          _activeTranscripts[id] = run;
          unawaited(
            run.whenComplete(() {
              if (identical(_activeTranscripts[id], run)) {
                _activeTranscripts.remove(id);
              }
              _signal();
            }),
          );
        }
      }
    } finally {
      _running = false;
    }
  }

  static bool _retryDue(Map<String, dynamic> job, DateTime now) {
    final at = job['retryAt'];
    if (at is! String) return true;
    final due = DateTime.tryParse(at);
    return due == null || !now.isBefore(due);
  }

  /// Explicit requests never wait behind automatic background work; among
  /// automatic jobs the newest message goes first (a fresh voice note should
  /// not queue behind a burst of older ones). Manual jobs keep their order.
  static List<Map<String, dynamic>> _byPriority(
    List<Map<String, dynamic>> jobs,
  ) {
    final indexed = jobs.indexed.toList();
    DateTime created(Map<String, dynamic> job) =>
        DateTime.tryParse(job['createdAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    bool automatic(Map<String, dynamic> job) =>
        job['origin'] == TranscriptionOrigin.auto.name;
    indexed.sort((a, b) {
      final autoA = automatic(a.$2), autoB = automatic(b.$2);
      if (autoA != autoB) return autoA ? 1 : -1;
      if (autoA) {
        final order = created(b.$2).compareTo(created(a.$2));
        if (order != 0) return order;
      }
      return a.$1.compareTo(b.$1);
    });
    return [for (final entry in indexed) entry.$2];
  }

  /// Exponential backoff for transient failures: 15 s, 1 min, 4 min, 16 min
  /// (keys: up to 30 min apart, for at most [keysWaitLimit]).
  Duration _backoff(int attempt) {
    final seconds = 15 * (1 << (2 * (attempt - 1)).clamp(0, 8));
    return Duration(seconds: seconds.clamp(15, 1800));
  }

  Future<void> _schedule(Map<String, dynamic> job) async {
    if (job['state'] != 'queued') return;
    final due = DateTime.parse(job['dueAt'] as String);
    if (clock().isBefore(due)) return;
    if (job['deviceId'] != transport.deviceId || !transport.verified) {
      _setState(job, 'paused', 'device_verification_required');
      return;
    }
    if (job['attempted'] != true &&
        clock().difference(due) > const Duration(minutes: 5)) {
      _setState(job, 'paused', 'late_over_five_minutes');
      return;
    }
    job = store.job(job['id'] as String)!;
    if (job['state'] != 'queued') return;
    job['attempted'] = true;
    _setState(job, 'processing', null);
    try {
      final target = SendTarget.fromJson(
        Map<String, dynamic>.from(job['target'] as Map),
      );
      final eventId = await transport.send(
        target,
        Map<String, dynamic>.from(job['content'] as Map),
        job['transactionId'] as String,
      );
      job['eventId'] = eventId;
      _setState(job, 'done', null);
      // Bound receipt only after server accepted the explicit scheduled reply.
      if (target.readUpToEventId != null) {
        try {
          await transport.readAfterAcceptedReply(target);
        } catch (_) {
          job['readMarkerError'] = 'read_marker_failed';
          store.saveJob(job);
        }
      }
    } on WorkerFailure catch (e) {
      _setState(job, e.code == 'send_unknown' ? 'queued' : 'failed', e.code);
    } catch (_) {
      _setState(job, 'queued', 'send_unknown');
    }
  }

  /// Retry interval of a reminder's reply check while the history cannot be
  /// read, and the polling interval of a successful check before due.
  static const reminderReplyRecheck = Duration(seconds: 30);

  /// How long a due "only if no reply" reminder waits for unreadable history
  /// before it fires anyway (`replyCheck: skipped`).
  static const reminderReplyCheckGrace = Duration(minutes: 5);

  /// Fires a plain reminder at once; starts the reply check of an "only if
  /// no reply" reminder beside the loop (see [maxConcurrentReminderChecks]).
  /// Before, checks ran one after another inside [tick], up to 10 s each,
  /// and delayed the publication of finished transcripts and reminders.
  void _startReminder(Map<String, dynamic> job) {
    final id = job['id'] as String;
    if (_activeReminders.containsKey(id)) return;
    final now = clock();
    final due = DateTime.parse(job['dueAt'] as String);
    if (job['untilReply'] != true) {
      // Nothing to wait for: fired within this tick once due.
      if (!now.isBefore(due)) {
        unawaited(_reminder(job).then<void>((_) {}, onError: (_) {}));
      }
      return;
    }
    final next = job['nextReplyCheckAt'];
    if (now.isBefore(due.add(reminderReplyCheckGrace)) &&
        next is String &&
        now.isBefore(DateTime.parse(next))) {
      return; // Not due for a check yet.
    }
    if (_activeReminders.length >= maxConcurrentReminderChecks) {
      return; // The next tick starts it.
    }
    final run = _reminder(job).then<void>((_) {}, onError: (_) {});
    _activeReminders[id] = run;
    unawaited(
      run.whenComplete(() {
        if (identical(_activeReminders[id], run)) _activeReminders.remove(id);
        _signal();
      }),
    );
  }

  /// Completes when no reminder check is running (tests, shutdown).
  Future<void> reminderChecksIdle() async {
    while (_activeReminders.isNotEmpty) {
      await Future.wait(_activeReminders.values.toList());
    }
  }

  /// A due reminder is fired. With "only if no reply" (`untilReply`) it is
  /// first checked for a real reply since it was set; a reply cancels it
  /// (`replied`). While the history cannot be read (missing keys, gaps), the
  /// check is retried every [reminderReplyRecheck], but only until
  /// [reminderReplyCheckGrace] after the due time: then the reminder fires
  /// anyway with `replyCheck: skipped` instead of waiting forever. The grace
  /// is measured from `dueAt`, so reminders stuck before this rule fire on
  /// the first tick that sees them.
  Future<void> _reminder(Map<String, dynamic> job) async {
    final due = DateTime.parse(job['dueAt'] as String);
    final graceEnd = due.add(reminderReplyCheckGrace);
    final next = job['nextReplyCheckAt'];
    if (clock().isBefore(graceEnd) &&
        next is String &&
        clock().isBefore(DateTime.parse(next))) {
      return;
    }
    if (job['untilReply'] == true) {
      final ref = ConversationRef.fromJson(
        Map<String, dynamic>.from(job['conversation'] as Map),
      );
      String? unresolved;
      var replied = false;
      try {
        replied = await transport
            .hasRepliedSince(ref, DateTime.parse(job['createdAt'] as String))
            .timeout(reminderReplyCheckTimeout);
      } on WorkerFailure catch (e) {
        unresolved = e.code;
      } catch (_) {
        unresolved = 'history_unavailable';
      }
      // The journal may have changed the reminder while the check ran (for
      // example cancelled it): apply the outcome only to the same version.
      final current = store.job(job['id'] as String);
      if (current == null ||
          current['revision'] != job['revision'] ||
          !{
            'queued',
            'waitingKeys',
            'waitingSync',
          }.contains(current['state'])) {
        return;
      }
      job = current;
      if (replied) {
        job.remove('nextReplyCheckAt');
        _setState(job, 'cancelled', 'replied');
        return;
      }
      final now = clock();
      if (unresolved != null) {
        if (now.isBefore(graceEnd)) {
          _deferReminder(
            job,
            unresolved == 'waiting_keys' ? 'waitingKeys' : 'waitingSync',
            unresolved,
          );
          return;
        }
        // Past the grace period: remind rather than stay silent, and say
        // that replies could not be checked.
        job['replyCheck'] = 'skipped';
        job['replyCheckError'] = unresolved;
      } else if (now.isBefore(due)) {
        // No reply yet; look again later instead of on every tick.
        job['nextReplyCheckAt'] = _nextReplyCheck(
          now,
          due,
        ).toUtc().toIso8601String();
        if (job['state'] != 'queued') {
          _setState(job, 'queued', null);
        } else {
          store.saveJob(job);
        }
        return;
      }
    }
    if (clock().isBefore(due)) return;
    job.remove('nextReplyCheckAt');
    job['due'] = true;
    _setState(job, 'done', null);
  }

  /// [reminderReplyRecheck] from [now], but never past the due time or the
  /// end of the grace period, so neither is missed by up to 30 s.
  DateTime _nextReplyCheck(DateTime now, DateTime due) {
    var next = now.add(reminderReplyRecheck);
    for (final edge in [due, due.add(reminderReplyCheckGrace)]) {
      if (edge.isAfter(now) && edge.isBefore(next)) next = edge;
    }
    return next;
  }

  void _deferReminder(Map<String, dynamic> job, String state, String code) {
    job['nextReplyCheckAt'] = _nextReplyCheck(
      clock(),
      DateTime.parse(job['dueAt'] as String),
    ).toUtc().toIso8601String();
    if (job['state'] != state || job['errorCode'] != code) {
      _setState(job, state, code);
    } else {
      store.saveJob(job);
    }
  }

  void _setState(Map<String, dynamic> job, String state, String? error) {
    store.transaction(() {
      job['state'] = state;
      job['errorCode'] = error;
      job['revision'] = (job['revision'] as int) + 1;
      store.saveJob(job);
      _result(job, 'transition');
    });
  }

  static bool _parkedOnSource(Map<String, dynamic> job) =>
      job['kind'] == 'transcript' &&
      job['state'] == 'waitingSync' &&
      job['errorCode'] == 'source_status_unknown';

  static bool _auditDue(Map<String, dynamic> job, DateTime now) {
    final at = DateTime.tryParse(job['auditAt'] as String? ?? '');
    return at == null || !now.isBefore(at);
  }

  /// Parks [job] on an unknown source status (saved by the caller's
  /// transition) with its first probe [parkedSourceRetry] from now.
  void _parkOnSource(Map<String, dynamic> job) {
    job['audits'] = 0;
    job['auditAt'] = clock().add(parkedSourceRetry).toUtc().toIso8601String();
    _setState(job, 'waitingSync', 'source_status_unknown');
  }

  /// A parked job's probe failed again: next one after a doubled delay.
  void _deferAudit(Map<String, dynamic> job) {
    final audits = (job['audits'] as int? ?? 0) + 1;
    var delay = parkedSourceRetry * (1 << audits.clamp(0, 16));
    if (delay > parkedSourceRetryMax) delay = parkedSourceRetryMax;
    job['audits'] = audits;
    job['auditAt'] = clock().add(delay).toUtc().toIso8601String();
    store.saveJob(job);
  }

  /// Invoked after sync reconciliation; only explicit jobs, no history scan.
  /// Parked jobs (see [parkedSourceRetry]) first, then the bounded
  /// round-robin over every job.
  Future<void> auditTranscriptSources({bool force = false}) async {
    if (_sourceAuditBusy) return;
    final now = clock();
    final roundRobinDue =
        force ||
        _sourceAuditAt == null ||
        now.difference(_sourceAuditAt!) >= sourceAuditInterval;
    final parkedDue =
        force ||
        _parkedAuditAt == null ||
        now.difference(_parkedAuditAt!) >= parkedSourceRetry;
    if (!roundRobinDue && !parkedDue) return;
    _sourceAuditBusy = true;
    try {
      if (parkedDue) {
        final parked = store
            .jobsWithError('transcript', [
              'waitingSync',
            ], 'source_status_unknown')
            .where(
              (job) => _parkedOnSource(job) && (force || _auditDue(job, now)),
            )
            .toList();
        if (parked.isNotEmpty) {
          _parkedAuditAt = now;
          // Rotate, so more parked jobs than one batch all get their turn.
          final start = _parkedCursor % parked.length;
          final count = parked.length < sourceAuditBatch
              ? parked.length
              : sourceAuditBatch;
          for (var n = 0; n < count; n++) {
            await _auditSource(parked[(start + n) % parked.length]);
          }
          _parkedCursor = start + count;
        }
      }
      if (!roundRobinDue) return;
      _sourceAuditAt = now;
      // Only jobs whose source still matters: live ones, and finished ones
      // holding text (to erase it when the message is deleted). Skips,
      // failures and empty results have nothing to protect.
      final batch = store.sourceAuditBatch(
        store.checkpoint('source-audit'),
        limit: sourceAuditBatch,
      );
      for (final snapshot in batch) {
        await _auditSource(snapshot);
        store.setCheckpoint('source-audit', snapshot['id'] as String);
      }
    } finally {
      _sourceAuditBusy = false;
    }
  }

  /// Probes one job's source: a redacted source erases the job, a confirmed
  /// one releases a parked job (queued again, or its held result published).
  Future<void> _auditSource(Map<String, dynamic> snapshot) async {
    final id = snapshot['id'] as String;
    final source = SourceEventRef.fromJson(
      Map<String, dynamic>.from(snapshot['source'] as Map),
    );
    final redacted = await _probeSource(source);
    final current = store.job(id);
    if (current == null ||
        current['source'].toString() != snapshot['source'].toString()) {
      return;
    }
    if (redacted == true) {
      _invalidateSource(current);
    } else if (redacted == null) {
      if (_parkedOnSource(current)) _deferAudit(current);
    } else if (redacted == false &&
        current['state'] == 'waitingSync' &&
        current['pendingResult'] == null &&
        current['errorCode'] == 'source_status_unknown') {
      current
        ..remove('auditAt')
        ..remove('audits');
      _setState(current, 'queued', null);
    } else if (redacted == false &&
        current['pendingResult'] is Map &&
        current['state'] == 'waitingSync') {
      final pending = Map<String, dynamic>.from(
        current.remove('pendingResult') as Map,
      );
      current
        ..addAll(pending)
        ..remove('auditAt')
        ..remove('audits');
      _setState(current, 'done', null);
    }
  }

  /// New room keys arrived (to-device) for [rooms] (every room when null):
  /// their key-waiting jobs try again now instead of after their backoff,
  /// each at most once per [keysWakeInterval]; a job that gave up waiting
  /// (`keys_unavailable`) is queued once more. Jobs of other rooms are not
  /// touched: a Beeper account receives room keys many times a day. Nothing
  /// is paid or published for a retry that still finds no key.
  int retryWaitingKeys({Set<String>? rooms}) {
    if (rooms != null && rooms.isEmpty) return 0;
    final now = clock();
    bool inRooms(Map<String, dynamic> job) {
      if (rooms == null) return true;
      final source = job['source'];
      final conversation = source is Map ? source['conversation'] : null;
      return conversation is Map && rooms.contains(conversation['roomId']);
    }

    var woken = 0;
    store.transaction(() {
      for (final job in store.jobsWhere('transcript', ['waitingKeys'])) {
        if (!job.containsKey('retryAt') || !inRooms(job)) continue;
        final last = DateTime.tryParse(job['keysWokenAt'] as String? ?? '');
        if (last != null && now.difference(last) < keysWakeInterval) continue;
        job
          ..remove('retryAt')
          ..['keysWokenAt'] = now.toUtc().toIso8601String();
        store.saveJob(job);
        woken++;
      }
    });
    for (final job in _gaveUpOnKeys().where(inRooms)) {
      job
        ..remove('retries')
        ..remove('retryAt')
        ..remove('waitingKeysSince')
        ..['keysRequeued'] = true;
      _setState(job, 'queued', null);
      woken++;
    }
    if (woken > 0) _signal();
    return woken;
  }

  /// Jobs that ended `keys_unavailable` and were not queued again yet.
  List<Map<String, dynamic>> _gaveUpOnKeys() => [
    for (final job in store.jobsWithError('transcript', [
      'failed',
      'cancelled',
    ], 'keys_unavailable'))
      if (job['errorCode'] == 'keys_unavailable' && job['keysRequeued'] != true)
        job,
  ];

  /// Whether a job of [roomId] could use new room keys (the daemon wakes
  /// only for keys that can help).
  bool waitsForKeys(String roomId) {
    bool inRoom(Map<String, dynamic> job) {
      final source = job['source'];
      final conversation = source is Map ? source['conversation'] : null;
      return conversation is Map && conversation['roomId'] == roomId;
    }

    return store.jobsWhere('transcript', ['waitingKeys']).any(inRoom) ||
        _gaveUpOnKeys().any(inRoom);
  }

  Future<bool?> _probeSource(SourceEventRef source) async {
    try {
      return await transport
          .sourceRedacted(source)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      return null;
    }
  }

  void _invalidateSource(Map<String, dynamic> job) {
    if (job['errorCode'] == 'source_redacted' && job['state'] == 'cancelled') {
      return;
    }
    _cancellations[job['id']]?.cancel();
    store.transaction(() {
      job['text'] = null; // Explicit tombstone clears text in replica merges.
      job.remove('pendingResult');
      job['state'] = 'cancelled';
      job['errorCode'] = 'source_redacted';
      job['revision'] = (job['revision'] as int) + 1;
      store.saveJob(job);
      store.invalidateTranscriptPublications(job['id'] as String);
      pruneMediaCheckpoints(jobId: job['id'] as String);
      _result(job, 'source_redacted');
    });
  }

  Future<void> _transcript(Map<String, dynamic> job) async {
    final id = job['id'] as String;
    final requestId = job['acceptedOpId'];
    final automatic = job['origin'] == TranscriptionOrigin.auto.name;
    // A cancelled request may be replaced by an explicitly requested retry
    // while this attempt is still awaiting transport/provider cleanup.
    Map<String, dynamic>? currentAttempt() {
      final current = store.job(id);
      if (current == null ||
          current['kind'] != 'transcript' ||
          current['acceptedOpId'] != requestId ||
          current['state'] == 'cancelled') {
        return null;
      }
      return current;
    }

    // A retry of a job waiting for keys or backing off publishes only when
    // what clients see changes, not "processing" and the same wait again on
    // every attempt (two journal events per attempt, on every device).
    final quiet = job['state'] == 'waitingKeys' || job['retries'] != null;
    final shown = (job['state'] as String?, job['errorCode'] as String?);
    void finish(Map<String, dynamic> current, String state, String? error) {
      if (quiet && shown.$1 == state && shown.$2 == error) {
        current['state'] = state;
        current['errorCode'] = error;
        store.saveJob(current);
      } else {
        _setState(current, state, error);
      }
    }

    final cancel = Cancellation();
    void Function()? releaseLarge;
    try {
      // The user (policy) or the operator (switch, after a restart) may have
      // turned automatic transcription off while this job waited. Nothing
      // has been downloaded or paid for yet.
      if (automatic && (!autoTranscription || !autoPolicy().auto)) {
        _setState(job, 'cancelled', 'auto_disabled');
        return;
      }
      _cancellations[id] = cancel;
      job.remove('retryAt');
      if (quiet) {
        job['state'] = 'processing';
        store.saveJob(job);
      } else {
        _setState(job, 'processing', null);
      }
      final source = SourceEventRef.fromJson(
        Map<String, dynamic>.from(job['source'] as Map),
      );
      // Declared metadata, before any download: automatic jobs skip what
      // the limits or the user's kind switches exclude without fetching the
      // media; every job learns whether it is large.
      final facts = await _mediaFacts(source);
      cancel.check();
      if (automatic) {
        final skipped = _autoSkip(facts);
        final current = currentAttempt();
        if (current == null) return;
        if (facts?.kind case final kind?) {
          current['mediaKind'] = kind.name;
          store.saveJob(current);
        }
        if (skipped != null) {
          _setState(current, 'cancelled', skipped);
          return;
        }
      }
      final initialStatus = await _probeSource(source);
      cancel.check();
      final initial = currentAttempt();
      if (initial == null) return;
      if (initialStatus == null) {
        _parkOnSource(initial);
        return;
      }
      if (initialStatus == true) {
        _invalidateSource(initial);
        return;
      }
      // Memory bound: media declared above largeMediaBytes (or a manual job
      // of unknown size) waits for the single large slot; everything else,
      // including automatic jobs of unknown size (older adapters declare
      // none), is downloaded with a hard cap of largeMediaBytes, so wrong or
      // missing metadata cannot smuggle a big file past the slot.
      final declared = facts?.sizeBytes;
      final large = declared == null ? !automatic : declared > largeMediaBytes;
      if (large) {
        releaseLarge = await _acquireLargeSlot();
        cancel.check();
        if (currentAttempt() == null) return;
      }
      final cap = !large
          ? largeMediaBytes
          : automatic
          ? autoMediaMaxBytes
          : transcriptionSourceMaxBytes;
      final Object loader = transport;
      final AudioSource audio;
      try {
        audio = loader is BoundedAudioLoader
            ? await loader.loadAudioBounded(
                source,
                cancel,
                maxBytes: cap,
                requireDeclaredSize: false,
              )
            : await transport.loadAudio(source, cancel);
      } on WorkerFailure catch (e) {
        // An automatic small-capped download passed its cap: stopped before
        // any provider request; the user can still ask manually.
        if (automatic && !large && e.code == 'source_too_large') {
          throw const WorkerFailure('auto_skipped_size_cap');
        }
        rethrow;
      }
      cancel.check();
      if (currentAttempt() == null) return;
      // Identical media (a forward, the same clip in merged chats) reuses an
      // earlier transcript in the same language without a provider request.
      final mediaKey =
          '$mediaCheckpointPrefix${await mediaDigest(audio.bytes)}:'
          '${job['language'] ?? ''}';
      cancel.check();
      final reused = _reusableTranscript(mediaKey, id);
      final result =
          reused ??
          await transcriber.transcribe(
            audio,
            job['language'] as String?,
            cancel,
            (duration, cost) {
              final current = currentAttempt();
              if (current == null || cancel.cancelled) return;
              if (automatic) {
                // Measured locally, before any upload: limits throw here so
                // nothing reaches the provider and nothing is charged.
                final policy = autoPolicy();
                if (!autoTranscription || !policy.auto) {
                  throw const WorkerFailure('auto_disabled');
                }
                // The user may have switched this kind off while the job
                // was queued or downloading.
                final kind = _jobKind(current);
                if (kind != null && !policy.kindEnabled(kind)) {
                  throw const WorkerFailure('auto_skipped_kind');
                }
                if (duration > policy.maxSeconds) {
                  throw const WorkerFailure('auto_skipped_duration');
                }
                if (autoSpent(excluding: id) + cost > policy.dailyBudgetUsd) {
                  throw const WorkerFailure('auto_skipped_budget');
                }
                // Keep the estimate durable for budget accounting, but skip the
                // separate journal publication; the final result carries it.
                // From here on the provider may be paid (see [recover]).
                current['durationSeconds'] = duration;
                current['estimatedCostUsd'] = cost;
                current['providerAttemptAt'] = clock()
                    .toUtc()
                    .toIso8601String();
                store.saveJob(current);
                return;
              }
              current['durationSeconds'] = duration;
              current['estimatedCostUsd'] = cost;
              current['providerAttemptAt'] = clock().toUtc().toIso8601String();
              _setState(current, 'processing', null);
            },
          );
      cancel.check();
      if (currentAttempt() == null) return;
      final redacted = await _probeSource(source);
      cancel.check();
      final latest = currentAttempt();
      if (latest == null) return;
      if (redacted == true) {
        _invalidateSource(latest);
        return;
      }
      final values = <String, dynamic>{
        'text': result.text,
        'durationSeconds': result.durationSeconds,
        'estimatedCostUsd': result.estimatedCostUsd,
      };
      latest
        ..remove('retries')
        ..remove('waitingKeysSince')
        ..remove('providerAttemptAt');
      if (redacted == null) {
        latest['pendingResult'] = values;
        _parkOnSource(latest);
      } else {
        latest.addAll(values);
        _setState(latest, 'done', null);
        store.setCheckpoint(
          mediaKey,
          '$id ${clock().toUtc().millisecondsSinceEpoch}',
        );
      }
    } on WorkerFailure catch (e) {
      final current = currentAttempt();
      if (current == null) return;
      if (e.code == 'source_redacted') {
        _invalidateSource(current);
        return;
      }
      final retries = (current['retries'] as int? ?? 0) + 1;
      var code = e.code;
      if (code == 'waiting_keys') {
        final now = clock();
        final since =
            DateTime.tryParse(current['waitingKeysSince'] as String? ?? '') ??
            now;
        current['waitingKeysSince'] = since.toUtc().toIso8601String();
        if (now.difference(since) < keysWaitLimit) {
          // Nothing was charged: wait, then try again without busy-looping.
          current['retries'] = retries;
          current['retryAt'] = now
              .add(_backoff(retries))
              .toUtc()
              .toIso8601String();
          finish(current, 'waitingKeys', code);
          return;
        }
        // Waited a day: stop retrying. A later key for this room queues it
        // once more (retryWaitingKeys).
        code = 'keys_unavailable';
        current.remove('waitingKeysSince');
      } else if (transientRetryCodes.contains(code) &&
          retries <= transientRetryLimit) {
        // Nothing was charged: wait, then try again without busy-looping.
        current['retries'] = retries;
        current['retryAt'] = clock()
            .add(_backoff(retries))
            .toUtc()
            .toIso8601String();
        finish(current, 'queued', code);
        return;
      }
      current
        ..remove('retryAt')
        ..remove('providerAttemptAt');
      // What an automatic job's rules refuse (a video without sound, a
      // disappearing chat, limits) is dropped without an error on a message
      // the user never asked about; nothing was charged.
      final silentSkip = automatic && silentAutoRefusals.contains(code);
      _setState(
        current,
        e is PaidRequestUnknown
            ? 'unknown'
            : code == 'cancelled' || code.startsWith('auto_') || silentSkip
            ? 'cancelled'
            : 'failed',
        code,
      );
    } catch (_) {
      final current = currentAttempt();
      if (current != null) {
        current.remove('providerAttemptAt');
        _setState(current, 'failed', 'transcription_failed');
      }
    } finally {
      releaseLarge?.call();
      if (identical(_cancellations[id], cancel)) _cancellations.remove(id);
    }
  }

  static AutoTranscriptionKind? _jobKind(Map<String, dynamic> job) {
    final name = job['mediaKind'];
    for (final kind in AutoTranscriptionKind.values) {
      if (kind.name == name) return kind;
    }
    return null;
  }

  /// One large download at a time; returns the release callback.
  Future<void Function()> _acquireLargeSlot() async {
    final previous = _largeSlot;
    final released = Completer<void>();
    _largeSlot = released.future;
    await previous;
    var done = false;
    return () {
      if (done) return;
      done = true;
      released.complete();
    };
  }

  /// SHA-256 of the media. Large buffers are hashed in 1 MiB slices that
  /// yield to the event loop, so sync and journal work never stall for the
  /// seconds a 100 MB video takes (no isolate copy of the buffer either).
  static Future<String> mediaDigest(Uint8List bytes) async {
    const slice = 1 << 20;
    if (bytes.length <= 4 * slice) return sha256.convert(bytes).toString();
    late Digest digest;
    final input = sha256.startChunkedConversion(
      ChunkedConversionSink<Digest>.withCallback((d) => digest = d.single),
    );
    for (var offset = 0; offset < bytes.length; offset += slice) {
      final end = offset + slice < bytes.length ? offset + slice : bytes.length;
      input.add(Uint8List.sublistView(bytes, offset, end));
      await Future<void>.delayed(Duration.zero);
    }
    input.close();
    return digest.toString();
  }

  /// Dedupe entries older than this are forgotten (also when the job they
  /// point to is gone or lost its text), so plaintext-media fingerprints do
  /// not accumulate indefinitely.
  static const mediaDedupeTtl = Duration(days: 14);
  static const mediaCheckpointPrefix = 'media-transcript:';

  ({String id, DateTime at})? _mediaEntry(String? value) {
    if (value == null) return null;
    final space = value.lastIndexOf(' ');
    final at = space < 0 ? null : int.tryParse(value.substring(space + 1));
    if (at == null) return null;
    return (
      id: value.substring(0, space),
      at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
    );
  }

  bool _mediaEntryLive(({String id, DateTime at})? entry) {
    if (entry == null || clock().difference(entry.at) > mediaDedupeTtl) {
      return false;
    }
    final job = store.job(entry.id);
    final text = job?['text'];
    return job != null &&
        job['kind'] == 'transcript' &&
        job['state'] == 'done' &&
        text is String &&
        text.isNotEmpty;
  }

  /// Removes expired or stale dedupe entries; [jobId] also forgets that job's
  /// entries at once (source redacted). Returns how many were removed.
  int pruneMediaCheckpoints({String? jobId}) {
    var removed = 0;
    for (final entry
        in store.checkpointsWithPrefix(mediaCheckpointPrefix).entries) {
      final parsed = _mediaEntry(entry.value);
      if ((jobId != null && parsed?.id == jobId) || !_mediaEntryLive(parsed)) {
        store.deleteCheckpoint(entry.key);
        removed++;
      }
    }
    return removed;
  }

  /// An earlier finished transcript of byte-identical media, at no cost.
  TranscriptionResult? _reusableTranscript(String mediaKey, String id) {
    final entry = _mediaEntry(store.checkpoint(mediaKey));
    if (entry == null || entry.id == id) return null;
    if (!_mediaEntryLive(entry)) {
      store.deleteCheckpoint(mediaKey);
      return null;
    }
    final job = store.job(entry.id)!;
    final text = job['text'] as String;
    final duration = job['durationSeconds'];
    return TranscriptionResult(
      text,
      duration is num ? duration.toDouble() : 0,
      0,
    );
  }

  /// Declared media facts; null when the transport has none, fails or is
  /// slow (the job then proceeds; an automatic one runs under the small
  /// hard cap).
  Future<MediaFacts?> _mediaFacts(SourceEventRef source) async {
    final Object preflight = transport;
    if (preflight is! MediaPreflight) return null;
    try {
      return await preflight
          .mediaFacts(source)
          .timeout(const Duration(seconds: 6));
    } catch (_) {
      return null;
    }
  }

  /// Why an automatic job is skipped before download, or null to proceed.
  /// Unknown facts never skip: the download is then hard-capped instead.
  String? _autoSkip(MediaFacts? facts) {
    if (facts == null) return null;
    final policy = autoPolicy();
    final kind = facts.kind;
    if (kind != null && !policy.kindEnabled(kind)) return 'auto_skipped_kind';
    final duration = facts.durationMs;
    if (duration != null && duration > policy.maxSeconds * 1000) {
      return 'auto_skipped_duration';
    }
    final size = facts.sizeBytes;
    if (size != null && size > autoMediaMaxBytes) return 'auto_skipped_size';
    return null;
  }

  /// Current synced policy. Absent or deleted = defaults (automatic on);
  /// unreadable = disabled.
  TranscriptionPolicy autoPolicy() {
    final stored = store.metadata(transcriptionPolicyEntity);
    if (stored == null || stored['deleted'] == true) {
      return TranscriptionPolicy.defaults;
    }
    return TranscriptionPolicy.fromValue(stored['value']);
  }

  /// Estimated cost of automatic jobs created within the rolling window,
  /// including uncertain paid attempts.
  double autoSpent({String? excluding}) => store.autoSpentSince(
    clock().subtract(autoBudgetWindow),
    excluding: excluding,
  );

  Map<String, dynamic>? _metadataValue(String id) {
    final stored = store.metadata(id);
    final value = stored == null || stored['deleted'] == true
        ? null
        : stored['value'];
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  /// Creates automatic jobs for newly received incoming speech media: the
  /// worker's own Matrix sync feed (drained on every call, no delay) and the
  /// local index scan (every [autoScanInterval]). A no-op unless the
  /// operator switch is on. The first local scan (or the first after the
  /// policy was off) only records the current position: no history; the
  /// live feed likewise starts its window when it is first activated.
  Future<int> autoScan({bool force = false}) async {
    if (!autoTranscription || _autoScanBusy) return 0;
    _autoScanBusy = true;
    try {
      var created = await _scanLive();
      final scanner = recentSources;
      final now = clock();
      if (scanner != null &&
          (force ||
              _autoScanAt == null ||
              now.difference(_autoScanAt!) >= autoScanInterval)) {
        _autoScanAt = now;
        created += await _scanLocal(scanner, now);
      }
      return created;
    } finally {
      _autoScanBusy = false;
    }
  }

  Future<int> _scanLive() async {
    final feed = liveSources;
    if (feed == null) return 0;
    final policy = autoPolicy();
    feed.active = policy.auto;
    if (!policy.auto) {
      if (store.checkpoint(autoLiveCheckpoint)?.isNotEmpty ?? false) {
        store.setCheckpoint(autoLiveCheckpoint, '');
      }
      await feed.drain();
      return 0;
    }
    var since = DateTime.tryParse(store.checkpoint(autoLiveCheckpoint) ?? '');
    if (since == null) {
      since = clock().toUtc();
      store.setCheckpoint(autoLiveCheckpoint, since.toIso8601String());
    }
    final List<RecentSourceItem> items;
    try {
      items = await feed.drain();
    } catch (_) {
      return 0;
    }
    if (items.isEmpty) return 0;
    // The journal may have changed the policy while the feed was drained.
    final current = autoPolicy();
    if (!current.auto) return 0;
    var created = 0;
    store.transaction(() {
      created = _createAutoJobs(items, current, clock(), notBefore: since);
    });
    return created;
  }

  Future<int> _scanLocal(RecentSourceScanner scanner, DateTime now) async {
    final policy = autoPolicy();
    final stored = store.checkpoint(autoScanCheckpoint);
    final cursor = stored == null || stored.isEmpty
        ? null
        : int.tryParse(stored);
    if (!policy.auto) {
      if (stored != null && stored.isNotEmpty) {
        store.setCheckpoint(autoScanCheckpoint, '');
      }
      return 0;
    }
    final windowStart = now.subtract(autoTranscriptionMaxAge);
    final enabledAt = policy.enabledAt;
    final RecentSourcePage? page;
    try {
      page = await scanner.recent(
        cursor: cursor,
        since: enabledAt != null && enabledAt.isAfter(windowStart)
            ? enabledAt
            : windowStart,
        limit: autoScanPageLimit,
        // Reels (on demand by default) are only listed when wanted.
        reels: policy.kindEnabled(AutoTranscriptionKind.reel),
      );
    } catch (_) {
      // Source unavailable or malformed: keep the cursor, retry later, and
      // never let an optional scan defer journal flush or paid jobs.
      return 0;
    }
    if (page == null) return 0;
    final scanned = page;
    // The journal may have changed the policy while the scan was running.
    final current = autoPolicy();
    if (!current.auto) return 0;
    var created = 0;
    store.transaction(() {
      created = _createAutoJobs(scanned.items, current, now);
      store.setCheckpoint(autoScanCheckpoint, '${scanned.cursor}');
    });
    // A full page means more rows are waiting: scan again without delay.
    if (scanned.items.length >= autoScanPageLimit) _autoScanAt = null;
    return created;
  }

  /// Inside a store transaction: one job per eligible item without a job.
  int _createAutoJobs(
    List<RecentSourceItem> items,
    TranscriptionPolicy current,
    DateTime now, {
    DateTime? notBefore,
  }) {
    var created = 0;
    final groups = _personGroupsByRoom();
    final spent = autoSpent();
    for (final item in items) {
      final timestamp = item.timestamp;
      if (notBefore != null &&
          (timestamp == null || timestamp.isBefore(notBefore))) {
        continue;
      }
      final source = SourceEventRef(
        conversation: ConversationRef(
          accountId: transport.accountId,
          roomId: item.roomId,
          network: item.network,
        ),
        eventId: item.eventId,
      );
      final id = transcriptEntityId(source);
      // Any existing job wins: manual, earlier automatic or cancelled.
      if (store.job(id) != null) continue;
      final group = groups[item.roomId];
      final block = autoTranscriptionBlock(
        current,
        AutoTranscriptionCandidate(
          kind: item.kind,
          network: item.network,
          roomId: item.roomId,
          // The owner's own message (a bridge ghost): the policy's own-
          // message switch decides, not incoming rules.
          outgoing: item.outgoing,
          timestamp: timestamp,
          durationMs: item.durationMs,
          chatMetadata: _metadataValue('org:${item.roomId}'),
          personMetadata: group == null
              ? null
              : _metadataValue('org:person:$group'),
          networkMetadata: _metadataValue('network-policy:${item.network}'),
        ),
        now: now,
      );
      var skipped = switch (block) {
        null => null,
        'duration_limit' => 'auto_skipped_duration',
        'budget' => 'auto_skipped_budget',
        _ => '',
      };
      if (skipped == '') continue;
      if (skipped == null && spent >= current.dailyBudgetUsd) {
        skipped = 'auto_skipped_budget';
      }
      final body =
          Map<String, dynamic>.from(
            TranscriptionJob(
              id: id,
              source: source,
              state: skipped == null ? JobState.queued : JobState.cancelled,
              language: current.defaultLanguage,
              errorCode: skipped,
              origin: TranscriptionOrigin.auto,
            ).toJson(),
          )..addAll({
            'kind': 'transcript',
            'revision': 1,
            'acceptedOpId': stableId('auto', id),
            'createdAt': now.toUtc().toIso8601String(),
            'mediaKind': item.kind.name,
          });
      store.saveJob(body);
      // Published like any job so every device shows the state; a
      // skipped job explains why no transcript appeared.
      _result(body, 'auto');
      created++;
    }
    return created;
  }

  /// Room → merged person group, from synced `person:<id>` metadata.
  Map<String, String> _personGroupsByRoom() {
    final result = <String, String>{};
    for (final entry in store.metadataWithPrefix('person:').entries) {
      final value = entry.value;
      final members = value is Map ? value['members'] : null;
      if (members is! List) continue;
      for (final member in members) {
        final room = member is Map ? member['roomId'] : null;
        if (room is String) {
          result[room] = entry.key.substring('person:'.length);
        }
      }
    }
    return result;
  }

  void cancelAll() {
    for (final c in _cancellations.values) {
      c.cancel();
    }
  }

  Future<void> shutdown() async {
    cancelAll();
    await waitForIdle();
    await reminderChecksIdle();
  }

  Future<void> waitForIdle() async {
    while (_activeTranscripts.isNotEmpty) {
      await Future.wait(_activeTranscripts.values.toList());
    }
  }
}

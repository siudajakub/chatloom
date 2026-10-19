// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:personal_core/personal_core.dart';
import 'ports.dart';
import 'store.dart';

String stableId(String namespace, String id) =>
    '$namespace-${sha256.convert(utf8.encode(id))}';

class WorkerEngine {
  static const autoScanInterval = Duration(seconds: 10);
  static const autoScanPageLimit = 100;
  static const autoScanCheckpoint = 'auto-scan';
  static const autoBudgetWindow = Duration(hours: 24);
  final WorkerStore store;
  final FeatureTransport transport;
  final Transcriber transcriber;
  final DateTime Function() clock;

  /// Read-only scan of newly indexed local voice/round messages.
  final RecentSourceScanner? recentSources;

  /// Private operator switch (`autoTranscription` in the worker config).
  /// Off by default: the synced user policy alone never starts a scan.
  final bool autoTranscription;
  final Map<String, Cancellation> _cancellations = {};
  bool _running = false;
  bool _transcriptBusy = false;
  bool _sourceAuditBusy = false;
  DateTime? _sourceAuditAt;
  bool _autoScanBusy = false;
  DateTime? _autoScanAt;
  Future<void>? _activeTranscript;
  WorkerEngine(
    this.store,
    this.transport,
    this.transcriber, {
    DateTime Function()? clock,
    this.recentSources,
    this.autoTranscription = false,
  }) : clock = clock ?? DateTime.now;

  /// True when this worker creates automatic jobs itself.
  bool get autoScanActive => autoTranscription && recentSources != null;

  void recover() {
    store.transaction(() {
      for (final job in store.jobs()) {
        if (job['state'] != 'processing') continue;
        // Paid request outcomes cannot be inferred after a crash.
        job['state'] = job['kind'] == 'transcript' ? 'unknown' : 'queued';
        if (job['kind'] == 'transcript') {
          job['errorCode'] = 'paid_request_unknown';
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
    }..remove('pendingResult'),
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
      payload: Map<String, dynamic>.from(body)..remove('pendingResult'),
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
      // Schedules take priority over paid audio jobs; each is independently durable.
      for (final job in store.jobs().where((j) => j['kind'] == 'schedule')) {
        await _schedule(job);
      }
      for (final job in store.jobs().where(
        (j) =>
            j['kind'] == 'reminder' &&
            {'queued', 'waitingKeys', 'waitingSync'}.contains(j['state']),
      )) {
        if (job['nextReplyCheckAt'] is String &&
            clock().isBefore(
              DateTime.parse(job['nextReplyCheckAt'] as String),
            )) {
          continue;
        }
        if (job['untilReply'] == true) {
          final ref = ConversationRef.fromJson(
            Map<String, dynamic>.from(job['conversation'] as Map),
          );
          try {
            if (await transport.hasRepliedSince(
              ref,
              DateTime.parse(job['createdAt'] as String),
            )) {
              _setState(job, 'cancelled', 'replied');
              continue;
            }
          } on WorkerFailure catch (e) {
            _deferReminder(
              job,
              e.code == 'waiting_keys' ? 'waitingKeys' : 'waitingSync',
              e.code,
            );
            continue;
          } catch (_) {
            _deferReminder(job, 'waitingSync', 'history_unavailable');
            continue;
          }
          job.remove('nextReplyCheckAt');
          if (job['state'] != 'queued') _setState(job, 'queued', null);
        }
        if (!clock().isBefore(DateTime.parse(job['dueAt'] as String))) {
          job['due'] = true;
          _setState(job, 'done', null);
        }
      }
      if (!_transcriptBusy) {
        final candidates = store
            .jobs()
            .where(
              (j) =>
                  j['kind'] == 'transcript' &&
                  {'queued', 'waitingKeys'}.contains(j['state']),
            )
            .toList();
        if (candidates.isNotEmpty) {
          // Explicit requests never wait behind automatic background work.
          final next = candidates.firstWhere(
            (j) => j['origin'] != TranscriptionOrigin.auto.name,
            orElse: () => candidates.first,
          );
          _transcriptBusy = true;
          _activeTranscript = _transcript(
            next,
          ).whenComplete(() => _transcriptBusy = false);
          unawaited(_activeTranscript);
        }
      }
    } finally {
      _running = false;
    }
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

  void _deferReminder(Map<String, dynamic> job, String state, String code) {
    job['nextReplyCheckAt'] = clock()
        .add(const Duration(seconds: 30))
        .toUtc()
        .toIso8601String();
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

  /// Invoked after sync reconciliation; only explicit jobs, no history scan.
  Future<void> auditTranscriptSources({bool force = false}) async {
    if (_sourceAuditBusy ||
        (!force &&
            _sourceAuditAt != null &&
            clock().difference(_sourceAuditAt!) <
                const Duration(seconds: 30))) {
      return;
    }
    _sourceAuditBusy = true;
    _sourceAuditAt = clock();
    try {
      final jobs = store
          .jobs()
          .where(
            (job) =>
                job['kind'] == 'transcript' &&
                job['errorCode'] != 'source_redacted',
          )
          .toList();
      if (jobs.isEmpty) return;
      final cursor = store.checkpoint('source-audit');
      final prior = jobs.indexWhere((job) => job['id'] == cursor);
      for (var n = 0; n < jobs.length && n < 4; n++) {
        final snapshot = jobs[(prior + 1 + n) % jobs.length];
        final id = snapshot['id'] as String;
        final source = SourceEventRef.fromJson(
          Map<String, dynamic>.from(snapshot['source'] as Map),
        );
        final redacted = await _probeSource(source);
        final current = store.job(id);
        if (current != null &&
            current['source'].toString() == snapshot['source'].toString()) {
          if (redacted == true) {
            _invalidateSource(current);
          } else if (redacted == false &&
              current['state'] == 'waitingSync' &&
              current['pendingResult'] == null &&
              current['errorCode'] == 'source_status_unknown') {
            _setState(current, 'queued', null);
          } else if (redacted == false &&
              current['pendingResult'] is Map &&
              current['state'] == 'waitingSync') {
            final pending = Map<String, dynamic>.from(
              current.remove('pendingResult') as Map,
            );
            current.addAll(pending);
            _setState(current, 'done', null);
          }
        }
        store.setCheckpoint('source-audit', id);
      }
    } finally {
      _sourceAuditBusy = false;
    }
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
      _result(job, 'source_redacted');
    });
  }

  Future<void> _transcript(Map<String, dynamic> job) async {
    final id = job['id'] as String;
    final requestId = job['acceptedOpId'];
    final automatic = job['origin'] == TranscriptionOrigin.auto.name;
    // The user (policy) or the operator (switch, after a restart) may have
    // turned automatic transcription off while this job waited. Nothing has
    // been downloaded or paid for yet.
    if (automatic && (!autoTranscription || !autoPolicy().auto)) {
      _setState(job, 'cancelled', 'auto_disabled');
      return;
    }
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

    final cancel = _cancellations[id] = Cancellation();
    _setState(job, 'processing', null);
    try {
      final source = SourceEventRef.fromJson(
        Map<String, dynamic>.from(job['source'] as Map),
      );
      final initialStatus = await _probeSource(source);
      cancel.check();
      final initial = currentAttempt();
      if (initial == null) return;
      if (initialStatus == null) {
        _setState(initial, 'waitingSync', 'source_status_unknown');
        return;
      }
      if (initialStatus == true) {
        _invalidateSource(initial);
        return;
      }
      final audio = await transport.loadAudio(source, cancel);
      cancel.check();
      if (currentAttempt() == null) return;
      final result = await transcriber.transcribe(
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
            if (duration > policy.maxSeconds) {
              throw const WorkerFailure('auto_skipped_duration');
            }
            if (autoSpent(excluding: id) + cost > policy.dailyBudgetUsd) {
              throw const WorkerFailure('auto_skipped_budget');
            }
            // Keep the estimate durable for budget accounting, but skip the
            // separate journal publication; the final result carries it.
            current['durationSeconds'] = duration;
            current['estimatedCostUsd'] = cost;
            store.saveJob(current);
            return;
          }
          current['durationSeconds'] = duration;
          current['estimatedCostUsd'] = cost;
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
      if (redacted == null) {
        latest['pendingResult'] = values;
        _setState(latest, 'waitingSync', 'source_status_unknown');
      } else {
        latest.addAll(values);
        _setState(latest, 'done', null);
      }
    } on WorkerFailure catch (e) {
      final current = currentAttempt();
      if (current == null) return;
      if (e.code == 'source_redacted') {
        _invalidateSource(current);
        return;
      }
      _setState(
        current,
        e is PaidRequestUnknown
            ? 'unknown'
            : e.code == 'waiting_keys'
            ? 'waitingKeys'
            : e.code == 'cancelled' || e.code.startsWith('auto_')
            ? 'cancelled'
            : 'failed',
        e.code,
      );
    } catch (_) {
      final current = currentAttempt();
      if (current != null) {
        _setState(current, 'failed', 'transcription_failed');
      }
    } finally {
      if (identical(_cancellations[id], cancel)) _cancellations.remove(id);
    }
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
  double autoSpent({String? excluding}) {
    final from = clock().subtract(autoBudgetWindow);
    var total = 0.0;
    for (final job in store.jobs()) {
      if (job['kind'] != 'transcript' ||
          job['origin'] != TranscriptionOrigin.auto.name ||
          job['id'] == excluding) {
        continue;
      }
      final created = DateTime.tryParse(job['createdAt'] as String? ?? '');
      if (created == null || created.isBefore(from)) continue;
      final pending = job['pendingResult'];
      final cost =
          job['estimatedCostUsd'] ??
          (pending is Map ? pending['estimatedCostUsd'] : null);
      if (cost is num && cost.isFinite && cost > 0) total += cost;
    }
    return total;
  }

  Map<String, dynamic>? _metadataValue(String id) {
    final stored = store.metadata(id);
    final value = stored == null || stored['deleted'] == true
        ? null
        : stored['value'];
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  /// Creates automatic jobs for newly indexed incoming voice/round messages.
  /// Called from the daemon loop; a no-op unless the operator switch is on
  /// and a local source is configured. The first scan (or the first after
  /// the policy was off) only records the current position: no history.
  Future<int> autoScan({bool force = false}) async {
    final scanner = recentSources;
    if (!autoTranscription || scanner == null || _autoScanBusy) return 0;
    final now = clock();
    if (!force &&
        _autoScanAt != null &&
        now.difference(_autoScanAt!) < autoScanInterval) {
      return 0;
    }
    _autoScanBusy = true;
    _autoScanAt = now;
    try {
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
        final groups = _personGroupsByRoom();
        final spent = autoSpent();
        for (final item in scanned.items) {
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
              outgoing: false,
              timestamp: item.timestamp,
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
              });
          store.saveJob(body);
          // Published like any job so every device shows the state; a
          // skipped job explains why no transcript appeared.
          _result(body, 'auto');
          created++;
        }
        store.setCheckpoint(autoScanCheckpoint, '${scanned.cursor}');
      });
      return created;
    } finally {
      _autoScanBusy = false;
    }
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
    await _activeTranscript;
  }

  Future<void> waitForIdle() async {
    await _activeTranscript;
  }
}

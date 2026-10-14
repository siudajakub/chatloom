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
  final WorkerStore store;
  final FeatureTransport transport;
  final Transcriber transcriber;
  final DateTime Function() clock;
  final Map<String, Cancellation> _cancellations = {};
  bool _running = false;
  bool _transcriptBusy = false;
  bool _sourceAuditBusy = false;
  DateTime? _sourceAuditAt;
  Future<void>? _activeTranscript;
  WorkerEngine(
    this.store,
    this.transport,
    this.transcriber, {
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

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
        if (op.payload['id'] != op.entityId) {
          throw const WorkerFailure('invalid_reminder');
        }
        final body = Map<String, dynamic>.from(op.payload)
          ..addAll({
            'kind': 'reminder',
            'revision': 1,
            'state': 'queued',
            'acceptedOpId': op.opId,
            'dueAt': due.toIso8601String(),
            'createdAt': op.createdAt.toUtc().toIso8601String(),
          });
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
        final job = TranscriptionJob.fromJson(op.payload);
        _validateConversation(job.source.conversation);
        if (job.id != op.entityId || !job.source.eventId.startsWith(r'$')) {
          throw const WorkerFailure('invalid_source');
        }
        final body =
            Map<String, dynamic>.from(
              TranscriptionJob(
                id: job.id,
                source: job.source,
                state: JobState.queued,
                language: job.language,
              ).toJson(),
            )..addAll({
              'kind': 'transcript',
              'revision': revision + 1,
              'acceptedOpId': op.opId,
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
        final candidates = store.jobs().where(
          (j) =>
              j['kind'] == 'transcript' &&
              {'queued', 'waitingKeys'}.contains(j['state']),
        );
        if (candidates.isNotEmpty) {
          _transcriptBusy = true;
          _activeTranscript = _transcript(
            candidates.first,
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
            : e.code == 'cancelled'
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

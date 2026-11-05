// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'package:personal_core/personal_core.dart';
import 'engine.dart' show stableId;
import 'ports.dart';
import 'store.dart';

/// Explicit private drafts, serialised independently of incoming media jobs.
/// There is deliberately no FeatureTransport.send call or recipient field.
class DictationJobs {
  final WorkerStore store;
  final PrivateDictationSource? source;
  final Transcriber? transcriber;
  final DateTime Function() clock;
  final void Function() onChanged;
  final Map<String, Cancellation> _cancellations = {};
  Future<void>? _active;
  DictationJobs(
    this.store,
    this.source,
    this.transcriber, {
    required this.clock,
    required this.onChanged,
  });
  bool get configured => source != null && transcriber != null;
  static bool _terminal(Object? state) =>
      const {'done', 'cancelled', 'failed', 'unknown'}.contains(state);

  void recover() {
    store.transaction(() {
      for (final job in store.jobsWhere('dictation', ['processing'])) {
        final paid = job['providerAttemptAt'] != null;
        job['state'] = paid ? 'unknown' : 'queued';
        job['errorCode'] = paid ? 'paid_request_unknown' : null;
        job.remove('providerAttemptAt');
        store.saveJob(job);
        _publish(job, 'recovery');
      }
    });
  }

  void accept(PersonalOperation op) {
    final previous = store.job(op.entityId);
    final revision = previous?['revision'] as int? ?? 0;
    if (op.baseRevision != revision) {
      _reject(op, previous, 'conflict');
      return;
    }
    if (op.kind == 'dictation.cancel') {
      if (previous == null || previous['kind'] != 'dictation') {
        _reject(op, previous, 'not_found');
        return;
      }
      if (_terminal(previous['state'])) {
        _reject(op, previous, 'too_late');
        return;
      }
      _cancellations[op.entityId]?.cancel();
      previous['revision'] = revision + 1;
      previous['acceptedOpId'] = op.opId;
      previous['state'] = 'cancelled';
      previous.remove('text');
      previous.remove('providerAttemptAt');
      store.saveJob(previous);
      _publish(previous, op.opId);
      return;
    }
    if (previous != null) {
      _reject(op, previous, 'already_exists');
      return;
    }
    final input = op.payload;
    final event = input['eventId'];
    final duration = input['durationMs'];
    final size = input['sizeBytes'];
    if (!DictationLimits.validId(op.entityId) ||
        input['id'] != op.entityId ||
        event is! String ||
        !event.startsWith(r'$') ||
        event.length > 255 ||
        duration is! int ||
        duration < 1 ||
        duration > DictationLimits.maxDuration.inMilliseconds ||
        size is! int ||
        size < 1 ||
        size > DictationLimits.maxBytes ||
        input.keys.any(
          (key) =>
              !const {'id', 'eventId', 'durationMs', 'sizeBytes'}.contains(key),
        )) {
      throw const WorkerFailure('invalid_dictation_request');
    }
    final age = clock().difference(op.createdAt);
    final expired =
        age > DictationLimits.sourceLifetime ||
        age < const Duration(minutes: -1);
    final job = <String, dynamic>{
      'id': op.entityId,
      'kind': 'dictation',
      'revision': 1,
      'acceptedOpId': op.opId,
      'eventId': event,
      'createdAt': op.createdAt.toUtc().toIso8601String(),
      'state': configured && !expired ? 'queued' : 'failed',
      if (!configured) 'errorCode': 'dictation_not_configured',
      if (expired) 'errorCode': 'dictation_source_timeout',
    };
    store.saveJob(job);
    _publish(job, op.opId);
  }

  void tick() {
    if (_active != null) return;
    final queued = store.jobsWhere('dictation', ['queued']);
    if (queued.isEmpty) return;
    final job = queued.first;
    final created = DateTime.tryParse(job['createdAt'] as String? ?? '');
    if (created == null ||
        clock().difference(created) > DictationLimits.sourceLifetime) {
      _finish(job, 'failed', 'dictation_source_timeout');
      return;
    }
    final run = _run(job).then<void>((_) {}, onError: (_) {});
    _active = run;
    unawaited(
      run.whenComplete(() {
        if (identical(_active, run)) _active = null;
        onChanged();
      }),
    );
  }

  Future<void> _run(Map<String, dynamic> job) async {
    final id = job['id'] as String;
    final revision = job['revision'];
    final event = job['eventId'] as String;
    final cancel = Cancellation();
    _cancellations[id] = cancel;
    bool current() =>
        store.job(id)?['revision'] == revision &&
        !_terminal(store.job(id)?['state']);
    Future<void> checkSource() async {
      cancel.check();
      if (!current()) throw const WorkerFailure('cancelled');
      final redacted = await source!.dictationRedacted(event);
      cancel.check();
      if (redacted != false) {
        throw WorkerFailure(
          redacted == true ? 'source_redacted' : 'source_status_unknown',
        );
      }
    }

    try {
      if (!configured) throw const WorkerFailure('dictation_not_configured');
      job['state'] = 'processing';
      store.saveJob(job);
      _publish(job, 'processing');
      await checkSource();
      final audio = await source!.loadDictation(event, id, cancel);
      if (audio.bytes.isEmpty ||
          audio.bytes.length > DictationLimits.maxBytes) {
        throw const WorkerFailure('source_too_large');
      }
      await checkSource();
      final result = await transcriber!.transcribe(audio, null, cancel, (
        duration,
        cost,
      ) {
        cancel.check();
        if (!current()) throw const WorkerFailure('cancelled');
        if (!duration.isFinite ||
            duration <= 0 ||
            duration > DictationLimits.maxDuration.inSeconds) {
          throw const WorkerFailure('dictation_duration_limit');
        }
        if (!cost.isFinite || cost < 0) {
          throw const WorkerFailure('invalid_estimate');
        }
        final since = clock().subtract(const Duration(hours: 24));
        var spent = 0.0;
        for (final other in store.jobsWhere('dictation')) {
          if (other['id'] == id) continue;
          final reserved = DateTime.tryParse(
            other['budgetAt'] as String? ?? '',
          );
          if (reserved != null && !reserved.isBefore(since)) {
            spent += (other['estimatedCostUsd'] as num?)?.toDouble() ?? 0;
          }
        }
        if (spent + cost > DictationLimits.dailyBudgetUsd) {
          throw const WorkerFailure('dictation_daily_budget');
        }
        // Durable reservation before any provider upload. A crash cannot
        // silently replay a request that may already have been charged.
        job['providerAttemptAt'] = clock().toUtc().toIso8601String();
        job['budgetAt'] = job['providerAttemptAt'];
        job['estimatedCostUsd'] = cost;
        store.saveJob(job);
      });
      cancel.check();
      if (!current()) return;
      if (result.text.trim().isEmpty) {
        throw const WorkerFailure('empty_transcript');
      }
      // Reserve room for JSON escaping, Megolm and the event envelope.
      if (utf8.encode(jsonEncode(result.text)).length > 24000) {
        throw const WorkerFailure('dictation_text_limit');
      }
      await checkSource();
      if (!current()) return;
      job['text'] = result.text.trim();
      job['durationSeconds'] = result.durationSeconds;
      _finish(job, 'done', null);
    } on WorkerFailure catch (error) {
      if (!current()) return;
      _finish(
        job,
        error is PaidRequestUnknown
            ? 'unknown'
            : const {'cancelled', 'source_redacted'}.contains(error.code)
            ? 'cancelled'
            : 'failed',
        error.code,
      );
    } catch (_) {
      if (!current()) return;
      final paid =
          job['providerAttemptAt'] != null ||
          store.job(id)?['providerAttemptAt'] != null;
      _finish(
        job,
        paid ? 'unknown' : 'failed',
        paid ? 'paid_request_unknown' : 'transcription_failed',
      );
    } finally {
      _cancellations.remove(id);
    }
  }

  void _finish(Map<String, dynamic> job, String state, String? error) {
    store.transaction(() {
      job['state'] = state;
      job['errorCode'] = error;
      job.remove('providerAttemptAt');
      if (state != 'done') job.remove('text');
      store.saveJob(job);
      _publish(job, state);
    });
  }

  void _publish(Map<String, dynamic> job, String reason) {
    final operation = PersonalOperation(
      opId: stableId(
        'dictation-result',
        '${job['id']}:${job['revision']}:$reason',
      ),
      kind: 'dictation.result',
      entityId: job['id'] as String,
      baseRevision: job['revision'] as int,
      createdAt: clock(),
      payload: {
        for (final key in const [
          'id',
          'revision',
          'acceptedOpId',
          'state',
          'errorCode',
          'text',
          'durationSeconds',
          'estimatedCostUsd',
        ])
          if (job.containsKey(key)) key: job[key],
      },
    );
    store.enqueue(operation.opId, operation.toJson());
    onChanged();
  }

  void _reject(
    PersonalOperation op,
    Map<String, dynamic>? previous,
    String code,
  ) {
    final result = PersonalOperation(
      opId: stableId('dictation-reject', op.opId),
      kind: 'dictation.result',
      entityId: op.entityId,
      baseRevision: previous?['revision'] as int? ?? 0,
      createdAt: clock(),
      payload: {
        'id': op.entityId,
        'state': 'conflict',
        'actualState': previous?['state'],
        'errorCode': code,
        'revision': previous?['revision'] ?? 0,
        'acceptedOpId': op.opId,
      },
    );
    store.enqueue(result.opId, result.toJson());
  }

  void cancelAll() {
    for (final cancel in _cancellations.values) {
      cancel.cancel();
    }
  }

  Future<void> waitForIdle() async {
    await _active;
  }
}

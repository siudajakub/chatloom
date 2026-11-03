// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:personal_core/personal_core.dart';

import 'engine.dart' show stableId;
import 'ports.dart';
import 'store.dart';
import 'summary_provider.dart';

/// Runs explicitly requested summaries beside sync/transcription. Source chunks
/// stay in the encrypted store only while their job needs them; terminal
/// transitions publish metadata tombstones to clear every app's replica.
class SummaryJobs {
  final WorkerStore store;
  final String accountId;
  final ConversationSummarizer? summarizer;
  final DateTime Function() clock;
  final void Function() onChanged;
  final Map<String, Cancellation> _cancellations = {};
  Future<void>? _active;
  DateTime? _orphanAuditAt;
  static const _sourceCheckpoint = 'summary-source-expiry:';
  SummaryJobs(
    this.store,
    this.accountId,
    this.summarizer, {
    required this.clock,
    required this.onChanged,
  });

  bool get configured => summarizer?.configured == true;

  void recover() {
    store.transaction(() {
      for (final job in store.jobsWhere('summary', ['processing'])) {
        final paid = job['providerAttemptAt'] != null;
        job['state'] = paid ? 'unknown' : 'queued';
        job['errorCode'] = paid ? 'paid_request_unknown' : null;
        job.remove('providerAttemptAt');
        store.saveJob(job);
        if (paid) _clearSource(job);
        _publish(job, 'recovery');
      }
    });
  }

  static bool _terminal(Object? state) =>
      {'done', 'cancelled', 'failed', 'unknown'}.contains(state);

  /// Late/replayed input after cancellation must never resurrect its text.
  bool sourceAlreadyFinished(Map<String, dynamic> value) {
    final id = value['summaryId'];
    return id is String && _terminal(store.job(id)?['state']);
  }

  void accept(PersonalOperation op) {
    final previous = store.job(op.entityId);
    final revision = previous?['revision'] as int? ?? 0;
    if (op.baseRevision != revision) {
      _reject(op, previous, 'conflict');
      return;
    }
    if (op.kind == 'summary.cancel') {
      if (previous == null || previous['kind'] != 'summary') {
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
      previous.remove('providerAttemptAt');
      store.saveJob(previous);
      _clearSource(previous);
      _publish(previous, op.opId);
      return;
    }
    if (previous != null) {
      // No in-place retry of a paid job. An explicit retry gets a new id.
      _reject(op, previous, 'already_exists');
      return;
    }
    final input = op.payload;
    final id = input['id'];
    final count = input['partCount'];
    final bytes = input['sourceBytes'];
    final digest = input['sourceDigest'];
    if (id is! String ||
        id != op.entityId ||
        !validSummaryId(id) ||
        count is! int ||
        count < 1 ||
        count > SummaryUpload.maxParts ||
        bytes is! int ||
        bytes < 1 ||
        bytes > SummaryUpload.maxSourceBytes ||
        digest is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      throw const WorkerFailure('invalid_summary_request');
    }
    late ConversationRef conversation;
    late SummaryRequest request;
    try {
      conversation = ConversationRef.fromJson(
        Map<String, dynamic>.from(input['conversation'] as Map),
      );
      request = SummaryRequest.fromJson(
        Map<String, dynamic>.from(input['request'] as Map),
      );
    } catch (_) {
      throw const WorkerFailure('invalid_summary_request');
    }
    if (conversation.accountId != accountId ||
        !conversation.roomId.startsWith('!')) {
      throw const WorkerFailure('invalid_account_or_room');
    }
    final job = <String, dynamic>{
      'id': id,
      'kind': 'summary',
      'revision': 1,
      'state': configured ? 'queued' : 'failed',
      'acceptedOpId': op.opId,
      'createdAt': clock().toUtc().toIso8601String(),
      'request': request.toJson(),
      'partCount': count,
      'sourceBytes': bytes,
      'sourceDigest': digest,
      if (!configured) 'errorCode': 'summary_not_configured',
    };
    store.saveJob(job);
    if (!configured) _clearSource(job);
    _publish(job, op.opId);
  }

  void tick() {
    _expireOrphans();
    if (_active != null) return;
    for (final job in store.jobsWhere('summary', ['queued'])) {
      final id = job['id'] as String;
      final createdAt = DateTime.tryParse(job['createdAt'] as String? ?? '');
      if (createdAt == null ||
          clock().difference(createdAt) > const Duration(minutes: 15)) {
        _finish(job, 'failed', 'summary_source_timeout');
        continue;
      }
      final parts = <String>[];
      var missing = false;
      var invalid = false;
      for (var i = 0; i < (job['partCount'] as int); i++) {
        final stored = store.metadata(SummaryUpload.summaryPartEntity(id, i));
        final value = stored?['deleted'] == true ? null : stored?['value'];
        if (value == null) {
          missing = true;
          break;
        }
        if (value is! Map ||
            value['summaryId'] != id ||
            value['index'] != i ||
            value['count'] != job['partCount'] ||
            value['sha256'] != job['sourceDigest'] ||
            value['text'] is! String ||
            utf8.encode(value['text'] as String).length >
                SummaryUpload.partBytes) {
          invalid = true;
          break;
        }
        parts.add(value['text'] as String);
      }
      if (invalid) {
        _finish(job, 'failed', 'invalid_summary_source');
        continue;
      }
      if (missing) continue;
      final encoded = parts.join();
      final bytes = utf8.encode(encoded);
      if (bytes.length != job['sourceBytes'] ||
          bytes.length > SummaryUpload.maxSourceBytes ||
          sha256Hex(bytes) != job['sourceDigest']) {
        _finish(job, 'failed', 'invalid_summary_source');
        continue;
      }
      late SummarySource source;
      try {
        source = SummarySource.fromJson(
          Map<String, dynamic>.from(jsonDecode(encoded) as Map),
        );
        // The client must make incomplete coverage explicit before upload.
        if (!source.complete && (source.coverageNote?.trim().isEmpty ?? true)) {
          throw const SummaryException('history_incomplete');
        }
      } catch (_) {
        _finish(job, 'failed', 'invalid_summary_source');
        continue;
      }
      final run = _run(job, source).then<void>((_) {}, onError: (_) {});
      _active = run;
      unawaited(
        run.whenComplete(() {
          if (identical(_active, run)) _active = null;
          onChanged();
        }),
      );
      break;
    }
  }

  Future<void> _run(Map<String, dynamic> job, SummarySource source) async {
    final id = job['id'] as String;
    final revision = job['revision'];
    final cancel = Cancellation();
    _cancellations[id] = cancel;
    bool current() {
      final latest = store.job(id);
      return latest?['revision'] == revision && !_terminal(latest?['state']);
    }

    try {
      job['state'] = 'processing';
      store.saveJob(job);
      _publish(job, 'processing');
      final provider = summarizer;
      if (provider == null || !provider.configured) {
        throw const WorkerFailure('summary_not_configured');
      }
      final result = await provider.summarize(
        SummaryRequest.fromJson(
          Map<String, dynamic>.from(job['request'] as Map),
        ),
        source,
        cancel,
        (cost) {
          cancel.check();
          if (!current()) throw const WorkerFailure('cancelled');
          job['providerAttemptAt'] = clock().toUtc().toIso8601String();
          job['estimatedCostUsd'] = cost;
          store.saveJob(job);
        },
      );
      cancel.check();
      if (!current()) return;
      job.addAll(result.toJson());
      _finish(job, 'done', null);
    } on WorkerFailure catch (error) {
      if (!current()) return;
      _finish(
        job,
        error is PaidRequestUnknown
            ? 'unknown'
            : error.code == 'cancelled'
            ? 'cancelled'
            : 'failed',
        error.code,
      );
    } catch (_) {
      if (!current()) return;
      // A failed final transaction may have removed the marker from this
      // mutable copy while SQLite rolled back to the paid processing row.
      final paid =
          job['providerAttemptAt'] != null ||
          store.job(id)?['providerAttemptAt'] != null;
      _finish(
        job,
        paid ? 'unknown' : 'failed',
        paid ? 'paid_request_unknown' : 'summary_failed',
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
      store.saveJob(job);
      _clearSource(job);
      _publish(job, state);
    });
    onChanged();
  }

  void noteSource(Map<String, dynamic> value) {
    final id = value['summaryId'] as String;
    final key = '$_sourceCheckpoint$id';
    if (store.checkpoint(key) != null) return;
    store.setCheckpoint(
      key,
      jsonEncode({
        'at': clock().toUtc().toIso8601String(),
        'count': value['count'],
      }),
    );
  }

  void _expireOrphans() {
    if (_orphanAuditAt != null &&
        clock().difference(_orphanAuditAt!) < const Duration(minutes: 1)) {
      return;
    }
    _orphanAuditAt = clock();
    for (final entry
        in store.checkpointsWithPrefix(_sourceCheckpoint).entries) {
      final id = entry.key.substring(_sourceCheckpoint.length);
      if (store.job(id) != null) continue;
      try {
        final record = jsonDecode(entry.value) as Map;
        final at = DateTime.parse(record['at'] as String);
        if (clock().difference(at) < const Duration(minutes: 15)) continue;
        store.transaction(
          () => _clearSource({'id': id, 'partCount': record['count']}),
        );
      } catch (_) {
        // Keep malformed checkpoint evidence; never infer that source is safe
        // to upload from an unreadable record.
      }
    }
  }

  void _clearSource(Map<String, dynamic> job) {
    final id = job['id'] as String;
    store.clearSummarySourceCopies(id);
    store.deleteCheckpoint('$_sourceCheckpoint$id');
    final count = job['partCount'] as int? ?? 0;
    for (var i = 0; i < count && i < SummaryUpload.maxParts; i++) {
      final entity = SummaryUpload.summaryPartEntity(id, i);
      final old = store.metadata(entity);
      if (old?['deleted'] == true) continue;
      final revision = (old?['revision'] as int? ?? 0) + 1;
      store.saveMetadata(entity, revision, true, null);
      final operation = PersonalOperation(
        opId: stableId('summary-clear', '$entity:$revision'),
        kind: 'metadata.result',
        entityId: entity,
        baseRevision: revision,
        createdAt: clock(),
        payload: {
          'state': 'done',
          'deleted': true,
          'value': null,
          'revision': revision,
        },
      );
      store.enqueue(operation.opId, operation.toJson());
    }
  }

  void _publish(Map<String, dynamic> job, String cause) {
    // Only an allowlist may cross back into the private journal. This avoids
    // copying source input or durable paid-request markers into every result.
    final payload = <String, dynamic>{
      for (final key in [
        'id',
        'kind',
        'revision',
        'state',
        'acceptedOpId',
        'errorCode',
        'text',
        'model',
        'messageCount',
        'startedAt',
        'endedAt',
        'complete',
        'estimatedCostUsd',
        'coverageNote',
      ])
        if (job.containsKey(key)) key: job[key],
    };
    final operation = PersonalOperation(
      opId: stableId(
        'summary-state',
        '${job['id']}:${job['revision']}:${job['state']}:$cause',
      ),
      kind: 'summary.result',
      entityId: job['id'] as String,
      baseRevision: job['revision'] as int,
      createdAt: clock(),
      payload: payload,
    );
    store.enqueue(operation.opId, operation.toJson());
  }

  void _reject(PersonalOperation op, Map<String, dynamic>? old, String code) {
    final result = PersonalOperation(
      opId: stableId('result', op.opId),
      kind: 'summary.result',
      entityId: op.entityId,
      baseRevision: old?['revision'] as int? ?? 0,
      createdAt: clock(),
      payload: {
        'state': 'conflict',
        'actualState': old?['state'],
        'errorCode': code,
        'revision': old?['revision'] ?? 0,
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

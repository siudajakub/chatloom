// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'contracts.dart';

typedef ReplicaRead = Future<Map<String, dynamic>?> Function(String key);
typedef ReplicaWrite =
    Future<void> Function(String key, Map<String, dynamic> value);

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
Object? _ordered(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _ordered(value[key])};
  }
  return value is List ? value.map(_ordered).toList() : value;
}

bool _same(Object? a, Object? b) =>
    jsonEncode(_ordered(a)) == jsonEncode(_ordered(b));

enum TranscriptCancellation {
  cancelledLocally,
  waitingAcknowledgement,
  queued,
  alreadyFinished,
}

/// A durable per-entity replica. Its single-record commits contain optimistic
/// state, revisions, conflict copies and outbox entries together. Network
/// publication happens outside its serialized mutation queue.
class PersonalReplica {
  final ReplicaRead read;
  final ReplicaWrite write;
  final String Function() newOperationId;
  final DateTime Function() clock;
  final void Function()? onChanged;
  final values = <String, Map<String, dynamic>>{};
  final revisions = <String, int>{};
  final conflicts = <String, Map<String, dynamic>>{};
  final transcripts = <String, TranscriptionJob>{};
  final schedules = <String, Map<String, dynamic>>{};
  final reminders = <String, Map<String, dynamic>>{};
  final pending = <String, PersonalOperation>{};
  final transcriptCancellations = <String>{};
  final _records = <String, Map<String, dynamic>>{};
  final _seen = <String>{};
  Future<void> _tail = Future.value();
  bool get hasUnattemptedCommands => pending.values.any(
    (op) => !((_records[op.entityId]?['attempted'] as List? ?? const [])
        .contains(op.opId)),
  );

  PersonalReplica({
    required this.read,
    required this.write,
    required this.newOperationId,
    required this.clock,
    this.onChanged,
  });

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  void restore(Map<String, Map<String, dynamic>> records) {
    for (final entry in records.entries.where(
      (e) => e.key.startsWith('replica:'),
    )) {
      final entity = entry.key.substring(8);
      _records[entity] = _copy(entry.value);
      _expose(entity, _records[entity]!);
    }
  }

  Map<String, dynamic> _record(String entity) => _copy(
    _records[entity] ??
        {
          'revision': 0,
          'generation': 0,
          'commands': <String, dynamic>{},
          'attempted': <String>[],
          'appliedResults': <String>[],
        },
  );

  Future<void> _commit(String entity, Map<String, dynamic> record) async {
    await write('replica:$entity', record);
    _records[entity] = _copy(record);
    _expose(entity, record);
    onChanged?.call();
  }

  void _expose(String entity, Map<String, dynamic> record) {
    if (record['transcriptCancellationRequested'] == true) {
      transcriptCancellations.add(entity);
    } else {
      transcriptCancellations.remove(entity);
    }
    revisions[entity] = record['revision'] as int? ?? 0;
    final value = record['localValue'] ?? record['serverValue'];
    if (value is Map) {
      values[entity] = Map<String, dynamic>.from(value);
    } else {
      values.remove(entity);
    }
    final preserved = record['preservedDrafts'];
    if (preserved is Map) {
      for (final entry in preserved.entries) {
        if (entry.value is Map)
          values['draft-copy:${entry.key}'] = Map<String, dynamic>.from(
            entry.value as Map,
          );
      }
    }
    final conflict = record['conflict'];
    if (conflict is Map) {
      conflicts[entity] = Map<String, dynamic>.from(conflict);
    } else {
      conflicts.remove(entity);
    }
    pending.removeWhere((_, op) => op.entityId == entity);
    final commands = record['commands'] as Map? ?? {};
    for (final value in commands.values) {
      final op = PersonalOperation.fromJson(
        Map<String, dynamic>.from(value as Map),
      );
      pending[op.opId] = op;
    }
    final job = record['job'];
    if (job is Map) {
      final data = Map<String, dynamic>.from(job);
      switch (record['jobKind']) {
        case 'transcript':
          // Rejections for an absent job may lack a source. Keep the local
          // placeholder/source, retaining the error and authoritative revision.
          final source = data['source'] ?? transcripts[entity]?.source.toJson();
          if (source != null) {
            transcripts[entity] = TranscriptionJob.fromJson({
              ...data,
              'id': entity,
              'source': source,
            });
          }
        case 'schedule':
          schedules[entity] = data;
        case 'reminder':
          reminders[entity] = data;
      }
    }
  }

  PersonalOperation _operation(
    String kind,
    String entity,
    Map<String, dynamic> payload,
    int revision, {
    String? id,
  }) => PersonalOperation(
    opId: id ?? newOperationId(),
    kind: kind,
    entityId: entity,
    baseRevision: revision,
    createdAt: clock(),
    payload: _copy(payload),
  );

  void _add(Map<String, dynamic> record, PersonalOperation op) {
    final commands = Map<String, dynamic>.from(
      record['commands'] as Map? ?? {},
    );
    commands[op.opId] = op.toJson();
    record['commands'] = commands;
  }

  Future<void> queueMetadata(String entity, Map<String, dynamic> value) =>
      _serial(() async {
        final record = _record(entity);
        record['localValue'] = _copy(value);
        record['generation'] = (record['generation'] as int? ?? 0) + 1;
        final inflight = record['metadataInFlight'] as String?;
        final attempted = (record['attempted'] as List? ?? []).cast<String>();
        if (record['conflict'] == null) {
          if (inflight == null || !attempted.contains(inflight)) {
            final op = _operation(
              'metadata.put',
              entity,
              {'value': value},
              record['revision'] as int,
              id: inflight,
            );
            _add(record, op);
            record['metadataInFlight'] = op.opId;
            record['metadataCommandGeneration'] = record['generation'];
          }
        }
        await _commit(entity, record);
      });

  Future<PersonalOperation> stageCommand(
    String kind,
    String entity,
    Map<String, dynamic> payload, {
    int? baseRevision,
    Map<String, dynamic>? optimisticJob,
  }) => _serial(() async {
    final record = _record(entity);
    if (!kind.startsWith('metadata.')) {
      final queued = (record['commands'] as Map? ?? {}).values
          .map(
            (value) => PersonalOperation.fromJson(
              Map<String, dynamic>.from(value as Map),
            ),
          )
          .toList();
      for (final existing in queued) {
        if (existing.kind == kind && _same(existing.payload, payload))
          return existing;
      }
      if (queued.any(
        (existing) => existing.kind.split('.').first == kind.split('.').first,
      )) {
        throw StateError(
          'Wait for the job acknowledgement before another action',
        );
      }
    }
    final op = _operation(
      kind,
      entity,
      payload,
      baseRevision ?? record['revision'] as int,
    );
    if (kind.startsWith('metadata.')) {
      if (record['metadataInFlight'] != null)
        throw StateError('Metadata already awaiting acknowledgement');
      if (entity.startsWith('draft:') && record['conflict'] is Map) {
        final conflict = record['conflict'] as Map;
        final preserved = Map<String, dynamic>.from(
          record['preservedDrafts'] as Map? ?? {},
        );
        for (final candidate in [
          record['localValue'],
          conflict['existingValue'],
          conflict['proposedValue'],
        ]) {
          if (candidate is! Map) continue;
          final value = Map<String, dynamic>.from(candidate);
          if (!preserved.values.any(
            (copy) => copy is Map && _same(copy['originalValue'], value),
          )) {
            preserved[newOperationId()] = {
              ..._copy(value),
              'originalValue': _copy(value),
              'sourceEntity': entity,
              'savedAt': clock().toUtc().toIso8601String(),
            };
          }
        }
        record['preservedDrafts'] = preserved;
      }
      record['metadataInFlight'] = op.opId;
      record['generation'] = (record['generation'] as int? ?? 0) + 1;
      record['metadataCommandGeneration'] = record['generation'];
      if (kind == 'metadata.put')
        record['localValue'] = _copy(
          Map<String, dynamic>.from(payload['value'] as Map),
        );
    }
    if (optimisticJob != null) {
      record['jobKind'] = kind.split('.').first;
      record['job'] = {..._copy(optimisticJob), 'revision': record['revision']};
    }
    _add(record, op);
    await _commit(entity, record);
    return op;
  });

  /// Mark publication before sending: an ambiguous timeout cannot turn a sent
  /// command back into a mutable coalescing slot.
  Future<PersonalOperation?> markPublishing(String opId) => _serial(() async {
    final op = pending[opId];
    if (op == null) return null;
    final record = _record(op.entityId);
    if ((record['attempted'] as List? ?? []).contains(opId)) return op;
    final attempted =
        (record['attempted'] as List? ?? []).cast<String>().toSet()..add(opId);
    record['attempted'] = attempted.toList();
    await _commit(op.entityId, record);
    return pending[opId];
  });

  /// Cancellation shares the publication lock. Only a request which has never
  /// started publication can be withdrawn locally. Otherwise the cancellation
  /// intent survives restart and awaits the authoritative revision/ACK.
  Future<TranscriptCancellation> cancelTranscript(
    String entity,
  ) => _serial(() async {
    final record = _record(entity);
    if (record['jobKind'] != 'transcript' || record['job'] is! Map) {
      throw StateError('Transcription is unavailable');
    }
    final commands = Map<String, dynamic>.from(
      record['commands'] as Map? ?? {},
    );
    final transcriptCommands = commands.values
        .map(
          (value) => PersonalOperation.fromJson(
            Map<String, dynamic>.from(value as Map),
          ),
        )
        .where((op) => op.kind.startsWith('transcript.'))
        .toList();
    final attempted = record['attempted'] as List? ?? const [];
    final unattemptedRequests = transcriptCommands
        .where(
          (op) =>
              op.kind == 'transcript.request' && !attempted.contains(op.opId),
        )
        .toList();
    if (unattemptedRequests.isNotEmpty &&
        transcriptCommands.length == unattemptedRequests.length) {
      for (final request in unattemptedRequests) {
        commands.remove(request.opId);
      }
      record['commands'] = commands;
      final onlyLocal =
          (record['job'] as Map)['state'] == 'waitingSync' &&
          unattemptedRequests.every(
            (request) => request.baseRevision == record['revision'],
          );
      if (onlyLocal) {
        record['job'] = {
          ...Map<String, dynamic>.from(record['job'] as Map),
          'state': 'cancelled',
        };
        record.remove('transcriptCancellationRequested');
        await _commit(entity, record);
        return TranscriptCancellation.cancelledLocally;
      }
      // Another trusted device may have started the same source job. Withdraw
      // our untouched request, but retain the real state and cancel remotely.
      transcriptCommands.clear();
    }
    if (_transcriptFinished(record)) {
      await _commit(entity, record);
      return TranscriptCancellation.alreadyFinished;
    }
    record['transcriptCancellationRequested'] = true;
    _queueTranscriptCancellation(entity, record);
    await _commit(entity, record);
    return transcriptCommands.isEmpty ||
            transcriptCommands.any((op) => op.kind == 'transcript.cancel')
        ? TranscriptCancellation.queued
        : TranscriptCancellation.waitingAcknowledgement;
  });

  bool _transcriptFinished(Map<String, dynamic> record) => {
    'done',
    'cancelled',
    'failed',
    'unknown',
  }.contains((record['job'] as Map?)?['state']);

  void _queueTranscriptCancellation(
    String entity,
    Map<String, dynamic> record,
  ) {
    if (record['transcriptCancellationRequested'] != true) return;
    if (_transcriptFinished(record)) {
      record.remove('transcriptCancellationRequested');
      return;
    }
    final commands = record['commands'] as Map? ?? {};
    if (commands.values.any(
      (value) =>
          value is Map &&
          (value['kind'] as String? ?? '').startsWith('transcript.'),
    ))
      return;
    _add(
      record,
      _operation('transcript.cancel', entity, {
        'id': entity,
      }, record['revision'] as int),
    );
  }

  Future<void> acceptResult(PersonalOperation result) => _serial(() async {
    final seenKey = 'seen:${result.opId}';
    if (_seen.contains(result.opId)) return;
    if (await read(seenKey) != null) {
      _seen.add(result.opId);
      return;
    }
    final entity = result.entityId;
    final record = _record(entity);
    final applied = (record['appliedResults'] as List? ?? []).cast<String>();
    if (applied.contains(result.opId)) {
      await write(seenKey, {'seen': true});
      _seen.add(result.opId);
      return;
    }
    final payload = result.payload;
    final revision = payload['revision'] as int? ?? result.baseRevision;
    final accepted = payload['acceptedOpId'] as String?;
    final commands = Map<String, dynamic>.from(
      record['commands'] as Map? ?? {},
    );
    final acknowledged = accepted == null || commands[accepted] is! Map
        ? null
        : PersonalOperation.fromJson(
            Map<String, dynamic>.from(commands[accepted] as Map),
          );
    final commandGeneration = record['metadataCommandGeneration'];
    if (accepted != null) commands.remove(accepted);
    record['commands'] = commands;
    record['attempted'] = (record['attempted'] as List? ?? [])
        .where((id) => id != accepted)
        .toList();
    if (record['metadataInFlight'] == accepted)
      record.remove('metadataInFlight');
    final latest = revision >= (record['revision'] as int);
    if (latest) {
      record['revision'] = revision;
      if (result.kind == 'metadata.result') {
        if (payload['state'] == 'conflict') {
          record['conflict'] = _copy(payload);
          final existing = payload['existingValue'];
          if (existing is Map)
            record['serverValue'] = _copy(Map<String, dynamic>.from(existing));
        } else {
          if (payload['deleted'] == true)
            record.remove('serverValue');
          else if (payload['value'] is Map)
            record['serverValue'] = _copy(
              Map<String, dynamic>.from(payload['value'] as Map),
            );
          // A foreign update cannot erase a local unacknowledged draft.
          if (acknowledged != null) {
            final sent = acknowledged.payload['value'];
            if ((acknowledged.kind == 'metadata.delete' &&
                    record['generation'] == commandGeneration) ||
                _same(sent, record['localValue']))
              record.remove('localValue');
            record.remove('conflict');
          }
        }
        if (record['localValue'] is Map &&
            record['conflict'] == null &&
            record['metadataInFlight'] == null &&
            acknowledged != null) {
          final op = _operation('metadata.put', entity, {
            'value': record['localValue'],
          }, revision);
          _add(record, op);
          record['metadataInFlight'] = op.opId;
          record['metadataCommandGeneration'] = record['generation'];
        }
      } else if ({
        'transcript.result',
        'schedule.result',
        'reminder.result',
      }.contains(result.kind)) {
        final previous = record['job'] as Map? ?? {};
        record['jobKind'] = result.kind.split('.').first;
        if (payload['state'] == 'conflict') {
          record['conflict'] = _copy(payload);
          record['job'] = {
            ...previous,
            ..._copy(payload),
            'state':
                payload['actualState'] ??
                (result.kind == 'transcript.result'
                    ? 'failed'
                    : previous['state'] ?? 'failed'),
          };
        } else {
          record['job'] = {...previous, ..._copy(payload)};
          record.remove('conflict');
        }
      }
    } else if (result.kind == 'metadata.result' &&
        acknowledged != null &&
        payload['state'] != 'conflict') {
      if (_same(acknowledged.payload['value'], record['localValue'])) {
        record.remove('localValue');
      } else if (record['localValue'] is Map) {
        record['conflict'] = {
          'state': 'conflict',
          'revision': record['revision'],
          'existingValue': record['serverValue'],
          'proposedValue': record['localValue'],
        };
      }
    }
    if (result.kind == 'transcript.result') {
      if (payload['state'] == 'conflict' &&
          payload['errorCode'] != 'conflict' &&
          acknowledged?.kind == 'transcript.cancel') {
        // A rejected cancellation (for example not_found) must never create
        // an endless chain of new opIds. The authoritative error is preserved.
        record.remove('transcriptCancellationRequested');
      }
      // A conflict ACK can report a newer processing revision. Requeue only
      // cancellation (never another paid request) at that durable revision.
      _queueTranscriptCancellation(entity, record);
    }
    record['appliedResults'] = [
      ...applied.skip(applied.length > 31 ? applied.length - 31 : 0),
      result.opId,
    ];
    // Commit the result and conflict copies BEFORE its seen marker, including
    // outbox removal/next-coalesced operation in the same durable record.
    await _commit(entity, record);
    await write(seenKey, {'seen': true});
    _seen.add(result.opId);
  });

  /// Migration from older split records. Nothing is published during migration.
  Future<void> importLegacy(
    String entity, {
    Map<String, dynamic>? value,
    int revision = 0,
    Map<String, dynamic>? job,
    String? jobKind,
    Iterable<PersonalOperation> pendingOperations = const [],
    Map<String, dynamic>? conflict,
  }) => _serial(() async {
    if (_records.containsKey(entity)) return;
    final record = _record(entity)..['revision'] = revision;
    if (value != null) record['serverValue'] = _copy(value);
    if (job != null) {
      record['job'] = _copy(job);
      record['jobKind'] = jobKind;
    }
    if (conflict != null) record['conflict'] = _copy(conflict);
    for (final pendingOperation in pendingOperations) {
      _add(record, pendingOperation);
      record['attempted'] = [
        ...(record['attempted'] as List),
        pendingOperation.opId,
      ];
      if (pendingOperation.kind.startsWith('metadata.')) {
        record['metadataInFlight'] = pendingOperation.opId;
        if (value != null) record['localValue'] = _copy(value);
      }
    }
    await _commit(entity, record);
  });
}

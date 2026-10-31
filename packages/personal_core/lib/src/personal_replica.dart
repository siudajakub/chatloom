// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'contracts.dart';
import 'transcript_parts.dart';
import 'transcription.dart' show sha256Hex;

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

/// Order-independent fingerprint of a metadata value (null = absent/deleted).
String _digest(Object? value) =>
    sha256Hex(utf8.encode(jsonEncode(_ordered(value))));

enum TranscriptCancellation {
  cancelledLocally,
  waitingAcknowledgement,
  queued,
  alreadyFinished,
}

/// How one journal event bears on a resumable replay.
enum JournalSettlement {
  /// Applied already, or irrelevant to every future trust/decryption state
  /// (commands, heartbeats, redactions, foreign or plaintext senders).
  settled,

  /// May still matter: not decrypted yet, sent by an own device which may be
  /// verified later, or a due reminder whose alert was not claimed yet.
  held,

  /// Not a durable journal position yet (local echo); replay stops here.
  barrier,
}

/// One journal event as seen by [JournalWatermark.advance].
class JournalPosition {
  final String eventId;
  final DateTime originServerTs;
  final JournalSettlement settlement;
  const JournalPosition(this.eventId, this.originServerTs, this.settlement);
}

/// A resumable position in the private journal, stored beside the replica.
///
/// Invariant: every journal event at or before [eventId] in journal order is
/// settled or listed in [held]. A client resumes by paging back until
/// [eventId] and a safety margin before it are loaded, then replays the newer
/// events, the margin and the held events (re-read by id). Re-applying a
/// result is idempotent, so an older watermark only costs time. A missing,
/// malformed, other-room or other-schema record means full replay.
class JournalWatermark {
  static const schema = 1;
  static const storageKey = 'journal:watermark';

  /// Beyond this many unsettled events the watermark stops advancing; later
  /// starts page back to it instead of losing track of any of them.
  static const maxHeld = 128;

  final String roomId;
  final String eventId;
  final DateTime originServerTs;
  final List<String> held;

  JournalWatermark({
    required this.roomId,
    required this.eventId,
    required this.originServerTs,
    List<String> held = const [],
  }) : held = List.unmodifiable(held);

  Map<String, dynamic> toJson() => {
    'schema': schema,
    'roomId': roomId,
    'eventId': eventId,
    'originServerTs': originServerTs.millisecondsSinceEpoch,
    'held': held,
  };

  static bool _isEventId(Object? id) =>
      id is String && id.length > 1 && id.startsWith(r'$');

  /// Null for anything but a complete record of this [schema].
  static JournalWatermark? tryParse(Map<String, dynamic>? json) {
    if (json == null || json['schema'] != schema) return null;
    final roomId = json['roomId'];
    final eventId = json['eventId'];
    final ts = json['originServerTs'];
    final held = json['held'];
    if (roomId is! String ||
        roomId.isEmpty ||
        !_isEventId(eventId) ||
        ts is! int ||
        held is! List ||
        held.length > maxHeld ||
        !held.every(_isEventId)) {
      return null;
    }
    return JournalWatermark(
      roomId: roomId,
      eventId: eventId as String,
      originServerTs: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
      held: held.cast<String>(),
    );
  }

  bool sameAs(JournalWatermark? other) {
    if (other == null ||
        other.roomId != roomId ||
        other.eventId != eventId ||
        other.originServerTs != originServerTs ||
        other.held.length != held.length) {
      return false;
    }
    for (var i = 0; i < held.length; i++) {
      if (other.held[i] != held[i]) return false;
    }
    return true;
  }

  /// Moves [previous] over [newer]: the events after it in journal order,
  /// oldest first. [resolved] are previously held ids which are settled now
  /// (or permanently unavailable). Without [previous], [newer] must start at
  /// the beginning of the journal. Returns null when nothing is covered yet.
  static JournalWatermark? advance({
    required String roomId,
    required JournalWatermark? previous,
    required Iterable<JournalPosition> newer,
    Set<String> resolved = const {},
    int maxHeld = JournalWatermark.maxHeld,
  }) {
    if (previous != null && previous.roomId != roomId) {
      throw ArgumentError('Journal watermark belongs to another room');
    }
    final held = <String>[
      for (final id in previous?.held ?? const <String>[])
        if (!resolved.contains(id)) id,
    ];
    final known = held.toSet();
    var eventId = previous?.eventId;
    var originServerTs = previous?.originServerTs;
    for (final position in newer) {
      if (position.settlement == JournalSettlement.barrier ||
          !_isEventId(position.eventId)) {
        break;
      }
      if (position.settlement == JournalSettlement.held &&
          !known.contains(position.eventId)) {
        if (held.length >= maxHeld) break;
        held.add(position.eventId);
        known.add(position.eventId);
      }
      eventId = position.eventId;
      originServerTs = position.originServerTs;
    }
    if (eventId == null || originServerTs == null) return null;
    return JournalWatermark(
      roomId: roomId,
      eventId: eventId,
      originServerTs: originServerTs,
      held: held,
    );
  }
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

  /// Automatic re-publications of one unconfirmed metadata change (a fresh
  /// operation id, see [reissue]) before only the user can resend it.
  static const maxAutomaticReissues = 2;

  /// Automatic rebases of this device's own change onto a newer revision
  /// that holds no foreign change, before the conflict is shown instead.
  static const maxAutomaticRebases = 3;

  /// Digests of the last values this device sent per entity.
  static const _sentHistory = 4;
  final _records = <String, Map<String, dynamic>>{};

  /// Applied result ids, newest last, bounded by [maxSeenInMemory].
  final _seen = <String>{};

  /// Durable seen markers live in [seenBuckets] records of at most
  /// [seenBucketSize] result ids each (chosen by a hash of the id, oldest
  /// dropped first), so they stay bounded however many results the journal
  /// carries. Before, every applied result left its own `seen:<opId>` record
  /// on every device, forever. Such older markers are still honoured. A
  /// result that fell out of its bucket is re-applied at most once more on a
  /// full replay, which is idempotent: revisions, `appliedResults` and
  /// command acknowledgement already make it a no-op.
  static const seenBuckets = 64;
  static const seenBucketSize = 64;
  static const maxSeenInMemory = 4096;
  static String seenKeyOf(String opId) => 'seen:ring:${_seenBucket(opId)}';
  static int _seenBucket(String opId) {
    var hash = 0;
    for (final unit in opId.codeUnits) {
      hash = (hash * 31 + unit) & 0x3fffffff;
    }
    return hash % seenBuckets;
  }

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
    // Only metadata (settings, chat metadata, drafts) can conflict. A refused
    // job command (already exists, too late, not found) is part of the job's
    // state and never a choice between two versions.
    if (conflict is Map && record['jobKind'] == null) {
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
            record['metadataBase'] = _digest(record['serverValue']);
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
      record['metadataBase'] = _digest(record['serverValue']);
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
    record['attemptedAt'] = {
      ...Map<String, dynamic>.from(record['attemptedAt'] as Map? ?? {}),
      opId: clock().toUtc().millisecondsSinceEpoch,
    };
    // Remembered before sending: if the acknowledgement never arrives, a
    // later refusal that reports this value is recognised as this device's
    // own write rather than a concurrent change.
    if (op.kind == 'metadata.put') {
      _rememberSent(record, op.payload['value']);
    } else if (op.kind == 'metadata.delete') {
      _rememberSent(record, null);
    }
    await _commit(op.entityId, record);
    return pending[opId];
  });

  /// When this device first started publishing [opId] (null: not yet, or a
  /// record from before this was tracked).
  DateTime? attemptedAt(String opId) {
    final op = pending[opId];
    final at = op == null
        ? null
        : (_records[op.entityId]?['attemptedAt'] as Map?)?[opId];
    return at is int
        ? DateTime.fromMillisecondsSinceEpoch(at, isUtc: true)
        : null;
  }

  /// Whether [opId] was handed to the journal at least once.
  bool isAttempted(String opId) {
    final op = pending[opId];
    return op != null &&
        ((_records[op.entityId]?['attempted'] as List?)?.contains(opId) ??
            false);
  }

  /// How often the change behind [opId] was re-published automatically.
  int reissueCount(String opId) {
    final op = pending[opId];
    return op == null ? 0 : _records[op.entityId]?['reissues'] as int? ?? 0;
  }

  /// Republishes an unconfirmed metadata change (or the pairing request)
  /// under a fresh operation id, so it travels as a new journal event in the
  /// current encryption session. A command the worker could never read (for
  /// example one sent before the worker's device existed) otherwise waits
  /// forever: a resend with the same transaction id returns the old event.
  ///
  /// Safe to repeat: every command carries the revision it was based on and
  /// the worker refuses one whose entity moved on, so a command the worker
  /// did process (only its answer was lost) comes back as a refusal with the
  /// real state, never as a second job or charge. An acknowledgement of the
  /// old id that still arrives is applied like any other result.
  /// [automatic] re-issues only metadata changes and the pairing request, at
  /// most [maxAutomaticReissues] times per change; paid or sending jobs
  /// (transcripts, schedules, reminders) are only resent when the user asks.
  /// Returns the new operation, or null when [opId] is not an attempted
  /// command.
  Future<PersonalOperation?> reissue(
    String opId, {
    bool automatic = false,
  }) => _serial(() async {
    final op = pending[opId];
    if (op == null) return null;
    final metadata = op.kind == 'metadata.put' || op.kind == 'metadata.delete';
    if (automatic && !metadata && op.kind != 'worker.pairing') {
      return null;
    }
    final record = _record(op.entityId);
    final commands = Map<String, dynamic>.from(
      record['commands'] as Map? ?? {},
    );
    final attempted = (record['attempted'] as List? ?? []).cast<String>();
    if (commands[opId] is! Map || !attempted.contains(opId)) return null;
    final count = record['reissues'] as int? ?? 0;
    if (automatic && count >= maxAutomaticReissues) return null;
    final put = op.kind == 'metadata.put';
    final fresh = _operation(
      op.kind,
      op.entityId,
      put && record['localValue'] is Map
          ? {'value': record['localValue']}
          : Map<String, dynamic>.from(op.payload),
      op.kind == 'worker.pairing' ? op.baseRevision : record['revision'] as int,
    );
    commands.remove(opId);
    record['commands'] = commands;
    record['attempted'] = attempted.where((id) => id != opId).toList();
    final at = Map<String, dynamic>.from(record['attemptedAt'] as Map? ?? {})
      ..remove(opId);
    record['attemptedAt'] = at;
    _add(record, fresh);
    if (record['metadataInFlight'] == opId) {
      record['metadataInFlight'] = fresh.opId;
      if (put) record['metadataCommandGeneration'] = record['generation'];
    }
    record['reissues'] = count + 1;
    await _commit(op.entityId, record);
    return fresh;
  });

  /// Resolves the metadata conflict of [entity] with one tap.
  ///
  /// [keepLocal]: this device's version is written over the other one (a new
  /// command based on the conflict's revision; the conflict disappears now
  /// and returns only if the entity changes elsewhere again).
  /// Otherwise the other version is kept: nothing is published, this
  /// device's proposal is dropped (a draft is kept as a draft copy first).
  Future<void> resolveConflict(String entity, {required bool keepLocal}) =>
      _serial(() async {
        final record = _record(entity);
        final conflict = record['conflict'];
        if (conflict is! Map || record['jobKind'] != null) return;
        if (record['metadataInFlight'] != null) {
          throw StateError('Metadata already awaiting acknowledgement');
        }
        final revision = conflict['revision'] is int
            ? conflict['revision'] as int
            : record['revision'] as int;
        final proposed = record['localValue'] is Map
            ? record['localValue']
            : conflict['proposedValue'];
        final existing = conflict.containsKey('existingValue')
            ? conflict['existingValue']
            : record['serverValue'];
        record.remove('conflict');
        record.remove('rebases');
        if (keepLocal) {
          // A replaced draft stays readable as a draft copy.
          if (entity.startsWith('draft:') && existing is Map) {
            _preserveDraft(record, entity, Map<String, dynamic>.from(existing));
          }
          final op = proposed is Map
              ? _operation('metadata.put', entity, {
                  'value': proposed,
                }, revision)
              : _operation('metadata.delete', entity, {}, revision);
          record['generation'] = (record['generation'] as int? ?? 0) + 1;
          if (proposed is Map) {
            record['localValue'] = _copy(Map<String, dynamic>.from(proposed));
          }
          _add(record, op);
          record['metadataInFlight'] = op.opId;
          record['metadataCommandGeneration'] = record['generation'];
          record['metadataBase'] = _digest(existing);
        } else {
          if (entity.startsWith('draft:') && proposed is Map) {
            _preserveDraft(record, entity, Map<String, dynamic>.from(proposed));
          }
          record.remove('localValue');
          if (existing is Map) {
            record['serverValue'] = _copy(Map<String, dynamic>.from(existing));
          } else {
            record.remove('serverValue');
          }
          if (revision > (record['revision'] as int)) {
            record['revision'] = revision;
          }
        }
        await _commit(entity, record);
      });

  /// Clears stored conflicts that need no choice: both versions are equal
  /// (an echo of this device's own write, or the same change made twice).
  /// Older app versions recorded those as conflicts. Returns the number of
  /// entities settled.
  Future<int> settleObsoleteConflicts() => _serial(() async {
    var settled = 0;
    // Only records holding a conflict are copied: startup stays cheap with
    // thousands of transcripts and drafts.
    final candidates = [
      for (final entry in _records.entries)
        if (entry.value['conflict'] is Map && entry.value['jobKind'] == null)
          entry.key,
    ];
    for (final entity in candidates) {
      final record = _record(entity);
      final conflict = record['conflict'];
      if (conflict is! Map ||
          record['jobKind'] != null ||
          record['metadataInFlight'] != null ||
          !conflict.containsKey('proposedValue')) {
        continue;
      }
      final proposed = record['localValue'] is Map
          ? record['localValue']
          : conflict['proposedValue'];
      final existing = conflict.containsKey('existingValue')
          ? conflict['existingValue']
          : record['serverValue'];
      if (!_equalValues(existing, proposed)) continue;
      record.remove('conflict');
      record.remove('localValue');
      if (existing is Map) {
        record['serverValue'] = _copy(Map<String, dynamic>.from(existing));
      } else {
        record.remove('serverValue');
      }
      final revision = conflict['revision'];
      if (revision is int && revision > (record['revision'] as int)) {
        record['revision'] = revision;
      }
      await _commit(entity, record);
      settled++;
    }
    return settled;
  });

  /// Equal metadata values; null (absent or deleted) equals only null.
  static bool _equalValues(Object? a, Object? b) =>
      (a is! Map && b is! Map) || (a is Map && b is Map && _same(a, b));

  void _preserveDraft(
    Map<String, dynamic> record,
    String entity,
    Map<String, dynamic> value,
  ) {
    final preserved = Map<String, dynamic>.from(
      record['preservedDrafts'] as Map? ?? {},
    );
    if (preserved.values.any(
      (copy) => copy is Map && _same(copy['originalValue'], value),
    )) {
      return;
    }
    preserved[newOperationId()] = {
      ..._copy(value),
      'originalValue': _copy(value),
      'sourceEntity': entity,
      'savedAt': clock().toUtc().toIso8601String(),
    };
    record['preservedDrafts'] = preserved;
  }

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

  /// Whether [opId] was applied: its bucket, or a marker from before buckets.
  Future<bool> _seenDurably(String opId) async {
    final ids = (await read(seenKeyOf(opId)))?['ids'];
    if (ids is List && ids.contains(opId)) return true;
    return await read('seen:$opId') != null;
  }

  Future<void> _markSeen(String opId) async {
    final key = seenKeyOf(opId);
    final ids = <String>[
      for (final id in (await read(key))?['ids'] as List? ?? const [])
        if (id is String && id != opId) id,
      opId,
    ];
    await write(key, {
      'ids': ids.length > seenBucketSize
          ? ids.sublist(ids.length - seenBucketSize)
          : ids,
    });
    _rememberSeen(opId);
  }

  void _rememberSeen(String opId) {
    _seen
      ..remove(opId)
      ..add(opId);
    if (_seen.length > maxSeenInMemory) _seen.remove(_seen.first);
  }

  Future<void> acceptResult(PersonalOperation result) => _serial(() async {
    if (_seen.contains(result.opId)) return;
    if (await _seenDurably(result.opId)) {
      _rememberSeen(result.opId);
      return;
    }
    final entity = result.entityId;
    final record = _record(entity);
    final applied = (record['appliedResults'] as List? ?? []).cast<String>();
    if (applied.contains(result.opId)) {
      await _markSeen(result.opId);
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
    final attemptedAt = Map<String, dynamic>.from(
      record['attemptedAt'] as Map? ?? {},
    )..removeWhere((id, _) => id == accepted || !commands.containsKey(id));
    if (attemptedAt.isEmpty) {
      record.remove('attemptedAt');
    } else {
      record['attemptedAt'] = attemptedAt;
    }
    if (record['metadataInFlight'] == accepted)
      record.remove('metadataInFlight');
    final latest = revision >= (record['revision'] as int);
    if (result.kind == transcriptTextPartKind) {
      // One slice of a long transcript: never a state change of its own.
      _acceptTextPart(record, payload, revision);
    } else if (result.kind == 'metadata.result') {
      _metadataResult(
        entity,
        record,
        payload,
        revision: revision,
        latest: latest,
        acknowledged: acknowledged,
        commandGeneration: commandGeneration,
      );
    } else if (latest) {
      record['revision'] = revision;
      if (result.kind == 'worker.pairing.result') record.remove('reissues');
      if ({
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
        if (result.kind == 'transcript.result') {
          _settleTranscriptText(record, payload, previous['text']);
        }
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
    await _markSeen(result.opId);
  });

  /// Stores one slice of a long transcript (see [transcriptTextPartKind])
  /// until the whole text can be assembled. Slices of another version of the
  /// text than the job announces are ignored; erased slices (`text: null`)
  /// carry nothing.
  void _acceptTextPart(
    Map<String, dynamic> record,
    Map<String, dynamic> payload,
    int revision,
  ) {
    final part = TranscriptTextPart.tryParse(payload);
    if (part == null) return;
    final job = record['job'];
    final meta = job is Map
        ? TranscriptTextParts.tryParse(job['textParts'])
        : null;
    if (meta != null && meta.digest != part.digest) return;
    final stored = record['transcriptText'];
    var parts = <String, dynamic>{};
    if (stored is Map) {
      if (stored['sha256'] == part.digest) {
        parts = Map<String, dynamic>.from(stored['parts'] as Map? ?? {});
      } else if ((stored['revision'] as int? ?? 0) > revision) {
        return; // A slice of an older version than the one being collected.
      }
    }
    parts['${part.index}'] = part.text;
    record['transcriptText'] = {
      'sha256': part.digest,
      'count': part.count,
      'revision': revision,
      'parts': parts,
    };
    _settleTranscriptText(record, null, null);
  }

  /// After a transcript result or slice: replaces the preview of a long
  /// transcript with the whole text once every slice matches its digest,
  /// keeps an already assembled text when the same result is applied again,
  /// and drops slices superseded by a complete text, a tombstone or a newer
  /// job. [payload] is the applied `transcript.result` (null for a slice).
  void _settleTranscriptText(
    Map<String, dynamic> record,
    Map<String, dynamic>? payload,
    Object? previousText,
  ) {
    final job = record['job'] is Map
        ? Map<String, dynamic>.from(record['job'] as Map)
        : null;
    // A result without the record announces no slices (whole text, erased
    // text or another state): an older announcement no longer applies.
    if (job != null && payload != null && !payload.containsKey('textParts')) {
      job.remove('textParts');
    }
    // Timestamps belong to the text of the same result: a new text without
    // them (an older worker transcribing again, an erased text) must not
    // inherit old ones. A result without text (a refusal) keeps them.
    if (job != null &&
        payload != null &&
        payload.containsKey('text') &&
        !payload.containsKey('timing')) {
      job.remove('timing');
    }
    final meta = TranscriptTextParts.tryParse(job?['textParts']);
    final stored = record['transcriptText'];
    if (job != null) record['job'] = job;
    if (meta == null) {
      final jobRevision = job?['revision'];
      if (stored is Map &&
          jobRevision is int &&
          jobRevision > (stored['revision'] as int? ?? 0)) {
        record.remove('transcriptText');
      }
      if (job != null) job.remove('textParts');
      return;
    }
    if (meta.matches(previousText) && !meta.matches(job!['text'])) {
      job['text'] = previousText; // Applied again: keep the whole text.
    }
    if (meta.matches(job!['text'])) {
      record.remove('transcriptText');
      return;
    }
    if (stored is! Map || stored['sha256'] != meta.digest) return;
    final slices = <int, String>{
      for (final entry in (stored['parts'] as Map? ?? {}).entries)
        if (int.tryParse('${entry.key}') case final index?)
          if (entry.value is String) index: entry.value as String,
    };
    final text = assembleTranscriptText(meta, slices);
    if (text == null) return;
    job['text'] = text;
    record.remove('transcriptText');
  }

  /// Applies a `metadata.result`. The worker serializes writes per entity by
  /// revision; a refusal (`state: conflict`) carries its current value.
  ///
  /// * A result for another device's operation only teaches the server state.
  ///   That device keeps, and resolves, its own proposal.
  /// * A refusal of this device's change is no conflict when the server
  ///   already holds the wanted value, and is rebased (sent again at the new
  ///   revision) when the server holds no foreign change: the value this
  ///   change started from, a value this device wrote itself, or nothing at
  ///   revision 0. Rebases are bounded by [maxAutomaticRebases].
  /// * Anything else is a real concurrent change: both versions stay until
  ///   the user chooses ([resolveConflict]).
  void _metadataResult(
    String entity,
    Map<String, dynamic> record,
    Map<String, dynamic> payload, {
    required int revision,
    required bool latest,
    required PersonalOperation? acknowledged,
    required Object? commandGeneration,
  }) {
    final refused = payload['state'] == 'conflict';
    if (acknowledged == null) {
      if (!latest) return;
      record['revision'] = revision;
      if (refused) {
        final existing = payload['existingValue'];
        _setServer(record, existing is Map ? existing : null);
      } else if (payload['deleted'] == true) {
        record.remove('serverValue');
      } else if (payload['value'] is Map) {
        _setServer(record, payload['value'] as Map);
      }
      _refreshConflict(record);
      return;
    }
    final put = acknowledged.kind == 'metadata.put';
    final sent = put ? acknowledged.payload['value'] : null;
    final newerEdit = record['generation'] != commandGeneration;
    record.remove('reissues');
    if (!refused) {
      if (latest) {
        record['revision'] = revision;
        if (payload['deleted'] == true) {
          record.remove('serverValue');
        } else if (payload['value'] is Map) {
          _setServer(record, payload['value'] as Map);
        }
        // A foreign update cannot erase a local unacknowledged draft.
        if ((!put && !newerEdit) || _same(sent, record['localValue'])) {
          record.remove('localValue');
        }
        record.remove('conflict');
        record.remove('rebases');
        _requeueLocal(record, entity, revision);
      } else if (_same(sent, record['localValue'])) {
        record.remove('localValue');
      } else if (record['localValue'] is Map) {
        // Acknowledged at an older state than one already applied (results
        // replayed out of order). The newer local edit started from this
        // device's own write: send it again when the newest known state is
        // still that write, otherwise keep both versions for the user.
        final known = record['serverValue'];
        final current = record['revision'] as int;
        if (_foreignChange(record, known, current)) {
          record['conflict'] = {
            'state': 'conflict',
            'revision': current,
            'existingValue': _copyOrNull(known),
            'proposedValue': _copyOrNull(record['localValue']),
          };
        } else {
          _requeueLocal(record, entity, current);
        }
      }
      return;
    }
    final wantDelete = !put && !newerEdit;
    final Object? wanted = wantDelete
        ? null
        : record['localValue'] is Map
        ? record['localValue']
        : sent;
    // Decide against the newest server state this device knows: the
    // refusal's own, or a newer one already applied (out-of-order replay).
    // A refusal at revision 0 without a value is always current: the worker
    // has never stored this entity (for example a re-created worker store),
    // whatever revision this device remembers.
    final authoritative =
        latest || (revision == 0 && payload['existingValue'] is! Map);
    final current = authoritative ? revision : record['revision'] as int;
    if (authoritative) {
      record['revision'] = revision;
      final existing = payload['existingValue'];
      _setServer(record, existing is Map ? existing : null);
    }
    final server = record['serverValue'];
    if (wantDelete ? server is! Map : wanted is Map && _same(server, wanted)) {
      // Both sides already agree: nothing to choose.
      record.remove('localValue');
      record.remove('conflict');
      record.remove('rebases');
      return;
    }
    if (!_foreignChange(record, server, current) &&
        _rebase(record, entity, wanted, wantDelete, current)) {
      return;
    }
    // A real concurrent change: both versions stay until the user chooses.
    // The refusal names the version that was sent; a newer unsent edit stays
    // the local value, so neither is lost.
    record['conflict'] = authoritative
        ? {..._copy(payload), 'existingValue': _copyOrNull(server)}
        : {
            'state': 'conflict',
            'revision': current,
            'existingValue': _copyOrNull(server),
            'proposedValue': _copyOrNull(wanted),
          };
    if (wanted is Map && record['localValue'] is! Map) {
      record['localValue'] = _copyOrNull(wanted);
    }
    record.remove('rebases');
  }

  static Map<String, dynamic>? _copyOrNull(Object? value) =>
      value is Map ? _copy(Map<String, dynamic>.from(value)) : null;

  /// Whether [server] (at [revision]) may hold another device's change: it
  /// is neither the value this device's change started from, nor one this
  /// device wrote itself, nor an entity the worker has never stored.
  bool _foreignChange(
    Map<String, dynamic> record,
    Object? server,
    int revision,
  ) {
    final value = server is Map ? server : null;
    final digest = _digest(value);
    final sent = record['sentDigests'] as List? ?? const [];
    return !(digest == record['metadataBase'] ||
        sent.contains(digest) ||
        (value == null && revision == 0));
  }

  /// Sends [wanted] (or a delete) again at [base]; false when not allowed.
  bool _rebase(
    Map<String, dynamic> record,
    String entity,
    Object? wanted,
    bool wantDelete,
    int base,
  ) {
    final rebases = record['rebases'] as int? ?? 0;
    if (rebases >= maxAutomaticRebases || (!wantDelete && wanted is! Map)) {
      return false;
    }
    final op = wantDelete
        ? _operation('metadata.delete', entity, {}, base)
        : _operation('metadata.put', entity, {'value': wanted}, base);
    if (!wantDelete) {
      record['localValue'] = _copy(Map<String, dynamic>.from(wanted as Map));
      record['metadataCommandGeneration'] = record['generation'];
    }
    record.remove('conflict');
    record['rebases'] = rebases + 1;
    _add(record, op);
    record['metadataInFlight'] = op.opId;
    record['metadataBase'] = _digest(record['serverValue']);
    return true;
  }

  /// Sends the newest local edit, unless one is in flight or in conflict.
  void _requeueLocal(Map<String, dynamic> record, String entity, int base) {
    if (record['localValue'] is! Map ||
        record['conflict'] != null ||
        record['metadataInFlight'] != null) {
      return;
    }
    final op = _operation('metadata.put', entity, {
      'value': record['localValue'],
    }, base);
    _add(record, op);
    record['metadataInFlight'] = op.opId;
    record['metadataCommandGeneration'] = record['generation'];
    record['metadataBase'] = _digest(record['serverValue']);
  }

  void _setServer(Map<String, dynamic> record, Map? value) {
    if (value == null) {
      record.remove('serverValue');
    } else {
      record['serverValue'] = _copy(Map<String, dynamic>.from(value));
    }
  }

  void _rememberSent(Map<String, dynamic> record, Object? value) {
    final digests = [
      for (final digest in record['sentDigests'] as List? ?? const [])
        if (digest is String) digest,
    ];
    final digest = _digest(value is Map ? value : null);
    digests
      ..remove(digest)
      ..add(digest);
    record['sentDigests'] = digests.length > _sentHistory
        ? digests.sublist(digests.length - _sentHistory)
        : digests;
  }

  /// Another device changed an entity this device holds a conflict for: the
  /// conflict now compares against the new server version, and disappears
  /// when that already equals this device's proposal.
  void _refreshConflict(Map<String, dynamic> record) {
    final conflict = record['conflict'];
    if (conflict is! Map || !conflict.containsKey('proposedValue')) return;
    final server = record['serverValue'];
    final proposed = record['localValue'] is Map
        ? record['localValue']
        : conflict['proposedValue'];
    if (_equalValues(server, proposed)) {
      record.remove('conflict');
      record.remove('localValue');
      return;
    }
    record['conflict'] = {
      ...Map<String, dynamic>.from(conflict),
      'revision': record['revision'],
      'existingValue': server is Map
          ? _copy(Map<String, dynamic>.from(server))
          : null,
    };
  }

  /// The persisted journal resume point for [roomId]; null means full replay
  /// (new or migrated store, other journal room, unknown or broken record).
  Future<JournalWatermark?> journalWatermark(String roomId) =>
      _serial(() async {
        final watermark = JournalWatermark.tryParse(
          await read(JournalWatermark.storageKey),
        );
        return watermark?.roomId == roomId ? watermark : null;
      });

  /// Serialized behind every earlier replica commit, so a watermark is never
  /// durable before the results it covers.
  Future<void> saveJournalWatermark(JournalWatermark watermark) =>
      _serial(() => write(JournalWatermark.storageKey, watermark.toJson()));

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

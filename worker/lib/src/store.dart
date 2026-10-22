// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'package:personal_core/personal_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'engine.dart' show stableId;

/// All job changes and acknowledgements share one durable transaction.
class WorkerStore {
  final Database db;
  WorkerStore(this.db) {
    db.execute('PRAGMA foreign_keys=ON');
    db.execute(
      'CREATE TABLE IF NOT EXISTS transcript_publications (op_id TEXT PRIMARY KEY, entity_id TEXT NOT NULL, event_id TEXT NOT NULL, pending_redaction INTEGER NOT NULL DEFAULT 0, text_bearing INTEGER NOT NULL DEFAULT 0)',
    );
    if (!db
        .select('PRAGMA table_info(transcript_publications)')
        .any((row) => row['name'] == 'text_bearing')) {
      db.execute(
        'ALTER TABLE transcript_publications ADD COLUMN text_bearing INTEGER NOT NULL DEFAULT 1',
      );
    }
    db.execute('PRAGMA journal_mode=WAL');
    db.execute(
      'CREATE TABLE IF NOT EXISTS commands (id TEXT PRIMARY KEY, body TEXT NOT NULL)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, kind TEXT NOT NULL, revision INTEGER NOT NULL, state TEXT NOT NULL, body TEXT NOT NULL)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS metadata (id TEXT PRIMARY KEY, revision INTEGER NOT NULL, deleted INTEGER NOT NULL, body TEXT NOT NULL)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS outbox (id TEXT PRIMARY KEY, body TEXT NOT NULL)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS checkpoints (id TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS reminder_hints (id TEXT PRIMARY KEY, body TEXT NOT NULL)',
    );
    // Per-loop queries read only the jobs they need (kind and state are
    // columns already). Rollback-safe: older binaries ignore the index and
    // the new table, and every existing table keeps its columns.
    db.execute(
      'CREATE INDEX IF NOT EXISTS jobs_kind_state ON jobs(kind, state)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS outbox_parked (id TEXT PRIMARY KEY, body TEXT NOT NULL, error TEXT NOT NULL, parked_at TEXT NOT NULL)',
    );
    _splitLongOutboxTranscripts();
  }

  T transaction<T>(T Function() action) {
    db.execute('BEGIN IMMEDIATE');
    try {
      final result = action();
      db.execute('COMMIT');
      return result;
    } catch (_) {
      db.execute('ROLLBACK');
      // Rolled-back job writes may have reached the in-memory ledger.
      _autoCosts = null;
      rethrow;
    }
  }

  /// [action] atomically, inside or outside a [transaction].
  void _atomically(void Function() action) {
    db.execute('SAVEPOINT store_atomic');
    try {
      action();
      db.execute('RELEASE store_atomic');
    } catch (_) {
      db.execute('ROLLBACK TO store_atomic');
      db.execute('RELEASE store_atomic');
      rethrow;
    }
  }

  bool hasCommand(String id) =>
      db.select('SELECT 1 FROM commands WHERE id=?', [id]).isNotEmpty;
  void command(String id, Map<String, dynamic> body) =>
      db.execute('INSERT INTO commands VALUES (?,?)', [id, jsonEncode(body)]);
  Map<String, dynamic>? job(String id) {
    final rows = db.select('SELECT body FROM jobs WHERE id=?', [id]);
    return rows.isEmpty
        ? null
        : jsonDecode(rows.first['body'] as String) as Map<String, dynamic>;
  }

  void saveJob(Map<String, dynamic> body) {
    db.execute(
      'INSERT INTO jobs VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, revision=excluded.revision, state=excluded.state, body=excluded.body',
      [
        body['id'],
        body['kind'],
        body['revision'],
        body['state'],
        jsonEncode(body),
      ],
    );
    _ledger(body);
  }

  /// Every job, decoded. Startup and maintenance only: per-loop work uses
  /// [jobsWhere], which reads just the rows it needs through the index.
  List<Map<String, dynamic>> jobs() => db
      .select('SELECT body FROM jobs ORDER BY rowid')
      .map((row) => jsonDecode(row['body'] as String) as Map<String, dynamic>)
      .toList();

  /// Jobs of [kind] in one of [states] (all states when null), in creation
  /// order.
  List<Map<String, dynamic>> jobsWhere(
    String kind, [
    Iterable<String>? states,
  ]) {
    final wanted = states?.toList();
    final rows = wanted == null
        ? db.select('SELECT body FROM jobs WHERE kind=? ORDER BY rowid', [kind])
        : wanted.isEmpty
        ? const <Row>[]
        : db.select(
            'SELECT body FROM jobs WHERE kind=? AND state IN (${List.filled(wanted.length, '?').join(',')}) ORDER BY rowid',
            [kind, ...wanted],
          );
    return [
      for (final row in rows)
        jsonDecode(row['body'] as String) as Map<String, dynamic>,
    ];
  }

  /// Jobs of [kind] in [states] whose `errorCode` is [errorCode]: the body
  /// is matched in SQL first, so only candidates are decoded (callers still
  /// check the decoded field).
  List<Map<String, dynamic>> jobsWithError(
    String kind,
    Iterable<String> states,
    String errorCode,
  ) {
    final wanted = states.toList();
    if (wanted.isEmpty) return const [];
    return [
      for (final row in db.select(
        'SELECT body FROM jobs WHERE kind=? AND state IN (${List.filled(wanted.length, '?').join(',')}) AND instr(body, ?) > 0 ORDER BY rowid',
        [kind, ...wanted, '"errorCode":${jsonEncode(errorCode)}'],
      ))
        jsonDecode(row['body'] as String) as Map<String, dynamic>,
    ];
  }

  /// The next [limit] transcript jobs after [afterId] (round-robin, wrapping)
  /// whose source still matters to a deletion audit: unfinished ones, and
  /// done ones holding text. Jobs parked on an unknown source status
  /// (`waitingSync`) have their own probe schedule and are left out.
  List<Map<String, dynamic>> sourceAuditBatch(
    String? afterId, {
    required int limit,
  }) {
    const filter =
        "kind='transcript' AND (state IN ('queued','processing','waitingKeys') OR (state='done' AND instr(body, '\"text\":\"') > 0))";
    final cursor = afterId == null
        ? null
        : db.select('SELECT rowid AS r FROM jobs WHERE id=?', [afterId]);
    final after = cursor == null || cursor.isEmpty
        ? 0
        : cursor.first['r'] as int;
    final rows = [
      ...db.select(
        'SELECT body FROM jobs WHERE $filter AND rowid>? ORDER BY rowid LIMIT ?',
        [after, limit],
      ),
    ];
    if (rows.length < limit && after > 0) {
      rows.addAll(
        db.select(
          'SELECT body FROM jobs WHERE $filter AND rowid<=? ORDER BY rowid LIMIT ?',
          [after, limit - rows.length],
        ),
      );
    }
    final seen = <String>{};
    return [
      for (final row in rows)
        if (jsonDecode(row['body'] as String) as Map<String, dynamic>
            case final job
            when seen.add(job['id'] as String) &&
                (job['state'] != 'done' ||
                    (job['text'] is String &&
                        (job['text'] as String).isNotEmpty)))
          job,
    ];
  }

  /// Unfinished jobs (heartbeat `pending`) without decoding any body.
  int get pendingJobCount =>
      db
              .select(
                "SELECT COUNT(*) AS n FROM jobs WHERE state NOT IN ('done','cancelled','failed')",
              )
              .first['n']
          as int;

  /// Automatic transcript jobs (id -> creation time and estimated cost), for
  /// the daily budget without decoding every job on each check. Built once
  /// from the table, then kept current by [saveJob]; a rolled-back
  /// transaction rebuilds it.
  Map<String, ({DateTime created, double cost})>? _autoCosts;

  void _ledger(Map<String, dynamic> body) {
    final costs = _autoCosts;
    if (costs == null) return;
    final id = body['id'] as String;
    final entry = _costEntry(body);
    if (entry == null) {
      costs.remove(id);
    } else {
      costs[id] = entry;
    }
  }

  static ({DateTime created, double cost})? _costEntry(
    Map<String, dynamic> job,
  ) {
    if (job['kind'] != 'transcript' ||
        job['origin'] != TranscriptionOrigin.auto.name) {
      return null;
    }
    final created = DateTime.tryParse(job['createdAt'] as String? ?? '');
    if (created == null) return null;
    final pending = job['pendingResult'];
    final cost =
        job['estimatedCostUsd'] ??
        (pending is Map ? pending['estimatedCostUsd'] : null);
    return (
      created: created,
      cost: cost is num && cost.isFinite && cost > 0 ? cost.toDouble() : 0,
    );
  }

  /// Estimated cost of automatic jobs created at or after [from], without
  /// [excluding]. Entries far older than the window are forgotten.
  double autoSpentSince(DateTime from, {String? excluding}) {
    final costs = _autoCosts ??= {
      for (final job in jobsWhere('transcript'))
        job['id'] as String: ?_costEntry(job),
    };
    final forget = from.subtract(const Duration(days: 1));
    costs.removeWhere((_, entry) => entry.created.isBefore(forget));
    var total = 0.0;
    for (final entry in costs.entries) {
      if (entry.key == excluding || entry.value.created.isBefore(from)) {
        continue;
      }
      total += entry.value.cost;
    }
    return total;
  }

  Map<String, dynamic>? metadata(String id) {
    final rows = db.select('SELECT * FROM metadata WHERE id=?', [id]);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return {
      'revision': row['revision'],
      'deleted': row['deleted'] == 1,
      'value': jsonDecode(row['body'] as String),
    };
  }

  /// Current (not deleted) metadata values whose id starts with [prefix].
  Map<String, Object?> metadataWithPrefix(String prefix) => {
    for (final row in db.select(
      'SELECT id, body FROM metadata WHERE deleted=0 AND substr(id,1,?)=?',
      [prefix.length, prefix],
    ))
      row['id'] as String: jsonDecode(row['body'] as String),
  };

  void saveMetadata(
    String id,
    int revision,
    bool deleted,
    Object? value,
  ) => db.execute(
    'INSERT INTO metadata VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision, deleted=excluded.deleted, body=excluded.body',
    [id, revision, deleted ? 1 : 0, jsonEncode(value)],
  );

  /// Queues a journal publication. A transcript too long for one journal
  /// event is published as a preview result plus text slices (personal_core
  /// `transcript_parts.dart`), queued together and in order.
  void enqueue(String id, Map<String, Object?> body) {
    final split = _splitTranscript(body);
    if (split == null) {
      db.execute('INSERT OR IGNORE INTO outbox VALUES (?,?)', [
        id,
        jsonEncode(body),
      ]);
      return;
    }
    _atomically(() {
      db.execute('INSERT OR IGNORE INTO outbox VALUES (?,?)', [
        id,
        jsonEncode(split.$1),
      ]);
      for (final part in split.$2) {
        db.execute('INSERT OR IGNORE INTO outbox VALUES (?,?)', [
          part['opId'],
          jsonEncode(part),
        ]);
      }
    });
  }

  /// The preview result and the slice operations for a transcript result
  /// whose text does not fit one journal event; null otherwise.
  static (Map<String, Object?>, List<Map<String, Object?>>)? _splitTranscript(
    Map<String, Object?> body,
  ) {
    final payload = body['payload'];
    if (body['kind'] != 'transcript.result' || payload is! Map) return null;
    final text = payload['text'];
    if (text is! String) return null;
    final publication = TranscriptTextPublication.of(text);
    if (publication == null) return null;
    final opId = body['opId'] as String;
    final entity = body['entityId'] as String;
    final revision = payload['revision'] as int? ?? 0;
    final result = Map<String, Object?>.from(body)
      ..['payload'] = {
        ...Map<String, dynamic>.from(payload),
        'text': publication.preview,
        'textParts': publication.meta.toJson(),
      };
    final parts = [
      for (var i = 0; i < publication.parts.length; i++)
        PersonalOperation(
          opId: stableId('text-part', '$opId:$i'),
          kind: transcriptTextPartKind,
          entityId: entity,
          baseRevision: revision,
          createdAt: DateTime.parse(body['createdAt'] as String),
          payload: publication.partPayload(entity, revision, i),
        ).toJson(),
    ];
    return (result, parts);
  }

  /// Results queued by an older worker with a transcript too long for one
  /// event never left the device (the SDK refuses them locally) and blocked
  /// the queue. They are rewritten into the preview-and-slices form once.
  void _splitLongOutboxTranscripts() {
    final rows = db.select(
      "SELECT id, body FROM outbox WHERE instr(body, '\"kind\":\"transcript.result\"') > 0 ORDER BY rowid",
    );
    for (final row in rows) {
      final body = jsonDecode(row['body'] as String) as Map<String, dynamic>;
      final split = _splitTranscript(body);
      if (split == null) continue;
      _atomically(() {
        db.execute('UPDATE outbox SET body=? WHERE id=?', [
          jsonEncode(split.$1),
          row['id'],
        ]);
        for (final part in split.$2) {
          db.execute('INSERT OR IGNORE INTO outbox VALUES (?,?)', [
            part['opId'],
            jsonEncode(part),
          ]);
        }
      });
    }
  }

  List<Map<String, dynamic>> get outbox => db
      .select('SELECT body FROM outbox ORDER BY rowid')
      .map((r) => jsonDecode(r['body'] as String) as Map<String, dynamic>)
      .toList();

  /// Queued publication ids in order, without decoding their bodies.
  List<String> get outboxIds => [
    for (final row in db.select('SELECT id FROM outbox ORDER BY rowid'))
      row['id'] as String,
  ];
  void acknowledge(String id) =>
      db.execute('DELETE FROM outbox WHERE id=?', [id]);

  /// Moves a publication the homeserver or SDK refuses for good (too large,
  /// malformed) out of the queue, so it no longer blocks the ones behind
  /// it. Kept, not deleted, with the reason code.
  void parkOutbox(String id, String error, DateTime at) => transaction(() {
    final rows = db.select('SELECT body FROM outbox WHERE id=?', [id]);
    if (rows.isEmpty) return;
    db.execute('INSERT OR REPLACE INTO outbox_parked VALUES (?,?,?,?)', [
      id,
      rows.single['body'],
      error,
      at.toUtc().toIso8601String(),
    ]);
    db.execute('DELETE FROM outbox WHERE id=?', [id]);
  });

  /// Queues entries parked with [error] again (behind everything queued).
  void unparkOutbox(String error) => transaction(() {
    final rows = db.select(
      'SELECT id, body FROM outbox_parked WHERE error=? ORDER BY rowid',
      [error],
    );
    for (final row in rows) {
      db.execute('INSERT OR IGNORE INTO outbox VALUES (?,?)', [
        row['id'],
        row['body'],
      ]);
      db.execute('DELETE FROM outbox_parked WHERE id=?', [row['id']]);
    }
  });

  int get parkedCount =>
      db.select('SELECT COUNT(*) AS n FROM outbox_parked').first['n'] as int;
  void enqueueReminderHint(String id, Map<String, Object?> body) => db.execute(
    'INSERT OR IGNORE INTO reminder_hints VALUES (?,?)',
    [id, jsonEncode(body)],
  );
  List<Map<String, dynamic>> get reminderHints => db
      .select('SELECT body FROM reminder_hints ORDER BY rowid')
      .map((row) => jsonDecode(row['body'] as String) as Map<String, dynamic>)
      .toList();
  void acknowledgeReminderHint(String id) =>
      db.execute('DELETE FROM reminder_hints WHERE id=?', [id]);
  static bool _transcriptPublication(Object? kind) =>
      kind == 'transcript.result' || kind == transcriptTextPartKind;

  void recordTranscriptPublicationIntent(Map<String, dynamic> body) {
    if (!_transcriptPublication(body['kind'])) return;
    final invalidated =
        job(body['entityId'] as String)?['errorCode'] == 'source_redacted';
    final textBearing = (body['payload'] as Map?)?['text'] is String;
    db.execute(
      'INSERT INTO transcript_publications VALUES (?,?,?,?,?) ON CONFLICT(op_id) DO UPDATE SET pending_redaction=MAX(pending_redaction,excluded.pending_redaction),text_bearing=MAX(text_bearing,excluded.text_bearing)',
      [
        body['opId'],
        body['entityId'],
        '',
        invalidated && textBearing ? 1 : 0,
        textBearing ? 1 : 0,
      ],
    );
  }

  void recordTranscriptPublication(Map<String, dynamic> body, String eventId) {
    if (!_transcriptPublication(body['kind'])) return;
    recordTranscriptPublicationIntent(body);
    db.execute('UPDATE transcript_publications SET event_id=? WHERE op_id=?', [
      eventId,
      body['opId'],
    ]);
  }

  void invalidateTranscriptPublications(String entityId) {
    db.execute(
      'UPDATE transcript_publications SET pending_redaction=1 WHERE entity_id=? AND text_bearing=1',
      [entityId],
    );
    // Preserve each txid: a previous send may have been accepted with a lost ACK.
    // Retrying a text:null body resolves that original event ID for redaction.
    for (final body in outbox) {
      if (body['entityId'] != entityId) continue;
      if (body['kind'] == transcriptTextPartKind) {
        // Slices keep their txid as well; an erased slice carries no text.
        recordTranscriptPublicationIntent(body);
        body['payload'] = {
          ...Map<String, dynamic>.from(body['payload'] as Map),
          'text': null,
        };
        db.execute('UPDATE outbox SET body=? WHERE id=?', [
          jsonEncode(body),
          body['opId'],
        ]);
        continue;
      }
      if (body['kind'] == 'transcript.result') {
        recordTranscriptPublicationIntent(body);
        final payload = Map<String, dynamic>.from(body['payload'] as Map)
          ..remove('pendingResult')
          ..remove('textParts')
          ..addAll({
            'text': null,
            'state': 'cancelled',
            'errorCode': 'source_redacted',
          });
        body['payload'] = payload;
        db.execute('UPDATE outbox SET body=? WHERE id=?', [
          jsonEncode(body),
          body['opId'],
        ]);
      }
    }
  }

  Map<String, dynamic>? outboxEntry(String opId) {
    final rows = db.select('SELECT body FROM outbox WHERE id=?', [opId]);
    return rows.isEmpty
        ? null
        : jsonDecode(rows.single['body'] as String) as Map<String, dynamic>;
  }

  List<Map<String, dynamic>> get pendingTranscriptRedactions => db
      .select(
        "SELECT op_id,event_id FROM transcript_publications WHERE pending_redaction=1 AND event_id != '' ORDER BY rowid LIMIT 8",
      )
      .map((row) => Map<String, dynamic>.from(row))
      .toList();
  void acknowledgeTranscriptRedaction(String opId) =>
      db.execute('DELETE FROM transcript_publications WHERE op_id=?', [opId]);

  String? checkpoint(String id) {
    final rows = db.select('SELECT value FROM checkpoints WHERE id=?', [id]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void setCheckpoint(String id, String value) => db.execute(
    'INSERT INTO checkpoints VALUES (?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value',
    [id, value],
  );
  Map<String, String> checkpointsWithPrefix(String prefix) => {
    for (final row in db.select(
      "SELECT id,value FROM checkpoints WHERE substr(id,1,length(?))=?",
      [prefix, prefix],
    ))
      row['id'] as String: row['value'] as String,
  };

  void deleteCheckpoint(String id) =>
      db.execute('DELETE FROM checkpoints WHERE id=?', [id]);
  void close() => db.close();
}

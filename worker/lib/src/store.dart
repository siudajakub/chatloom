// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'package:sqlite3/sqlite3.dart';

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
  }

  T transaction<T>(T Function() action) {
    db.execute('BEGIN IMMEDIATE');
    try {
      final result = action();
      db.execute('COMMIT');
      return result;
    } catch (_) {
      db.execute('ROLLBACK');
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

  void saveJob(Map<String, dynamic> body) => db.execute(
    'INSERT INTO jobs VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, revision=excluded.revision, state=excluded.state, body=excluded.body',
    [
      body['id'],
      body['kind'],
      body['revision'],
      body['state'],
      jsonEncode(body),
    ],
  );
  List<Map<String, dynamic>> jobs() => db
      .select('SELECT body FROM jobs ORDER BY rowid')
      .map((row) => jsonDecode(row['body'] as String) as Map<String, dynamic>)
      .toList();
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

  void saveMetadata(
    String id,
    int revision,
    bool deleted,
    Object? value,
  ) => db.execute(
    'INSERT INTO metadata VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision, deleted=excluded.deleted, body=excluded.body',
    [id, revision, deleted ? 1 : 0, jsonEncode(value)],
  );
  void enqueue(String id, Map<String, Object?> body) => db.execute(
    'INSERT OR IGNORE INTO outbox VALUES (?,?)',
    [id, jsonEncode(body)],
  );
  List<Map<String, dynamic>> get outbox => db
      .select('SELECT body FROM outbox ORDER BY rowid')
      .map((r) => jsonDecode(r['body'] as String) as Map<String, dynamic>)
      .toList();
  void acknowledge(String id) =>
      db.execute('DELETE FROM outbox WHERE id=?', [id]);
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
  void recordTranscriptPublicationIntent(Map<String, dynamic> body) {
    if (body['kind'] != 'transcript.result') return;
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
    if (body['kind'] != 'transcript.result') return;
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
      if (body['entityId'] == entityId && body['kind'] == 'transcript.result') {
        recordTranscriptPublicationIntent(body);
        final payload = Map<String, dynamic>.from(body['payload'] as Map)
          ..remove('pendingResult')
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
  void close() => db.close();
}

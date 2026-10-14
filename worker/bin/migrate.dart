// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/config.dart';
import 'package:personal_worker/src/engine.dart';
import 'package:personal_worker/src/runtime.dart';
import 'package:personal_worker/src/store.dart';
import 'package:sqlite3/sqlite3.dart';

/// Explicit source map only; no text/title/time heuristic and no network APIs.
Future<void> main(List<String> args) async {
  sanitizeLogs();
  if (args.length < 3 ||
      args.length > 4 ||
      (args.length == 4 && args[3] != '--apply')) {
    stderr.writeln(
      'Usage: migrate SOURCE.sqlite EXPLICIT_MAPPING.json WORKER_CONFIG.json [--apply]',
    );
    exitCode = 64;
    return;
  }
  try {
    final source = sqlite3.open(args[0], mode: OpenMode.readOnly);
    try {
      final mappings = jsonDecode(File(args[1]).readAsStringSync()) as List;
      final mapped = <String, SourceEventRef>{};
      for (final value in mappings) {
        final map = Map<String, dynamic>.from(value as Map);
        final legacy = Map<String, dynamic>.from(map['legacy'] as Map);
        final ref = SourceEventRef.fromJson(
          Map<String, dynamic>.from(map['source'] as Map),
        );
        if (!ref.conversation.roomId.startsWith('!') ||
            !ref.eventId.startsWith(r'$')) {
          throw const FormatException('canonical source required');
        }
        final key = jsonEncode([legacy['chatId'], legacy['messageId']]);
        if (mapped.containsKey(key)) {
          throw const FormatException('duplicate source mapping');
        }
        mapped[key] = ref;
      }
      final rows = source.select(
        "SELECT chat_id,message_id,text FROM transcripts WHERE status='done' AND text IS NOT NULL",
      );
      final eligible = rows
          .where(
            (row) => mapped.containsKey(
              jsonEncode([row['chat_id'], row['message_id']]),
            ),
          )
          .toList();
      stdout.writeln(
        'Completed rows: ${rows.length}; explicitly mapped: ${eligible.length}; unmapped: ${rows.length - eligible.length}.',
      );
      if (args.length == 3) {
        stdout.writeln('Dry run: no writes and no network.');
        return;
      }
      final config = WorkerConfig.read(args[2]);
      await privateDirectory(config.stateDirectory);
      final credentials = readCredentials(config);
      final cipher = credentials['databaseCipher'] as String;
      if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(cipher)) {
        throw const FormatException('invalid cipher');
      }
      final backup =
          '${config.stateDirectory}/legacy-backup-${DateTime.now().microsecondsSinceEpoch}.sqlite';
      // SQLCipher export includes the WAL and encrypts the independent backup.
      final snapshot = sqlite3.copyIntoMemory(source);
      snapshot.execute(
        "ATTACH DATABASE ? AS migration_backup KEY \"x'$cipher'\"",
        [backup],
      );
      try {
        snapshot.select("SELECT sqlcipher_export('migration_backup')");
      } finally {
        snapshot.execute('DETACH DATABASE migration_backup');
        snapshot.close();
      }
      await Process.run('chmod', ['600', backup]);
      final store = WorkerStore(
        encryptedDatabase(
          '${config.stateDirectory}/jobs.sqlite',
          credentials['databaseCipher'] as String,
        ),
      );
      try {
        store.transaction(() {
          for (final row in eligible) {
            final ref =
                mapped[jsonEncode([row['chat_id'], row['message_id']])]!;
            final id = stableId(
              'transcript',
              ref.key,
            ).replaceFirst('transcript-', 'transcript:');
            if (store.job(id) != null) continue;
            final body = Map<String, dynamic>.from(
              TranscriptionJob(
                id: id,
                source: ref,
                state: JobState.done,
                text: row['text'] as String,
                model: 'legacy-import',
              ).toJson(),
            )..addAll({'kind': 'transcript', 'revision': 1});
            store.saveJob(body);
            final operation = PersonalOperation(
              opId: stableId('legacy', ref.key),
              kind: 'transcript.result',
              entityId: id,
              baseRevision: 1,
              createdAt: DateTime.now(),
              payload: body,
            );
            store.enqueue(operation.opId, operation.toJson());
          }
        });
      } finally {
        store.close();
      }
      stdout.writeln(
        'Imported mapped results into encrypted store; private backup retained. Nothing sent.',
      );
    } finally {
      source.close();
    }
  } catch (e) {
    stderr.writeln(
      'Migration stopped (${e.runtimeType}); original source preserved.',
    );
    exitCode = 1;
  }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path;
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/config.dart';
import 'package:personal_worker/src/engine.dart';
import 'package:personal_worker/src/journal.dart';
import 'package:personal_worker/src/journal_trust.dart';
import 'package:personal_worker/src/matrix_transport.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/runtime.dart';
import 'package:personal_worker/src/store.dart';
import 'package:personal_worker/src/transcriber.dart';
import 'package:personal_worker/src/admin_guard.dart';
import 'package:personal_worker/src/local_sources.dart';
import 'package:personal_worker/src/journal_ready.dart';
import 'package:personal_worker/src/transcript_publication.dart';

final requestGuard = JournalAdminHttpClient();

Future<void> validateJournal(Room room) async {
  if (!room.encrypted ||
      room.membership != Membership.join ||
      room.getState(personalRoomMarker)?.content['schema'] !=
          personalSchemaVersion) {
    throw const WorkerFailure('invalid_private_journal');
  }
  final members = await room.requestParticipants([
    Membership.join,
    Membership.invite,
  ]);
  if (members.isEmpty || members.any((m) => m.id != room.client.userID)) {
    throw const WorkerFailure('journal_membership_changed');
  }
  requestGuard.journals.add(room.id);
}

Future<Room?> findJournal(Client client, WorkerConfig config) async {
  final pointer = client.accountData[personalRoomMarker]?.content['roomId'];
  final selected = config.journalRoomId.isNotEmpty
      ? config.journalRoomId
      : pointer;
  if (selected != null) {
    if (selected is! String) {
      throw const WorkerFailure('invalid_journal_pointer');
    }
    final room = client.getRoomById(selected);
    if (room == null) throw const WorkerFailure('journal_unavailable');
    await validateJournal(room);
    return room;
  }
  final candidates = client.rooms
      .where(
        (r) =>
            r.getState(personalRoomMarker)?.content['schema'] ==
            personalSchemaVersion,
      )
      .toList();
  if (candidates.length > 1) {
    throw const WorkerFailure('ambiguous_private_journal');
  }
  if (candidates.isEmpty) return null;
  await validateJournal(candidates.single);
  return candidates.single;
}

Future<Event> authenticatedReadBack(
  Client client,
  Room room,
  String eventId,
  Set<String> pins,
) async {
  await validateJournal(room);
  final raw = await client.getOneRoomEvent(room.id, eventId);
  if (raw.type != EventTypes.Encrypted || raw.senderId != client.userID) {
    throw const WorkerFailure('journal_result_not_encrypted');
  }
  final event = await client.encryption?.decryptRoomEvent(
    Event.fromMatrixEvent(raw, room),
  );
  // Proven by the megolm session that decrypted it, not the envelope key.
  final authenticated =
      event != null && await WorkerJournalTrust.verify(client, event, pins);
  if (!authenticated || event.type != personalEventType || event.redacted) {
    throw const WorkerFailure('journal_authenticated_decryption_unproven');
  }
  return event;
}

Future<void> pair(Client client, WorkerConfig config, String configFile) async {
  var room = await findJournal(client, config);
  final existed = room != null;
  if (room == null) {
    final id = await client.createRoom(
      name: 'ChatLoom — private sync',
      preset: CreateRoomPreset.privateChat,
      creationContent: {'m.federate': false},
      initialState: [
        StateEvent(
          type: EventTypes.Encryption,
          content: {'algorithm': 'm.megolm.v1.aes-sha2'},
        ),
        StateEvent(
          type: personalRoomMarker,
          content: {'schema': personalSchemaVersion},
        ),
      ],
    );
    room = await waitForJoinedJournal(client, id);
  }
  await validateJournal(room);
  await client.updateUserDeviceKeys(additionalUsers: {client.userID!});
  final pins =
      client.userDeviceKeys[client.userID]?.deviceKeys.values
          .where((d) => d.verified && !d.blocked && d.isValid)
          .map((d) => d.deviceId!)
          .toSet() ??
      <String>{};
  if (!pins.contains(client.deviceID)) {
    throw const WorkerFailure('device_verification_required');
  }
  await client.setAccountData(client.userID!, personalRoomMarker, {
    'roomId': room.id,
  });
  await room.setPushRuleState(PushRuleState.dontNotify);
  final op = PersonalOperation(
    opId: stableId('headless-pair', client.deviceID!),
    kind: 'worker.pairing',
    entityId: 'worker',
    createdAt: DateTime.now().toUtc(),
    payload: {'schema': personalSchemaVersion},
  );
  await validateJournal(room);
  final eventId = await room.sendEvent(
    op.toJson(),
    type: personalEventType,
    txid: stableId('headless-pair-event', op.opId),
    displayPendingEvent: false,
  );
  if (eventId == null) throw const WorkerFailure('pair_publication_unknown');
  final event = await authenticatedReadBack(client, room, eventId, pins);
  if (event.content['opId'] != op.opId) {
    throw const WorkerFailure('pair_readback_mismatch');
  }
  final value =
      jsonDecode(File(configFile).readAsStringSync()) as Map<String, dynamic>;
  value['journalRoomId'] = room.id;
  value['trustedDeviceIds'] = pins.toList()..sort();
  value['allowConversationSends'] = false;
  final target = path.join(config.stateDirectory, 'paired-config.json');
  if (File(target).existsSync()) {
    final previous =
        jsonDecode(File(target).readAsStringSync()) as Map<String, dynamic>;
    if (previous['journalRoomId'] != room.id ||
        jsonEncode(previous['trustedDeviceIds']) !=
            jsonEncode(value['trustedDeviceIds'])) {
      throw const WorkerFailure('paired_config_conflict');
    }
  } else {
    await writePrivateJson(target, value);
  }
  stdout.writeln(
    jsonEncode({
      'pairing': 'PASS',
      'existingJournal': existed,
      'verifiedOwnDevicesPinned': pins.length,
      'encryptedAuthenticatedReadBack': true,
    }),
  );
}

List<SourceEventRef> readSources(String file, String account) {
  requirePrivateFile(file);
  final value =
      jsonDecode(File(file).readAsStringSync()) as Map<String, dynamic>;
  final sources = (value['sources'] as List)
      .map((s) => SourceEventRef.fromJson(Map<String, dynamic>.from(s as Map)))
      .toList();
  if (sources.isEmpty ||
      sources.length > 3 ||
      sources.map((s) => s.key).toSet().length != sources.length ||
      sources.any(
        (s) =>
            s.conversation.accountId != account ||
            !s.conversation.roomId.startsWith('!') ||
            !s.eventId.startsWith(r'$'),
      )) {
    throw const WorkerFailure('invalid_acceptance_sources');
  }
  return sources;
}

Future<void> main(List<String> args) async {
  sanitizeLogs();
  RandomAccessFile? lock;
  Client? client;
  WorkerStore? store;
  try {
    if (args.length < 2 ||
        !{
          'inspect',
          'pair',
          'enqueue',
          'verify',
          'db-check',
        }.contains(args[0]) ||
        (args[0] == 'enqueue' || args[0] == 'verify') && args.length != 3) {
      throw const WorkerFailure('invalid_admin_arguments');
    }
    final config = WorkerConfig.read(args[1]);
    if (args[0] == 'db-check') {
      final file = path.join(config.stateDirectory, 'matrix.sqlite');
      if (!File(file).existsSync()) throw const WorkerFailure('backup_missing');
      final db = encryptedDatabase(
        file,
        readCredentials(config)['databaseCipher'] as String,
      );
      try {
        if (db.select('PRAGMA integrity_check').single.values.single != 'ok') {
          throw const WorkerFailure('backup_integrity_failed');
        }
        stdout.writeln('{"encryptedBackupIntegrity":"PASS"}');
      } finally {
        db.close();
      }
      return;
    }
    if (config.allowConversationSends) {
      throw const WorkerFailure('conversation_sends_must_be_disabled');
    }
    lock = File(
      path.join(config.stateDirectory, 'worker.lock'),
    ).openSync(mode: FileMode.append);
    lock.lockSync(FileLock.exclusive);
    client = await openSession(config, httpClient: requestGuard);
    if (!client.isLogged()) throw const WorkerFailure('enrollment_required');
    final matrixTransport = MatrixFeatureTransport(
      client,
      allowConversationSends: false,
    );
    final FeatureTransport transport = config.localSourceSocket == null
        ? matrixTransport
        : LocalSourceTransport(matrixTransport, config.localSourceSocket!);
    if (!transport.verified) {
      throw const WorkerFailure('device_verification_required');
    }
    if (args[0] == 'inspect') {
      final journal = await findJournal(client, config);
      stdout.writeln(
        jsonEncode({
          'sessionVerified': true,
          'journalFound': journal != null,
          'verifiedOwnDeviceCount':
              client.userDeviceKeys[client.userID]?.deviceKeys.values
                  .where((d) => d.verified && !d.blocked)
                  .length ??
              0,
        }),
      );
      return;
    }
    if (args[0] == 'pair') {
      await pair(client, config, args[1]);
      return;
    }
    final room = await findJournal(client, config);
    if (room == null || config.journalRoomId.isEmpty) {
      throw const WorkerFailure('journal_unavailable');
    }
    final credentials = readCredentials(config);
    store = WorkerStore(
      encryptedDatabase(
        path.join(config.stateDirectory, 'jobs.sqlite'),
        credentials['databaseCipher'] as String,
      ),
    );
    // Prove journal authentication without ticking jobs or invoking OpenAI.
    final engine = WorkerEngine(
      store,
      transport,
      OpenAiTranscriber('', temporaryRoot: config.temporaryDirectory),
    );
    final pins = config.trustedDeviceIds.toSet()..add(transport.deviceId);
    final journal = WorkerJournal(client, room.id, pins, store, engine);
    try {
      await journal.start();
      final sources = readSources(args[2], transport.accountId);
      final results = <Map<String, Object?>>[];
      for (final source in sources) {
        final id = stableId(
          'transcript',
          source.key,
        ).replaceFirst('transcript-', 'transcript:');
        final job = store.job(id);
        if (args[0] == 'enqueue') {
          if (job != null) {
            if (job['state'] == 'unknown') throw const PaidRequestUnknown();
            results.add({'state': job['state'], 'newRequest': false});
            continue;
          }
          final redacted = await transport.sourceRedacted(source);
          if (redacted != false) {
            throw const WorkerFailure('acceptance_source_unavailable');
          }
          final op = PersonalOperation(
            opId: stableId('headless-transcript-request', source.key),
            kind: 'transcript.request',
            entityId: id,
            createdAt: DateTime.now().toUtc(),
            payload: TranscriptionJob(
              id: id,
              source: source,
              state: JobState.queued,
            ).toJson(),
          );
          await validateJournal(room);
          final eventId = await room.sendEvent(
            op.toJson(),
            type: personalEventType,
            txid: stableId('headless-transcript-event', op.opId),
            displayPendingEvent: false,
          );
          if (eventId == null) {
            throw const WorkerFailure('request_publication_unknown');
          }
          final event = await authenticatedReadBack(
            client,
            room,
            eventId,
            pins,
          );
          if (event.content['opId'] != op.opId) {
            throw const WorkerFailure('request_readback_mismatch');
          }
          results.add({'state': 'published', 'newRequest': true});
        } else {
          if (job == null ||
              job['state'] != 'done' ||
              job['model'] != transcriptionModel ||
              job['text'] is! String ||
              (job['text'] as String).trim().isEmpty) {
            throw const WorkerFailure('transcript_not_done');
          }
          final publishedEvent = doneTranscriptEvent(store, job);
          if (publishedEvent == null) {
            throw const WorkerFailure('transcript_publication_unproven');
          }
          final event = await authenticatedReadBack(
            client,
            room,
            publishedEvent,
            pins,
          );
          final payload = event.content['payload'] as Map?;
          // A long transcript is published as a preview plus text slices;
          // its result names the whole text by length and digest.
          final parts = TranscriptTextParts.tryParse(payload?['textParts']);
          final textMatches = parts != null
              ? parts.matches(job['text'])
              : (payload?['text'] == job['text']);
          if (event.content['entityId'] != id ||
              event.content['kind'] != 'transcript.result' ||
              payload?['state'] != 'done' ||
              payload?['revision'] != job['revision'] ||
              !textMatches) {
            stderr.writeln(
              jsonEncode({
                'entityMatches': event.content['entityId'] == id,
                'doneStateMatches': payload?['state'] == 'done',
                'revisionMatches': payload?['revision'] == job['revision'],
                'textMatches': textMatches,
              }),
            );
            throw const WorkerFailure('transcript_readback_mismatch');
          }
          results.add({
            'state': 'done',
            'model': job['model'],
            'durationSeconds': job['durationSeconds'],
            'estimatedCostUsd': job['estimatedCostUsd'],
            'transcriptCharacters': (job['text'] as String).length,
            'encryptedAuthenticatedReadBack': true,
          });
        }
      }
      stdout.writeln(
        jsonEncode({
          'action': args[0],
          'results': results,
          'conversationSends': 0,
        }),
      );
    } finally {
      journal.dispose();
    }
  } on WorkerFailure catch (e) {
    stderr.writeln('Worker admin stopped: ${e.code}');
    exitCode = 1;
  } catch (e) {
    stderr.writeln('Worker admin stopped: ${e.runtimeType}');
    exitCode = 1;
  } finally {
    store?.close();
    if (client != null) await client.dispose();
    stdout.writeln(
      jsonEncode({
        'blockedActivity': requestGuard.blockedActivity,
        'encryptedJournalWrites': requestGuard.encryptedJournalWrites,
        'conversationSends': 0,
      }),
    );
    lock?.unlockSync();
    lock?.closeSync();
  }
}

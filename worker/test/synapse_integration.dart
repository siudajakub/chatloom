// SPDX-License-Identifier: AGPL-3.0-or-later
// Disposable localhost Synapse integration. No production account, files or API.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path;
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/config.dart';
import 'package:personal_worker/src/engine.dart';
import 'package:personal_worker/src/journal.dart';
import 'package:personal_worker/src/matrix_transport.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/runtime.dart';
import 'package:personal_worker/src/store.dart';
import 'package:personal_worker/src/reminder_relay.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vodozemac/vodozemac.dart' as vod;

final testServer = Uri.parse('http://127.0.0.1:18765/');

class IntegrationFailure implements Exception {
  final String stage;
  IntegrationFailure(this.stage);
}

void require(bool condition, String stage) {
  if (!condition) throw IntegrationFailure(stage);
}

class RequestRecorder extends http.BaseClient {
  final http.Client inner = http.Client();
  int syncs = 0;
  int offlineSyncs = 0;
  int forbiddenActivity = 0;
  int keyUploads = 0;
  int encryptedSends = 0;
  int plaintextSends = 0;
  final Map<String, int> sendsByTransaction = {};
  bool dropNextAcceptedSourceSend = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    require(
      request.url.scheme == 'http' &&
          request.url.host == '127.0.0.1' &&
          request.url.port == 18765,
      'non_loopback_request',
    );
    final p = request.url.path;
    if (p.endsWith('/sync')) {
      syncs++;
      if (request.url.queryParameters['set_presence'] == 'offline') {
        offlineSyncs++;
      }
    }
    if (p.contains('/read_markers') ||
        p.contains('/receipt/') ||
        p.contains('/typing/') ||
        p.contains('/presence/')) {
      forbiddenActivity++;
    }
    if (p.endsWith('/keys/upload')) keyUploads++;
    if (p.contains('/send/')) {
      final segments = request.url.pathSegments;
      final index = segments.indexOf('send');
      final type = segments[index + 1];
      sendsByTransaction.update(
        segments.last,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
      if (type == EventTypes.Encrypted) {
        encryptedSends++;
      } else {
        plaintextSends++;
      }
    }
    final response = await inner.send(request);
    if (dropNextAcceptedSourceSend && p.contains('/send/')) {
      dropNextAcceptedSourceSend = false;
      require(
        response.statusCode == 200,
        'synthetic_send_not_accepted_before_loss',
      );
      await response.stream.drain<void>();
      // HTTP succeeded on the server, but its response was lost to the caller.
      throw const SocketException('synthetic_response_lost');
    }
    return response;
  }

  @override
  void close() => inner.close();
}

class FixtureTranscriber implements Transcriber {
  int calls = 0;
  final Uint8List expected;
  FixtureTranscriber(this.expected);
  @override
  Future<TranscriptionResult> transcribe(
    AudioSource audio,
    String? language,
    Cancellation cancel,
    void Function(double, double) estimate,
  ) async {
    cancel.check();
    calls++;
    require(
      base64Encode(audio.bytes) == base64Encode(expected),
      'audio_bytes_not_decrypted',
    );
    estimate(1, 0.0045 / 60);
    return const TranscriptionResult('fixture transcription', 1, 0.0045 / 60);
  }
}

Future<void> eventually(
  FutureOr<bool> Function() condition,
  String stage, {
  Duration timeout = const Duration(seconds: 40),
}) async {
  final until = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(until)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw IntegrationFailure(stage);
}

Future<Map<String, dynamic>> fixtureJson(
  http.Client client,
  String route,
  Map<String, dynamic> body,
) async {
  final response = await client.post(
    testServer.resolve(route),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode(body),
  );
  final result = jsonDecode(response.body) as Map<String, dynamic>;
  if (response.statusCode == 401 && result['session'] is String) {
    final retry = await client.post(
      testServer.resolve(route),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        ...body,
        'auth': {'type': 'm.login.dummy', 'session': result['session']},
      }),
    );
    require(retry.statusCode == 200, 'fixture_registration_uia');
    return jsonDecode(retry.body) as Map<String, dynamic>;
  }
  require(response.statusCode == 200, 'fixture_registration_http');
  return result;
}

Future<Client> fixtureClient(
  String name,
  RequestRecorder recorder,
  Map<String, dynamic> login,
  String cipher,
  Directory directory,
) async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(
    ':memory:',
    options: OpenDatabaseOptions(
      singleInstance: false,
      onConfigure: (db) async {
        await db.execute("PRAGMA key = \"x'$cipher'\"");
        require(
          (await db.rawQuery('PRAGMA cipher_version')).isNotEmpty,
          'fixture_sqlcipher_missing',
        );
      },
    ),
  );
  final client = Client(
    name,
    httpClient: recorder,
    database: await MatrixSdkDatabase.init(
      name,
      database: db,
      sqfliteFactory: databaseFactoryFfi,
      maxFileSize: 0,
    ),
    shareKeysWith: ShareKeysWith.directlyVerifiedOnly,
    receiptsPublicByDefault: false,
    logLevel: Level.error,
    sendTimelineEventTimeout: const Duration(seconds: 6),
    importantStateEvents: {personalRoomMarker},
  );
  client.syncPresence = PresenceType.offline;
  await client.checkHomeserver(testServer, checkWellKnown: false);
  await client.init(
    newToken: login['access_token'] as String,
    newUserID: login['user_id'] as String,
    newDeviceID: login['device_id'] as String,
    newHomeserver: testServer,
  );
  await client.roomsLoading;
  await client.accountDataLoading;
  await client.userDeviceKeysLoading;
  return client;
}

Future<void> trustFixtures(Client sender, Client worker) async {
  for (final client in [sender, worker]) {
    client.userDeviceKeys[client.userID]?.outdated = true;
    await client.updateUserDeviceKeys(additionalUsers: {client.userID!});
  }
  await eventually(() async {
    for (final client in [sender, worker]) {
      final keys = client.userDeviceKeys[client.userID]?.deviceKeys;
      if (keys?.containsKey(sender.deviceID) != true ||
          keys?.containsKey(worker.deviceID) != true) {
        client.userDeviceKeys[client.userID]?.outdated = true;
        await client.updateUserDeviceKeys(additionalUsers: {client.userID!});
        return false;
      }
    }
    return true;
  }, 'fixture_device_keys_not_uploaded');
  // Explicit trust is limited to these two NEW disposable fixture devices.
  for (final client in [sender, worker]) {
    for (final device in [sender.deviceID!, worker.deviceID!]) {
      client.userDeviceKeys[client.userID]!.deviceKeys[device]!
          .setDirectVerified(true);
    }
  }
}

Future<Event> decryptedEvent(
  Room room,
  String eventId,
  String expectedType,
) async {
  Event? result;
  await eventually(() async {
    result = await room.getEventById(eventId);
    if (result?.type == EventTypes.Encrypted) {
      try {
        await result!.requestKey();
      } catch (_) {}
    }
    return result?.type == expectedType;
  }, 'event_decryption_timeout');
  require(
    result!.originalSource?.type == EventTypes.Encrypted,
    'event_not_encrypted_on_wire',
  );
  return result!;
}

Future<T> fixtureRateLimited<T>(Future<T> Function() action) async {
  final deadline = DateTime.now().add(const Duration(minutes: 2));
  while (true) {
    try {
      return await action();
    } on MatrixException catch (e) {
      if (e.errcode != 'M_LIMIT_EXCEEDED' || DateTime.now().isAfter(deadline)) {
        rethrow;
      }
      await Future<void>.delayed(
        Duration(milliseconds: (e.retryAfterMs ?? 2000).clamp(1, 30000)),
      );
    }
  }
}

Future<void> main() async {
  sanitizeLogs();
  String stage = 'preflight';
  final recorder = RequestRecorder();
  final senderRecorder = RequestRecorder();
  Client? sender;
  Client? worker;
  WorkerStore? store;
  WorkerEngine? engine;
  WorkerJournal? journal;
  Directory? directory;
  try {
    require(
      testServer.host == '127.0.0.1' && testServer.port == 18765,
      'server_guard',
    );
    final info = await recorder.get(
      testServer.resolve('_matrix/client/versions'),
    );
    require(info.statusCode == 200, 'disposable_server_not_ready');
    stage = 'crypto';
    await vod.init(
      libraryPath: '${Directory.current.path}/build/native/bundle/lib/',
    );
    directory = await Directory(
      '${Directory.current.path}/.runtime/integration',
    ).create(recursive: true);
    directory = await directory.createTemp('fixture-');
    final cipher = List.generate(
      32,
      (_) => Random.secure().nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    stage = 'registration';
    final username =
        'fixture_${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 30)}';
    final password = base64UrlEncode(
      List.generate(32, (_) => Random.secure().nextInt(256)),
    );
    final first =
        await fixtureJson(senderRecorder, '_matrix/client/v3/register', {
          'username': username,
          'password': password,
          'device_id': 'fixture_sender',
          'inhibit_login': false,
        });
    require(
      (first['user_id'] as String).endsWith(':personal.test'),
      'fixture_realm_mismatch',
    );
    final second = await fixtureJson(recorder, '_matrix/client/v3/login', {
      'type': 'm.login.password',
      'identifier': {'type': 'm.id.user', 'user': username},
      'password': password,
      'device_id': 'fixture_worker',
    });
    require(second['user_id'] == first['user_id'], 'fixture_account_mismatch');
    stage = 'clients';
    sender = await fixtureClient(
      'fixture-sender',
      senderRecorder,
      first,
      cipher,
      directory,
    );
    worker = await fixtureClient(
      'fixture-worker',
      recorder,
      second,
      cipher,
      directory,
    );
    require(
      sender.encryptionEnabled && worker.encryptionEnabled,
      'sdk_encryption_disabled',
    );
    await trustFixtures(sender, worker);
    stage = 'rooms';
    final sourceRoomId = await sender.createGroupChat(
      enableEncryption: true,
      federated: false,
      preset: CreateRoomPreset.privateChat,
    );
    final journalRoomId = await sender.createGroupChat(
      enableEncryption: true,
      federated: false,
      preset: CreateRoomPreset.privateChat,
      initialState: [
        StateEvent(
          type: personalRoomMarker,
          content: {'schema': personalSchemaVersion},
        ),
      ],
    );
    await eventually(
      () =>
          worker!.getRoomById(sourceRoomId) != null &&
          worker.getRoomById(journalRoomId) != null,
      'fixture_rooms_not_synced',
    );
    await trustFixtures(sender, worker);
    final sourceRoom = sender.getRoomById(sourceRoomId)!;
    final writerRoom = sender.getRoomById(journalRoomId)!;
    final workerRoom = worker.getRoomById(sourceRoomId)!;
    final readRoom = worker.getRoomById(journalRoomId)!;
    final audio = Uint8List.fromList(List.generate(4096, (i) => i % 251));
    stage = 'source_audio';
    final audioId = await sourceRoom.sendFileEvent(
      MatrixAudioFile(bytes: audio, name: 'fixture.wav', mimeType: 'audio/wav'),
      extraContent: {
        'org.matrix.msc3245.voice': {},
        'info': {'duration': 1000, 'size': audio.length},
      },
    );
    require(audioId != null, 'audio_send_failed');
    final received = await decryptedEvent(
      workerRoom,
      audioId!,
      EventTypes.Message,
    );
    require(
      received.content['file'] is Map &&
          received.messageType == MessageTypes.Audio,
      'audio_attachment_not_encrypted',
    );
    final downloaded = await received.downloadAndDecryptAttachment();
    require(
      base64Encode(downloaded.bytes) == base64Encode(audio),
      'source_audio_roundtrip',
    );
    stage = 'journal_pairing';
    final pairing = PersonalOperation(
      opId: 'fixture-pairing',
      kind: 'worker.pairing',
      entityId: 'worker',
      createdAt: DateTime.now(),
      payload: {},
    );
    final pairId = await writerRoom.sendEvent(
      Map<String, dynamic>.from(pairing.toJson()),
      type: personalEventType,
      txid: 'fixture-pairing',
    );
    require(pairId != null, 'pairing_send_failed');
    await decryptedEvent(readRoom, pairId!, personalEventType);
    // GET /event can decrypt before the long-poll sync has persisted that event.
    // WorkerJournal reads SDK timeline storage, so prove that exact boundary.
    final pairingTimeline = await readRoom.getTimeline();
    try {
      await eventually(
        () => pairingTimeline.events.any(
          (event) =>
              event.eventId == pairId &&
              event.type == personalEventType &&
              event.originalSource?.type == EventTypes.Encrypted,
        ),
        'pairing_not_persisted_in_sdk_sync',
      );
    } finally {
      pairingTimeline.cancelSubscriptions();
    }
    store = WorkerStore(
      encryptedDatabase(path.join(directory.path, 'jobs.sqlite'), cipher),
    );
    final transcriber = FixtureTranscriber(audio);
    engine = WorkerEngine(store, MatrixFeatureTransport(worker), transcriber);
    journal = WorkerJournal(
      worker,
      journalRoomId,
      {sender.deviceID!, worker.deviceID!},
      store,
      engine,
    );
    await journal.start();
    require(
      journal.authenticatedDecryptionSeen,
      'worker_check_decryption_not_proven',
    );
    require(
      store.hasCommand('fixture-pairing') &&
          store.outbox.any(
            (body) =>
                body['kind'] == 'worker.pairing.result' &&
                (body['payload'] as Map)['acceptedOpId'] == 'fixture-pairing',
          ),
      'pairing_ack_not_durable',
    );
    stage = 'metadata';
    final metadata = PersonalOperation(
      opId: 'fixture-metadata',
      kind: 'metadata.put',
      entityId: 'fixture-preference',
      createdAt: DateTime.now(),
      payload: {
        'value': {'setting': 'synthetic'},
      },
    );
    final metadataId = await writerRoom.sendEvent(
      Map<String, dynamic>.from(metadata.toJson()),
      type: personalEventType,
      txid: 'fixture-metadata',
    );
    await decryptedEvent(readRoom, metadataId!, personalEventType);
    await journal.reconcile();
    require(
      store.metadata('fixture-preference')?['revision'] == 1,
      'metadata_not_consumed',
    );
    await journal.flush();
    stage = 'transcript';
    final source = SourceEventRef(
      conversation: ConversationRef(
        accountId: worker.userID!,
        roomId: sourceRoomId,
      ),
      eventId: audioId,
    );
    final request = PersonalOperation(
      opId: 'fixture-transcript',
      kind: 'transcript.request',
      entityId: 'fixture-transcript',
      createdAt: DateTime.now(),
      payload: Map<String, dynamic>.from(
        TranscriptionJob(
          id: 'fixture-transcript',
          source: source,
          state: JobState.queued,
        ).toJson(),
      ),
    );
    final requestId = await writerRoom.sendEvent(
      Map<String, dynamic>.from(request.toJson()),
      type: personalEventType,
      txid: 'fixture-transcript',
    );
    await decryptedEvent(readRoom, requestId!, personalEventType);
    await journal.reconcile();
    await engine.tick();
    await engine.waitForIdle();
    require(
      store.job('fixture-transcript')?['state'] == 'done' &&
          transcriber.calls == 1,
      'mock_transcript_not_done',
    );
    await journal.flush();
    await journal.reconcile();
    await engine.tick();
    await engine.waitForIdle();
    require(transcriber.calls == 1, 'transcript_replay_duplicate');
    stage = 'schedule';
    final schedule = ScheduledSend(
      id: 'fixture-schedule',
      target: SendTarget(conversation: source.conversation),
      dueAt: DateTime.now(),
      content: {'msgtype': 'm.text', 'body': 'fixture scheduled text'},
      transactionId: 'caller-draft',
    );
    final command = PersonalOperation(
      opId: 'fixture-schedule-create',
      kind: 'schedule.create',
      entityId: schedule.id,
      createdAt: DateTime.now(),
      payload: Map<String, dynamic>.from(schedule.toJson()),
    );
    final commandId = await writerRoom.sendEvent(
      Map<String, dynamic>.from(command.toJson()),
      type: personalEventType,
      txid: 'fixture-schedule-create',
    );
    await decryptedEvent(readRoom, commandId!, personalEventType);
    await journal.reconcile();
    recorder.dropNextAcceptedSourceSend = true;
    await engine.tick();
    if (store.job(schedule.id)?['state'] == 'queued') await engine.tick();
    require(
      store.job(schedule.id)?['state'] == 'done',
      'scheduled_send_not_accepted',
    );
    final eventId = store.job(schedule.id)!['eventId'] as String;
    await decryptedEvent(sourceRoom, eventId, EventTypes.Message);
    final tx = store.job(schedule.id)!['transactionId'] as String;
    require(
      (recorder.sendsByTransaction[tx] ?? 0) >= 2,
      'lost_response_retry_not_exercised',
    );
    final duplicate = await MatrixFeatureTransport(
      worker,
    ).send(schedule.target, Map<String, dynamic>.from(schedule.content), tx);
    require(duplicate == eventId, 'same_transaction_created_duplicate');
    stage = 'reminder_durable_hint';
    final reminder = PersonalOperation(
      opId: 'fixture-reminder-create',
      kind: 'reminder.create',
      entityId: 'fixture-reminder',
      createdAt: DateTime.now(),
      payload: {
        'id': 'fixture-reminder',
        'conversation': source.conversation.toJson(),
        'dueAt': DateTime.now().toUtc().toIso8601String(),
        'untilReply': false,
      },
    );
    final reminderId = await writerRoom.sendEvent(
      Map<String, dynamic>.from(reminder.toJson()),
      type: personalEventType,
      txid: 'fixture-reminder-create',
    );
    await decryptedEvent(readRoom, reminderId!, personalEventType);
    await journal.reconcile();
    await engine.tick();
    require(
      store.job('fixture-reminder')?['state'] == 'done',
      'reminder_not_due',
    );
    require(store.reminderHints.isEmpty, 'wake_hint_before_journal_acceptance');
    await journal.flush();
    require(store.reminderHints.length == 1, 'reminder_hint_not_durable');
    await ReminderHintDelivery(store, null).flush();
    require(store.reminderHints.length == 1, 'missing_relay_hint_dropped');
    require(
      store.reminderHints.single.keys.toSet().difference({
        'hintId',
        'emittedAt',
      }).isEmpty,
      'hint_exposes_source_ids',
    );
    stage = 'heartbeat_and_results';
    final heartbeat = PersonalOperation(
      opId: 'fixture-heartbeat',
      kind: 'worker.heartbeat',
      entityId: 'worker',
      createdAt: DateTime.now(),
      payload: {'healthy': true, 'verified': true, 'pending': 0},
    );
    store.enqueue(heartbeat.opId, heartbeat.toJson());
    await journal.flush();
    final reader = await writerRoom.getTimeline();
    try {
      await eventually(
        () =>
            reader.events.any(
              (e) =>
                  e.type == personalEventType &&
                  e.content['kind'] == 'transcript.result' &&
                  (e.content['payload'] as Map?)?['state'] == 'done',
            ) &&
            reader.events.any(
              (e) =>
                  e.type == personalEventType &&
                  e.content['kind'] == 'worker.heartbeat',
            ),
        'result_decryption_not_observed',
      );
    } finally {
      reader.cancelSubscriptions();
    }
    stage = 'source_redaction_and_replicas';
    final textEvents = store.db
        .select(
          "SELECT event_id FROM transcript_publications WHERE entity_id=? AND text_bearing=1 AND event_id != ''",
          ['fixture-transcript'],
        )
        .map((row) => row['event_id'] as String)
        .toList();
    require(textEvents.isNotEmpty, 'published_text_ids_not_durable');
    // Model a process/connection loss after server acceptance but before the
    // store receives its ACK: retain only the pre-send intent and queued op.
    final lostResult = PersonalOperation(
      opId: 'fixture-lost-private-ack',
      kind: 'transcript.result',
      entityId: 'fixture-transcript',
      createdAt: DateTime.now(),
      baseRevision: store.job('fixture-transcript')!['revision'] as int,
      payload: Map<String, dynamic>.from(store.job('fixture-transcript')!),
    ).toJson();
    store.enqueue(lostResult['opId'] as String, lostResult);
    store.recordTranscriptPublicationIntent(
      Map<String, dynamic>.from(lostResult),
    );
    final lostAcceptedId = await readRoom.sendEvent(
      Map<String, dynamic>.from(lostResult),
      type: personalEventType,
      txid: stableId('journal', lostResult['opId'] as String),
      displayPendingEvent: false,
    );
    require(lostAcceptedId != null, 'lost_private_ack_fixture_not_accepted');
    textEvents.add(
      lostAcceptedId!,
    ); // Test evidence only, deliberately no ledger ACK.
    stage = 'source_redaction_request';
    await fixtureRateLimited(() => sourceRoom.redactEvent(audioId));
    stage = 'source_redaction_probe';
    require(
      await MatrixFeatureTransport(worker).sourceRedacted(source) == true,
      'fresh_source_redaction_not_confirmed',
    );
    stage = 'source_redaction_audit';
    await engine.auditTranscriptSources(force: true);
    require(
      store.job('fixture-transcript')?['state'] == 'cancelled' &&
          store.job('fixture-transcript')?['errorCode'] == 'source_redacted' &&
          store.job('fixture-transcript')?['text'] == null,
      'source_redaction_not_tombstoned',
    );
    await fixtureRateLimited(() => journal!.flush());
    stage = 'source_redaction_ack';
    require(
      store.pendingTranscriptRedactions.isEmpty,
      'private_text_redaction_not_acked',
    );
    for (final id in textEvents) {
      final raw = await worker.getOneRoomEvent(journalRoomId, id);
      require(
        Event.fromMatrixEvent(raw, readRoom).redacted,
        'old_private_text_still_available',
      );
    }
    for (final replicaRoom in [writerRoom, readRoom]) {
      final replica = await replicaRoom.getTimeline();
      try {
        await eventually(
          () => replica.events.any(
            (event) =>
                !event.redacted &&
                event.type == personalEventType &&
                event.content['kind'] == 'transcript.result' &&
                event.content['entityId'] == 'fixture-transcript' &&
                (event.content['payload'] as Map?)?['errorCode'] ==
                    'source_redacted' &&
                (event.content['payload'] as Map).containsKey('text') &&
                (event.content['payload'] as Map)['text'] == null,
          ),
          'two_clients_tombstone_not_observed',
        );
      } finally {
        replica.cancelSubscriptions();
      }
    }
    require(transcriber.calls == 1, 'redaction_triggered_paid_retry');
    require(recorder.forbiddenActivity == 0, 'worker_not_silent');
    require(
      recorder.syncs > 0 && recorder.syncs == recorder.offlineSyncs,
      'worker_presence_not_offline',
    );
    require(
      recorder.encryptedSends > 0 && recorder.plaintextSends == 0,
      'journal_or_send_plaintext',
    );
    stdout.writeln(
      'PASS: disposable two-device E2EE audio+journal, durable pairing ACK, metadata, mock transcript dedup, schedule response-loss+same-txid, durable reminder hint (no live push), heartbeat, source-redaction private-text recall+two-client tombstone, silent worker.',
    );
  } on MatrixException catch (e) {
    stderr.writeln('FAIL: $stage (${e.errcode})');
    exitCode = 1;
  } on WorkerFailure catch (e) {
    stderr.writeln('FAIL: $stage (${e.code})');
    exitCode = 1;
  } on IntegrationFailure catch (e) {
    stderr.writeln('FAIL: ${e.stage}');
    exitCode = 1;
  } catch (e) {
    stderr.writeln('FAIL: $stage (${e.runtimeType})');
    exitCode = 1;
  } finally {
    await engine?.shutdown();
    journal?.dispose();
    store?.close();
    await sender?.dispose();
    await worker?.dispose();
    recorder.close();
    senderRecorder.close();
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

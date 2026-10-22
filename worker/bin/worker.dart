// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption/utils/crypto_setup_extension.dart';
import 'package:path/path.dart' as path;
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/config.dart';
import 'package:personal_worker/src/engine.dart';
import 'package:personal_worker/src/heartbeat_schedule.dart';
import 'package:personal_worker/src/journal.dart';
import 'package:personal_worker/src/journal_session_rotation.dart';
import 'package:personal_worker/src/matrix_transport.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/runtime.dart';
import 'package:personal_worker/src/store.dart';
import 'package:personal_worker/src/transcriber.dart';
import 'package:personal_worker/src/reminder_relay.dart';
import 'package:personal_worker/src/transcription_check.dart';
import 'package:personal_worker/src/local_sources.dart';
import 'package:personal_worker/src/matrix_sources.dart';

Future<void> main(List<String> arguments) async {
  sanitizeLogs();
  RandomAccessFile? sessionLock;
  try {
    if (arguments.length != 2 ||
        !{
          'run',
          'enroll',
          'restore',
          'check',
          'native-check',
          'transcribe-check',
        }.contains(arguments[0])) {
      stderr.writeln(
        'Usage: worker <run|enroll|restore|check|native-check|transcribe-check> /absolute/config.json',
      );
      exitCode = 64;
      return;
    }
    final config = WorkerConfig.read(arguments[1]);
    await privateDirectory(config.stateDirectory);
    sessionLock = File(
      path.join(config.stateDirectory, 'worker.lock'),
    ).openSync(mode: FileMode.append);
    sessionLock.lockSync(FileLock.exclusive);
    if (arguments[0] == 'transcribe-check') {
      final credentials = readCredentials(config);
      final result = await checkTranscription(
        stdin,
        OpenAiTranscriber(
          credentials['openaiApiKey'] as String? ?? '',
          temporaryRoot: config.temporaryDirectory,
          requireCodecSandbox: config.requireCodecSandbox,
        ),
      );
      stdout.writeln(result);
      return;
    }
    if (arguments[0] == 'enroll') {
      await enroll(config);
      return;
    }
    if (arguments[0] == 'restore') {
      await restore(config);
      return;
    }
    if (arguments[0] == 'native-check' &&
        File(path.join(config.stateDirectory, 'matrix.sqlite')).existsSync()) {
      throw const WorkerFailure('synthetic_check_requires_empty_session');
    }
    MatrixLiveSources? liveSources;
    final client = await openSession(
      config,
      beforeInit:
          arguments[0] == 'run' &&
              config.autoTranscription &&
              config.autoTranscriptionMatrix
          ? (client) => liveSources = MatrixLiveSources(
              client,
              journalRoomId: config.journalRoomId,
            )..start()
          : null,
    );
    if (arguments[0] == 'native-check') {
      if (client.isLogged()) {
        await client.dispose();
        throw const WorkerFailure('synthetic_check_requires_empty_session');
      }
      final credentials = readCredentials(config);
      final db = encryptedDatabase(
        path.join(config.stateDirectory, 'jobs.sqlite'),
        credentials['databaseCipher'] as String,
      );
      final store = WorkerStore(db);
      store.setCheckpoint('native-check', 'ok');
      store.close();
      await client.dispose();
      stdout.writeln(
        'Native crypto and SQLCipher initialized; no account accessed.',
      );
      return;
    }
    try {
      if (!client.isLogged()) throw const WorkerFailure('enrollment_required');
      await client.roomsLoading;
      await client.accountDataLoading;
      await client.userDeviceKeysLoading;
      final matrixTransport = MatrixFeatureTransport(
        client,
        allowConversationSends: config.allowConversationSends,
      );
      final FeatureTransport transport = config.localSourceSocket == null
          ? matrixTransport
          : LocalSourceTransport(matrixTransport, config.localSourceSocket!);
      if (!transport.verified) {
        throw const WorkerFailure('device_verification_required');
      }
      final credentials = readCredentials(config);
      final store = WorkerStore(
        encryptedDatabase(
          path.join(config.stateDirectory, 'jobs.sqlite'),
          credentials['databaseCipher'] as String,
        ),
      );
      final engine = WorkerEngine(
        store,
        transport,
        OpenAiTranscriber(
          credentials['openaiApiKey'] as String? ?? '',
          temporaryRoot: config.temporaryDirectory,
          requireCodecSandbox: config.requireCodecSandbox,
        ),
        // Automatic transcription scans only explicitly configured local
        // sources, and only with the private operator switch (default off).
        recentSources: transport is LocalSourceTransport ? transport : null,
        liveSources: liveSources,
        autoTranscription: config.autoTranscription,
      );
      final devices = config.trustedDeviceIds.toSet()..add(transport.deviceId);
      final journal = WorkerJournal(
        client,
        config.journalRoomId,
        devices,
        store,
        engine,
      );
      final relayToken = credentials['reminderRelayToken'] as String? ?? '';
      final relay = config.reminderRelayUrl == null || relayToken.isEmpty
          ? null
          : HttpReminderWakeHintSink(
              url: config.reminderRelayUrl!,
              token: relayToken,
            );
      final reminderDelivery = ReminderHintDelivery(store, relay);
      try {
        await journal.start();
        if (arguments[0] == 'check') {
          stdout.writeln(
            'Encrypted private journal and verified session: PASS.',
          );
          return;
        }
        engine.recover();
        // The SDK keeps the id of the sync filter it defined first; a changed
        // worker filter (no typing, receipts or presence) is defined once.
        if (store.checkpoint('sync-filter') != workerSyncFilterVersion) {
          try {
            await client.redefineSyncFilter();
            store.setCheckpoint('sync-filter', workerSyncFilterVersion);
          } catch (_) {
            stderr.writeln('Sync filter update deferred');
          }
        }
        var stopping = false;
        final subscriptions = <StreamSubscription<ProcessSignal>>[];
        for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
          subscriptions.add(
            signal.watch().listen((_) {
              stopping = true;
              engine.cancelAll();
              if (transport is LocalSourceTransport) transport.close();
              relay?.close();
              client.stopNetwork();
            }),
          );
        }
        // One wait per loop iteration, ended by whichever source has news.
        // Each source future gets one listener for its whole life (before,
        // every 2-second wait added another to futures that complete only
        // on activity, tens of thousands a day).
        Completer<void>? currentWait;
        var wokenDuringCycle = false;
        void wakeLoop() {
          final wait = currentWait;
          currentWait = null;
          if (wait == null) {
            wokenDuringCycle = true;
          } else if (!wait.isCompleted) {
            wait.complete();
          }
        }

        Future<void>? watchedEngine, watchedLive;
        void watchSources() {
          final engineWake = engine.wakeup;
          if (!identical(engineWake, watchedEngine)) {
            watchedEngine = engineWake;
            unawaited(engineWake.then((_) => wakeLoop()));
          }
          final liveWake = liveSources?.wakeup;
          if (liveWake != null && !identical(liveWake, watchedLive)) {
            watchedLive = liveWake;
            unawaited(liveWake.then((_) => wakeLoop()));
          }
        }

        // New room keys (to-device) let jobs of that room waiting for keys
        // try again at once; keys for other rooms wake nothing.
        final keyRooms = <String>{};
        final keyWatch = client.onToDeviceEvent.stream
            .where(
              (event) =>
                  event.type == EventTypes.RoomKey ||
                  event.type == EventTypes.ForwardedRoomKey,
            )
            .listen((event) {
              final room = event.content['room_id'];
              if (room is! String || keyRooms.contains(room)) return;
              try {
                if (!engine.waitsForKeys(room)) return;
              } catch (_) {
                return;
              }
              keyRooms.add(room);
              wakeLoop();
            });
        final heartbeats = HeartbeatSchedule();
        // A fresh journal session at start and daily, so app devices added
        // since can trust worker results soon (journal_session_rotation).
        final sessionRotation = JournalSessionRotation(
          SdkOutboundSession(client, config.journalRoomId),
        );
        DateTime? rotationFailingSince;

        /// Runs one loop step; a failure is logged (code only) and never
        /// skips the steps after it. Journal loss is fatal as before.
        Future<void> step(Future<void> Function() action) async {
          try {
            await action();
          } on WorkerFailure catch (e) {
            if (stopping) return;
            if (e.code == 'journal_membership_changed' ||
                e.code == 'journal_marker_missing' ||
                e.code == 'journal_unavailable') {
              rethrow;
            }
            stderr.writeln('Worker cycle deferred: ${e.code}');
          } catch (_) {
            if (stopping) return;
            stderr.writeln(
              'Worker cycle deferred: connection_or_storage_error',
            );
          }
        }

        try {
          while (!stopping) {
            await step(() async {
              await journal.reconcile();
              if (stopping) return;
              await engine.auditTranscriptSources();
              if (stopping) return;
              await engine.autoScan();
              if (stopping) return;
              if (keyRooms.isNotEmpty) {
                final rooms = {...keyRooms};
                keyRooms.clear();
                engine.retryWaitingKeys(rooms: rooms);
              }
              await engine.tick();
            });
            if (stopping) break;
            await step(() async {
              final at = DateTime.now().toUtc();
              final parked = store.parkedCount;
              final heartbeatPayload = <String, dynamic>{
                'healthy': true,
                'verified': transport.verified,
                if (config.requireCodecSandbox)
                  'transcription': 'blocked_codec_sandbox',
                'autoTranscription': engine.autoScanActive ? 'scan' : 'off',
                // Worker capabilities for app-side gating: media kinds 2 =
                // voice, round, any video and audio (also as files); 3 = also
                // Instagram reels as their own kind (on demand by default);
                // live = cloud rooms are picked up from the worker's own sync.
                'transcriptionMedia': 3,
                'autoTranscriptionLive': engine.liveScanActive,
                'reminderPush': reminderDelivery.configured
                    ? 'configured'
                    : 'not_configured',
                'pendingReminderHints': store.reminderHints.length,
                'pending': store.pendingJobCount,
                // Results the homeserver refused for good (content-free).
                if (parked > 0) 'parkedResults': parked,
              };
              if (heartbeats.due(at, heartbeatPayload)) {
                final heartbeat = PersonalOperation(
                  opId: stableId('heartbeat', at.toIso8601String()),
                  kind: 'worker.heartbeat',
                  entityId: 'worker',
                  createdAt: at,
                  payload: heartbeatPayload,
                );
                store.enqueue(heartbeat.opId, heartbeat.toJson());
                heartbeats.sent(at, heartbeatPayload);
              }
            });
            if (stopping) break;
            // Publication runs on every cycle, whatever failed above.
            await step(() async {
              try {
                final rotated = await sessionRotation.rotateIfDue();
                rotationFailingSince = null;
                if (rotated != null) {
                  stderr.writeln('Journal session rotated: ${rotated.name}');
                }
              } on WorkerFailure {
                // Results published under an old session cannot be trusted
                // by devices added since, so publication waits for the
                // rotation, but not forever.
                final since = rotationFailingSince ??= DateTime.now();
                if (DateTime.now().difference(since) <
                    const Duration(minutes: 10)) {
                  rethrow;
                }
              }
              await journal.flush();
            });
            if (stopping) break;
            await step(reminderDelivery.flush);
            if (!stopping) {
              // Event driven: a received message (live feed), a finished
              // transcript or reminder check (result to publish) or a
              // useful room key ends the wait at once.
              watchSources();
              if (wokenDuringCycle) {
                wokenDuringCycle = false;
                continue;
              }
              final wait = currentWait = Completer<void>();
              final timer = Timer(const Duration(seconds: 2), wakeLoop);
              await wait.future;
              timer.cancel();
              wokenDuringCycle = false;
            }
          }
        } finally {
          await keyWatch.cancel();
          await liveSources?.close();
          await engine.shutdown();
          for (final subscription in subscriptions) {
            await subscription.cancel();
          }
        }
      } finally {
        if (transport is LocalSourceTransport) transport.close();
        relay?.close();
        journal.dispose();
        store.close();
      }
    } finally {
      await client.dispose();
    }
  } on WorkerFailure catch (e) {
    stderr.writeln('Worker stopped: ${e.code}');
    exitCode = 1;
  } catch (_) {
    stderr.writeln('Worker stopped: initialization_or_connection_error');
    exitCode = 1;
  } finally {
    if (sessionLock != null) {
      sessionLock.unlockSync();
      sessionLock.closeSync();
    }
  }
}

String secretInput(String label) {
  stderr.write('$label: ');
  final terminal = stdin.hasTerminal;
  if (!terminal) throw const WorkerFailure('interactive_terminal_required');
  final echo = terminal ? stdin.echoMode : true;
  if (terminal) stdin.echoMode = false;
  try {
    return stdin.readLineSync()?.trim() ?? '';
  } finally {
    if (terminal) {
      stdin.echoMode = echo;
      stderr.writeln();
    }
  }
}

Future<void> enroll(WorkerConfig config) async {
  // An interrupted login may leave an anonymous encrypted SDK database. Open
  // it with its existing cipher; never replace credentials or reset its state.
  final existingDatabase =
      Directory(config.stateDirectory).existsSync() &&
      Directory(
        config.stateDirectory,
      ).listSync().any((f) => f.path.endsWith('.sqlite'));
  if (existingDatabase && !File(config.credentialsPath).existsSync()) {
    throw const WorkerFailure('existing_session_credentials_required');
  }
  if (!File(config.credentialsPath).existsSync()) {
    final cipher = List.generate(
      32,
      (_) => Random.secure().nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await writePrivateJson(config.credentialsPath, {
      'databaseCipher': cipher,
      'openaiApiKey': secretInput('OpenAI API key (blank to add later)'),
    });
  }
  final client = await openSession(config);
  try {
    if (File(path.join(config.stateDirectory, 'pairing.json')).existsSync()) {
      throw const WorkerFailure('existing_session_use_restore');
    }
    if (!client.isLogged()) {
      final server = secretInput('Matrix homeserver HTTPS URL');
      final uri = Uri.parse(server);
      if (uri.scheme != 'https') {
        throw const WorkerFailure('https_homeserver_required');
      }
      final user = secretInput('Matrix user ID');
      final password = secretInput('Matrix password');
      await client.checkHomeserver(uri);
      await client.login(
        LoginType.mLoginPassword,
        identifier: AuthenticationUserIdentifier(user: user),
        password: password,
        initialDeviceDisplayName: 'Personal feature worker',
      );
    }
    final recovery = secretInput('Existing recovery key (no reset)');
    if (recovery.isEmpty) throw const WorkerFailure('recovery_required');
    await client.restoreCryptoIdentity(recovery);
    await client.roomsLoading;
    await client.accountDataLoading;
    await client.userDeviceKeysLoading;
    if (!MatrixFeatureTransport(client).verified) {
      throw const WorkerFailure('device_verification_required');
    }
    // Device ID is written to a private pairing file, never printed or logged.
    await writePrivateJson(path.join(config.stateDirectory, 'pairing.json'), {
      'workerDeviceId': client.deviceID,
      'userId': client.userID,
      'journalRoomId': config.journalRoomId,
    });
    stdout.writeln(
      'Session enrolled. Use the private pairing file to finish journal pairing; prove decryption before enabling sends.',
    );
  } finally {
    await client.dispose();
  }
}

Future<void> restore(WorkerConfig config) async {
  final client = await openSession(config);
  try {
    if (!client.isLogged()) throw const WorkerFailure('enrollment_required');
    final recovery = secretInput('Existing recovery key (no reset)');
    if (recovery.isEmpty) throw const WorkerFailure('recovery_required');
    await client.restoreCryptoIdentity(recovery);
    stdout.writeln(
      'Existing session restored; prove journal decryption with check.',
    );
  } finally {
    await client.dispose();
  }
}

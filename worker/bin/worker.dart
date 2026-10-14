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
import 'package:personal_worker/src/journal.dart';
import 'package:personal_worker/src/matrix_transport.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/runtime.dart';
import 'package:personal_worker/src/store.dart';
import 'package:personal_worker/src/transcriber.dart';
import 'package:personal_worker/src/reminder_relay.dart';

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
        }.contains(arguments[0])) {
      stderr.writeln(
        'Usage: worker <run|enroll|restore|check|native-check> /absolute/config.json',
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
    final client = await openSession(config);
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
      final transport = MatrixFeatureTransport(client);
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
      final reminderDelivery = ReminderHintDelivery(
        store,
        config.reminderRelayUrl == null || relayToken.isEmpty
            ? null
            : HttpReminderWakeHintSink(
                url: config.reminderRelayUrl!,
                token: relayToken,
              ),
      );
      try {
        await journal.start();
        if (arguments[0] == 'check') {
          stdout.writeln(
            'Encrypted private journal and verified session: PASS.',
          );
          return;
        }
        engine.recover();
        var stopping = false;
        final subscriptions = <StreamSubscription<ProcessSignal>>[];
        for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
          subscriptions.add(
            signal.watch().listen((_) {
              stopping = true;
              engine.cancelAll();
            }),
          );
        }
        var heartbeatAt = DateTime.fromMillisecondsSinceEpoch(0);
        try {
          while (!stopping) {
            try {
              await journal.reconcile();
              await engine.auditTranscriptSources();
              await engine.tick();
              if (DateTime.now().difference(heartbeatAt) >
                  const Duration(minutes: 1)) {
                final at = DateTime.now().toUtc();
                final heartbeat = PersonalOperation(
                  opId: stableId('heartbeat', at.toIso8601String()),
                  kind: 'worker.heartbeat',
                  entityId: 'worker',
                  createdAt: at,
                  payload: {
                    'healthy': true,
                    'verified': transport.verified,
                    if (config.requireCodecSandbox)
                      'transcription': 'blocked_codec_sandbox',
                    'reminderPush': reminderDelivery.configured
                        ? 'configured'
                        : 'not_configured',
                    'pendingReminderHints': store.reminderHints.length,
                    'pending': store
                        .jobs()
                        .where(
                          (j) => !{
                            'done',
                            'cancelled',
                            'failed',
                          }.contains(j['state']),
                        )
                        .length,
                  },
                );
                store.enqueue(heartbeat.opId, heartbeat.toJson());
                heartbeatAt = at;
              }
              await journal.flush();
              await reminderDelivery.flush();
            } on WorkerFailure catch (e) {
              if (e.code == 'journal_membership_changed' ||
                  e.code == 'journal_marker_missing' ||
                  e.code == 'journal_unavailable') {
                rethrow;
              }
              stderr.writeln('Worker cycle deferred: ${e.code}');
            } catch (_) {
              stderr.writeln(
                'Worker cycle deferred: connection_or_storage_error',
              );
            }
            await Future<void>.delayed(const Duration(seconds: 2));
          }
        } finally {
          await engine.shutdown();
          for (final subscription in subscriptions) {
            await subscription.cancel();
          }
        }
      } finally {
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
  // Existing state is never reset or recreated by enrollment.
  if (Directory(config.stateDirectory).existsSync() &&
      Directory(
        config.stateDirectory,
      ).listSync().any((f) => f.path.endsWith('.sqlite'))) {
    throw const WorkerFailure('existing_session_use_restore');
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

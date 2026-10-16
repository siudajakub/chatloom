// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vodozemac/vodozemac.dart' as vod;
import 'package:http/http.dart' as http;
import 'config.dart';
import 'ports.dart';

Future<void> privateDirectory(String directory) async {
  await Directory(directory).create(recursive: true);
  if (!Platform.isWindows) {
    final result = await Process.run('chmod', ['700', directory]);
    if (result.exitCode != 0) {
      throw const WorkerFailure('directory_permissions');
    }
  }
}

void sanitizeLogs() {
  Logs().sanitize = (event) => LogEvent(
    'diagnostic:${event.level.name}',
    exception: event.exception?.runtimeType.toString(),
    level: event.level,
  );
  Logs().level = Level.error;
  Logs().nativeColors = false;
}

Future<Client> openSession(
  WorkerConfig config, {
  http.Client? httpClient,
}) async {
  sanitizeLogs();
  final credentials = readCredentials(config);
  final cipher = credentials['databaseCipher'] as String;
  if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(cipher)) {
    throw const WorkerFailure('invalid_database_cipher');
  }
  await privateDirectory(config.stateDirectory);
  await privateDirectory(config.temporaryDirectory);
  // Orphaned plaintext audio is confined to this private transient directory.
  for (final file in Directory(config.temporaryDirectory).listSync()) {
    if (file is Directory && path.basename(file.path).startsWith('audio-')) {
      file.deleteSync(recursive: true);
    }
  }
  try {
    await vod.init(
      libraryPath:
          '${path.normalize(config.nativeLibraryDirectory)}${Platform.pathSeparator}',
    );
  } catch (e) {
    throw WorkerFailure('native_crypto_init_${e.runtimeType}');
  }
  final group = vod.GroupSession();
  final inbound = group.toInbound();
  if (inbound.decrypt(group.encrypt('synthetic-native-roundtrip')).plaintext !=
      'synthetic-native-roundtrip') {
    throw const WorkerFailure('native_crypto_self_check_failed');
  }
  sqfliteFfiInit();
  final database = await databaseFactoryFfi
      .openDatabase(
        path.join(config.stateDirectory, 'matrix.sqlite'),
        options: OpenDatabaseOptions(
          singleInstance: false,
          onConfigure: (db) async {
            await db.execute("PRAGMA key = \"x'$cipher'\"");
            if ((await db.rawQuery('PRAGMA cipher_version')).isEmpty) {
              throw const WorkerFailure('sqlcipher_unavailable');
            }
            await db.rawQuery('SELECT count(*) FROM sqlite_master');
          },
        ),
      )
      .catchError(
        (Object e) => throw WorkerFailure('session_database_${e.runtimeType}'),
      );
  final sdkDatabase = await MatrixSdkDatabase.init(
    'personal-feature-worker',
    database: database,
    sqfliteFactory: databaseFactoryFfi,
    maxFileSize: 0,
  );
  final client = Client(
    'personal-feature-worker',
    database: sdkDatabase,
    httpClient: httpClient,
    logLevel: Level.error,
    receiptsPublicByDefault: false,
    shareKeysWith: ShareKeysWith.crossVerified,
    sendTimelineEventTimeout: const Duration(seconds: 30),
    onSoftLogout: (c) => c.refreshAccessToken(),
    importantStateEvents: {personalJournalMarker},
  );
  client.syncPresence = PresenceType.offline;
  try {
    await client.init(
      waitForFirstSync: false,
      preserveSessionOnInitFailure: true,
    );
    // Keep network failures outside local restore so they cannot clear the
    // encrypted session, while retaining the worker's fresh-sync startup gate.
    if (client.isLogged()) await client.firstSyncReceived;
  } catch (_) {
    await client.dispose();
    throw const WorkerFailure('session_init_failed');
  }
  return client;
}

// Used only for preserving the room marker in SDK sync; wire value is frozen.
const personalJournalMarker = 'pl.personal.client.journal.v1';

Future<void> writePrivateJson(
  String filename,
  Map<String, dynamic> value,
) async {
  await privateDirectory(path.dirname(filename));
  final file = File(filename);
  if (file.existsSync()) throw const WorkerFailure('refuse_overwrite');
  // Create under umask 077 in launcher; set private mode before writing bytes.
  await file.create();
  if (!Platform.isWindows) await Process.run('chmod', ['600', filename]);
  await file.writeAsString(jsonEncode(value), flush: true);
}

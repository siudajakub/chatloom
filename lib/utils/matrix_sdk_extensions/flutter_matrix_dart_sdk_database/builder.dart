// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/media/protected_matrix_database.dart';
import 'package:chatloom/personal/performance_probe.dart';
import 'package:chatloom/personal/storage/database_policy.dart';
import 'package:chatloom/personal/storage/storage_failure.dart';
import 'package:chatloom/utils/client_manager.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_foundation/path_provider_foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:universal_html/html.dart' as html;

import 'cipher.dart';
import 'vacuum.dart';

Future<DatabaseApi> flutterMatrixSdkDatabaseBuilder(String clientName) async {
  try {
    return await preserveOnStorageFailure(() => _constructDatabase(clientName));
  } catch (e) {
    final failure = e is StorageFailure
        ? e
        : const StorageFailure(StorageFailureCode.databaseUnavailable);
    Logs().e('Protected storage initialization failed: ${failure.code.name}');

    try {
      // Send error notification:
      final l10n = await lookupL10n(AppConfig.appLocale);
      // We expect that the database cannot be open on iOS 2.8.0 due to that
      // the team ID has changed and te app can no longer access the database
      // key in the iOS keychain. This should be removed from 2.9.0 on.
      if (!PlatformInfos.isIOS) {
        ClientManager.sendInitNotification(
          l10n.initAppError,
          'Protected storage is unavailable (${failure.code.name}). '
          'Your local data was preserved. Retry when secure storage is available.',
        );
      }
    } catch (_) {
      Logs().e('Unable to show protected storage notification');
    }

    // Never delete the database or reset the encryption key after a failure.
    throw failure;
  }
}

Future<Directory?> getFileStorageLocation() async {
  try {
    late final Directory temporaryDirectory;
    if (PlatformInfos.isIOS) {
      final containerPath = await PathProviderFoundation().getContainerPath(
        appGroupIdentifier: 'group.im.fluffychat.app',
      );
      temporaryDirectory = Directory(containerPath!);
    } else if (PlatformInfos.isLinux) {
      temporaryDirectory = await getApplicationCacheDirectory();
    } else {
      temporaryDirectory = await getTemporaryDirectory();
    }
    return await Directory(
      join(temporaryDirectory.path, 'fluffychat_download_cache'),
    ).create(recursive: true);
  } on MissingPlatformDirectoryException catch (_) {
    Logs().w(
      'No temporary directory for file cache available on this platform.',
    );
  }
  return null;
}

Future<MatrixSdkDatabase> _constructDatabase(String clientName) async {
  if (kIsWeb) {
    html.window.navigator.storage?.persist();
    return await MatrixSdkDatabase.init(clientName);
  }

  // Path resolution can consult getDatabasesPath for an existing installation.
  // Initialize the FFI factory before any global sqflite helper is called.
  final factory = createDatabaseFactoryFfi();
  databaseFactory = factory;
  final path = await _resolveDatabasePath(clientName);
  await requireEncryptedDatabaseFile(path);
  final keyLock = await File(
    join(dirname(path), 'matrix-key-init.lock'),
  ).open(mode: FileMode.append);
  late final String cipher;
  try {
    await keyLock.lock(FileLock.blockingExclusive);
    final requireExisting = await _hasExistingMatrixDatabase(dirname(path));
    cipher = await PersonalPerformanceProbe.time(
      'db.key.matrix',
      () => getDatabaseCipher(requireExisting: requireExisting),
    );
  } finally {
    await keyLock.close();
  }

  final helper = SQfLiteEncryptionHelper(
    factory: factory,
    path: path,
    cipher: cipher,
  );

  // Includes the SQLCipher key derivation (first query in onConfigure).
  final opening = Stopwatch()..start();
  final database = await factory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 1,
      // most important : apply encryption when opening the DB
      onConfigure: (db) async {
        await helper.applyPragmaKey(db);
        // Keeps a reserve of free pages instead of releasing all on every
        // open (startup and push wakes); see vacuum.dart.
        await prepareIncrementalAutoVacuum(db);
      },
    ),
  );

  PersonalPerformanceProbe.record('db.open.matrix', opening.elapsed);

  final matrixDatabase = ProtectedMatrixDatabase(
    clientName,
    database: database,
    factory: factory,
    maxFileSize: 1000 * 1000 * 10,
  );
  await matrixDatabase.open();
  return matrixDatabase;
}

Future<String> _getDatabaseDirectory() async {
  if (PlatformInfos.isIOS) {
    final containerPath = await PathProviderFoundation().getContainerPath(
      appGroupIdentifier: 'group.im.fluffychat.app',
    );
    if (containerPath == null) {
      Logs().w('No container path found for iOS app!');
      return (await getLibraryDirectory()).path;
    }
    return containerPath;
  }
  if (PlatformInfos.isMacOS) {
    return (await getLibraryDirectory()).path;
  }
  return (await getApplicationSupportDirectory()).path;
}

Future<String> _getDatabasePath(String clientName) async {
  final databaseDirectory = await _getDatabaseDirectory();

  return join(databaseDirectory, '$clientName.sqlite');
}

Future<bool> _hasExistingMatrixDatabase(String directory) async {
  await for (final entry in Directory(directory).list(followLinks: false)) {
    if (entry is File &&
        entry.path.endsWith('.sqlite') &&
        basename(entry.path) != 'personal_v1.sqlite') {
      return true;
    }
  }
  return false;
}

Future<String> _resolveDatabasePath(String clientName) async {
  final sqlFilePath = await _getDatabasePath(clientName);
  if (await File(sqlFilePath).exists()) return sqlFilePath;
  final oldPath = PlatformInfos.isDesktop
      ? (await getApplicationSupportDirectory()).path
      : PlatformInfos.isIOS
      ? (await getLibraryDirectory()).path
      : PlatformInfos.isAndroid
      // Android's legacy native database directory is beside files/, whereas
      // the FFI default is a working-directory-relative desktop path.
      ? join(dirname(dirname(sqlFilePath)), 'databases')
      : await getDatabasesPath();

  final oldFilePath = join(oldPath, '$clientName.sqlite');
  // Preserve a previous location without copying/deleting files implicitly.
  if (await File(oldFilePath).exists()) return oldFilePath;
  await Directory(dirname(sqlFilePath)).create(recursive: true);
  return sqlFilePath;
}

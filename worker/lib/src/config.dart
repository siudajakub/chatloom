// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';
import 'ports.dart';
import 'reminder_relay.dart';

class WorkerConfig {
  final String stateDirectory;
  final String temporaryDirectory;
  final String credentialsPath;
  final String journalRoomId;
  final List<String> trustedDeviceIds;
  final String nativeLibraryDirectory;
  final Uri? reminderRelayUrl;
  final bool requireCodecSandbox;
  final bool allowConversationSends;
  final String? localSourceSocket;
  WorkerConfig({
    required this.stateDirectory,
    required this.temporaryDirectory,
    required this.credentialsPath,
    required this.journalRoomId,
    required this.trustedDeviceIds,
    required this.nativeLibraryDirectory,
    this.reminderRelayUrl,
    this.requireCodecSandbox = false,
    this.allowConversationSends = true,
    this.localSourceSocket,
  });
  factory WorkerConfig.read(String filename) {
    final value =
        jsonDecode(File(filename).readAsStringSync()) as Map<String, dynamic>;
    final state = value['stateDirectory'] as String;
    final temporary = value['temporaryDirectory'] as String;
    final credential = value['credentialsPath'] as String;
    final relayValue = value['reminderRelayUrl'] as String?;
    final sourceSocket = value['localSourceSocket'] as String?;
    if (sourceSocket != null &&
        (!path.isAbsolute(sourceSocket) ||
            !path.isWithin('/run', sourceSocket))) {
      throw const WorkerFailure('invalid_local_source_socket');
    }
    final relay = relayValue == null || relayValue.isEmpty
        ? null
        : Uri.parse(relayValue);
    if (relay != null && !allowedReminderRelayUrl(relay)) {
      throw const WorkerFailure('invalid_reminder_relay_url');
    }
    if (!path.isAbsolute(state) ||
        !path.isAbsolute(temporary) ||
        !path.isAbsolute(credential)) {
      throw const WorkerFailure('absolute_paths_required');
    }
    return WorkerConfig(
      stateDirectory: state,
      temporaryDirectory: temporary,
      credentialsPath: credential,
      reminderRelayUrl: relay,
      requireCodecSandbox: value['requireCodecSandbox'] as bool? ?? false,
      allowConversationSends: value['allowConversationSends'] as bool? ?? true,
      localSourceSocket: sourceSocket,
      journalRoomId: value['journalRoomId'] as String? ?? '',
      trustedDeviceIds: (value['trustedDeviceIds'] as List? ?? [])
          .cast<String>(),
      nativeLibraryDirectory:
          value['nativeLibraryDirectory'] as String? ??
          path.join(path.dirname(Platform.resolvedExecutable), '..', 'lib'),
    );
  }
}

void requirePrivateFile(String filename) {
  final stat = File(filename).statSync();
  if (stat.type != FileSystemEntityType.file || stat.mode & 0x3f != 0) {
    throw const WorkerFailure('credentials_permissions');
  }
}

Map<String, dynamic> readCredentials(WorkerConfig config) {
  requirePrivateFile(config.credentialsPath);
  return jsonDecode(File(config.credentialsPath).readAsStringSync())
      as Map<String, dynamic>;
}

/// Never silently opens SQLite when SQLCipher or its key is unavailable.
Database encryptedDatabase(String filename, String cipher) {
  if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(cipher)) {
    throw const WorkerFailure('invalid_database_cipher');
  }
  final db = sqlite3.open(filename);
  try {
    db.execute("PRAGMA key = \"x'$cipher'\"");
    final cipherVersion = db.select('PRAGMA cipher_version');
    if (cipherVersion.isEmpty) {
      throw const WorkerFailure('sqlcipher_unavailable');
    }
    db.select('SELECT count(*) FROM sqlite_master');
    return db;
  } catch (_) {
    db.close();
    rethrow;
  }
}

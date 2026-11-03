// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';
import 'ports.dart';
import 'reminder_relay.dart';
import 'transcript_timestamps.dart';

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

  /// Operator opt-in for worker-side automatic transcription. Only effective
  /// together with the synced user policy. Sources: [localSourceSocket]
  /// (local bridge rooms) and, unless [autoTranscriptionMatrix] is false,
  /// the worker's own Matrix sync (cloud rooms).
  final bool autoTranscription;

  /// Lets the operator keep automatic work to local sources only.
  final bool autoTranscriptionMatrix;

  /// The provider and speech model (`transcriptionProvider` and
  /// `transcriptionModel` in the config). Default: `x-ai/grok-stt-1.0`
  /// through OpenRouter, whose one request also returns segment and word
  /// timestamps for the live transcript view. `openai` keeps
  /// `gpt-transcribe` (its default, no timestamps) or `whisper-1`; switching
  /// back is a config change.
  final TranscriptionModel transcriptionModel;
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
    this.autoTranscription = false,
    this.autoTranscriptionMatrix = true,
    this.transcriptionModel = TranscriptionModel.standard,
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
    final model = transcriptionModelOf(
      value['transcriptionProvider'],
      value['transcriptionModel'],
    );
    return WorkerConfig(
      stateDirectory: state,
      temporaryDirectory: temporary,
      credentialsPath: credential,
      reminderRelayUrl: relay,
      requireCodecSandbox: value['requireCodecSandbox'] as bool? ?? false,
      allowConversationSends: value['allowConversationSends'] as bool? ?? true,
      localSourceSocket: sourceSocket,
      autoTranscription: value['autoTranscription'] as bool? ?? false,
      autoTranscriptionMatrix:
          value['autoTranscriptionMatrix'] as bool? ?? true,
      transcriptionModel: model,
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

/// The model a config selects with `transcriptionProvider` and
/// `transcriptionModel`, both optional: neither selects
/// [TranscriptionModel.standard] (Grok through OpenRouter), a provider alone
/// its default model, a model alone that model and its provider. A model of
/// another provider, or an unknown name, refuses to start.
TranscriptionModel transcriptionModelOf(
  Object? providerName,
  Object? modelName,
) {
  TranscriptionProvider? provider;
  if (providerName != null) {
    provider = TranscriptionProvider.byName(providerName);
    if (provider == null) {
      throw const WorkerFailure('invalid_transcription_provider');
    }
  }
  if (modelName == null) {
    return provider == null
        ? TranscriptionModel.standard
        : TranscriptionModel.defaultFor(provider);
  }
  final model = modelName is String
      ? TranscriptionModel.byName(modelName, provider: provider)
      : null;
  if (model == null) throw const WorkerFailure('invalid_transcription_model');
  return model;
}

/// File next to the credentials JSON that holds the OpenRouter key: the
/// systemd credential of the same name (`LoadCredential=openrouter_api_key:…`),
/// copied there with mode 0600 by `prepare_credentials.py`.
const openRouterKeyFile = 'openrouter_api_key';

/// The API key of the configured provider; empty when none is configured
/// (transcripts then fail with `openai_key_missing`, nothing is sent).
///
/// OpenAI: `openaiApiKey` in the credentials JSON. OpenRouter: the
/// owner-only file [openRouterKeyFile] next to the credentials JSON when it
/// exists, otherwise `openrouterApiKey` in the credentials JSON. The key is
/// never printed.
String transcriptionApiKey(
  WorkerConfig config,
  Map<String, dynamic> credentials,
) {
  switch (config.transcriptionModel.provider) {
    case TranscriptionProvider.openai:
      return credentials['openaiApiKey'] as String? ?? '';
    case TranscriptionProvider.openrouter:
      return openRouterApiKey(config, credentials);
  }
}

/// Shared server-only credential; summaries never place this key in the app.
String openRouterApiKey(WorkerConfig config, Map<String, dynamic> credentials) {
  final file = path.join(
    path.dirname(config.credentialsPath),
    openRouterKeyFile,
  );
  final type = FileSystemEntity.typeSync(file, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    return credentials['openrouterApiKey'] as String? ?? '';
  }
  if (type != FileSystemEntityType.file) {
    throw const WorkerFailure('credentials_permissions');
  }
  requirePrivateFile(file);
  final bytes = File(file).readAsBytesSync();
  final key = String.fromCharCodes(bytes).trim();
  // A header value: printable ASCII without spaces.
  if (bytes.length > 4096 || key.codeUnits.any((u) => u <= 0x20 || u > 0x7e)) {
    throw const WorkerFailure('invalid_openrouter_key');
  }
  return key;
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

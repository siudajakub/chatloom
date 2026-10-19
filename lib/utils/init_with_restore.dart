// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/personal/performance_probe.dart';
import 'package:fluffychat/utils/client_manager.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:matrix/matrix.dart';

class SessionBackup {
  final String? olmAccount;
  final String accessToken;
  final String userId;
  final String homeserver;
  final String? deviceId;
  final String? deviceName;

  const SessionBackup({
    required this.olmAccount,
    required this.accessToken,
    required this.userId,
    required this.homeserver,
    required this.deviceId,
    this.deviceName,
  });

  factory SessionBackup.fromJsonString(String json) =>
      SessionBackup.fromJson(jsonDecode(json));

  factory SessionBackup.fromJson(Map<String, dynamic> json) => SessionBackup(
    olmAccount: json['olm_account'],
    accessToken: json['access_token'],
    userId: json['user_id'],
    homeserver: json['homeserver'],
    deviceId: json['device_id'],
    deviceName: json['device_name'],
  );

  Map<String, dynamic> toJson() => {
    'olm_account': olmAccount,
    'access_token': accessToken,
    'user_id': userId,
    'homeserver': homeserver,
    'device_id': deviceId,
    if (deviceName != null) 'device_name': deviceName,
  };

  @override
  String toString() => jsonEncode(toJson());
}

/// Session backup writes run after startup instead of blocking it. Writes and
/// deletes for one key are serialized so a logout delete always lands last.
class SessionBackupWriter {
  static final Map<String, Future<void>> _pending = {};

  /// Completes when every queued write or delete for [key] has finished.
  static Future<void> settled(String key) => _pending[key] ?? Future.value();

  /// Rewrites [key] only when the stored backup differs from [value].
  static Future<void> write(
    FlutterSecureStorage storage,
    String key,
    String value,
  ) => _enqueue(key, () async {
    if (await storage.read(key: key) == value) return;
    await storage.write(key: key, value: value);
  });

  static Future<void> delete(FlutterSecureStorage storage, String key) =>
      _enqueue(key, () => storage.delete(key: key));

  static Future<void> _enqueue(String key, Future<void> Function() action) {
    late final Future<void> next;
    next = settled(key)
        .then((_) => action())
        .catchError((Object error) {
          // A backup failure must not restart an already initialized session.
          Logs().e('Session backup unavailable: ${error.runtimeType}');
        })
        .whenComplete(() {
          if (identical(_pending[key], next)) _pending.remove(key);
        });
    _pending[key] = next;
    return next;
  }
}

extension InitWithRestoreExtension on Client {
  static Future<void> deleteSessionBackup(String clientName) async {
    final storage = PlatformInfos.isMobile || PlatformInfos.isLinux
        ? const FlutterSecureStorage()
        : null;
    if (storage == null) return;
    await SessionBackupWriter.delete(
      storage,
      '${AppSettings.applicationName.value}_session_backup_$clientName',
    );
  }

  Future<void> initWithRestore({
    void Function()? onMigration,
    bool allowSessionRestore = false,
  }) async {
    final storageKey =
        '${AppSettings.applicationName.value}_session_backup_$clientName';
    final storage = PlatformInfos.isMobile || PlatformInfos.isLinux
        ? const FlutterSecureStorage()
        : null;
    void onInitState(InitState state) {
      if (state == InitState.migratingDatabase) onMigration?.call();
      if (PersonalPerformanceProbe.enabled) _probeInitState(state);
    }

    try {
      await init(
        onInitStateChanged: onInitState,
        waitForFirstSync: false,
        waitUntilLoadCompletedLoaded: true,
        preserveSessionOnInitFailure: true,
      );
      if (isLogged()) {
        final accessToken = this.accessToken;
        final homeserver = this.homeserver?.toString();
        final deviceId = deviceID;
        final userId = userID;
        final hasBackup =
            accessToken != null &&
            homeserver != null &&
            deviceId != null &&
            userId != null;
        assert(hasBackup);
        if (hasBackup && storage != null) {
          Logs().v('Store session in backup');
          // Captured now, written later: startup does not wait for keystore
          // I/O, and an unchanged backup is not rewritten.
          unawaited(
            SessionBackupWriter.write(
              storage,
              storageKey,
              SessionBackup(
                olmAccount: encryption?.pickledOlmAccount,
                accessToken: accessToken,
                deviceId: deviceId,
                homeserver: homeserver,
                deviceName: deviceName,
                userId: userId,
              ).toString(),
            ),
          );
        }
      }
    } catch (e) {
      Logs().e('client_initialization_failed');
      // Opening failed storage is not consent to replace its session from a
      // backup. Startup retries the existing database without relogin/recovery.
      if (!allowSessionRestore) rethrow;
      final l10n = await lookupL10n(AppConfig.appLocale);
      await SessionBackupWriter.settled(storageKey);
      final sessionBackupString = await storage?.read(key: storageKey);
      if (sessionBackupString == null) {
        ClientManager.sendInitNotification(
          l10n.initAppError,
          l10n.sessionLostBody(
            AppConfig.newIssueUrl.toString(),
            e.runtimeType.toString(),
          ),
        );
        rethrow;
      }

      try {
        final sessionBackup = SessionBackup.fromJsonString(sessionBackupString);
        await init(
          newToken: sessionBackup.accessToken,
          newOlmAccount: sessionBackup.olmAccount,
          newDeviceID: sessionBackup.deviceId,
          newDeviceName: sessionBackup.deviceName,
          newHomeserver: Uri.tryParse(sessionBackup.homeserver),
          newUserID: sessionBackup.userId,
          waitForFirstSync: false,
          waitUntilLoadCompletedLoaded: true,
          preserveSessionOnInitFailure: true,
          onInitStateChanged: onInitState,
        );
        ClientManager.sendInitNotification(
          l10n.initAppError,
          l10n.restoreSessionBody(
            AppConfig.newIssueUrl.toString(),
            e.runtimeType.toString(),
          ),
        );
      } catch (e) {
        Logs().e('Restore client failed: ${e.runtimeType}');
        ClientManager.sendInitNotification(
          l10n.initAppError,
          l10n.sessionLostBody(
            AppConfig.newIssueUrl.toString(),
            e.runtimeType.toString(),
          ),
        );
        rethrow;
      }
    }
  }

  /// Startup timeline per local loader (PERSONAL_PERFORMANCE_PROBE only).
  void _probeInitState(InitState state) {
    switch (state) {
      case InitState.loadingData:
        PersonalPerformanceProbe.startupPhase('client_loading');
        for (final (phase, loader) in [
          ('loaded_rooms', roomsLoading),
          ('loaded_account_data', accountDataLoading),
          ('loaded_device_keys', userDeviceKeysLoading),
        ]) {
          if (loader == null) continue;
          unawaited(
            loader.then(
              (_) => PersonalPerformanceProbe.startupPhase(phase),
              onError: (Object _) {},
            ),
          );
        }
      case InitState.finished:
        PersonalPerformanceProbe.startupPhase('client_init');
      default:
        break;
    }
  }
}

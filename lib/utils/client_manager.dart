// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/composer_commands.dart';
import 'package:chatloom/personal/diagnostics.dart';
import 'package:chatloom/personal/performance_probe.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/privacy_transport.dart';
import 'package:chatloom/utils/custom_http_client.dart';
import 'package:chatloom/utils/custom_image_resizer.dart';
import 'package:chatloom/utils/init_with_restore.dart';
import 'package:chatloom/utils/matrix_live_kit_calls/matrix_live_kit_call_member.dart';
import 'package:chatloom/utils/notification_background_handler.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/utils/sync_network_recovery.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:matrix/matrix.dart';
// The vendored SDK exposes its restore exception through this pinned type.
// ignore: implementation_imports
import 'package:matrix/src/utils/client_init_exception.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_html/html.dart' as html;

import 'matrix_sdk_extensions/flutter_matrix_dart_sdk_database/builder.dart';

abstract class ClientManager {
  static const String clientNamespace = 'im.fluffychat.store.clients';

  static Future<List<Client>> getClients({
    bool initialize = true,
    required SharedPreferences store,
    @visibleForTesting
    Future<Client> Function(String, SharedPreferences)? clientFactory,
    @visibleForTesting
    Future<void> Function(Client, void Function())? initializeClient,
  }) async {
    final startup = ClientStartup(
      store: store,
      clientFactory: clientFactory,
      initializeClient: initializeClient,
      initialize: initialize,
    );
    await startup.restore();
    if (startup.registryFailure != null) {
      throw StateError('Account registry is invalid');
    }
    // Compatibility for background/legacy callers. Foreground uses the explicit
    // result and never routes a failed client into login.
    return startup.accounts
        .where((entry) => entry.client != null)
        .map((entry) => entry.client!)
        .toList();
  }

  static Future<void> addClientNameToStore(
    String clientName,
    SharedPreferences store,
  ) async {
    final clientNamesList = store.getStringList(clientNamespace) ?? [];
    clientNamesList.add(clientName);
    await store.setStringList(clientNamespace, clientNamesList);
  }

  static Future<void> removeClientNameFromStore(
    String clientName,
    SharedPreferences store,
  ) async {
    final clientNamesList = store.getStringList(clientNamespace) ?? [];
    clientNamesList.remove(clientName);
    await store.setStringList(clientNamespace, clientNamesList);
  }

  static NativeImplementations get nativeImplementations => kIsWeb
      ? NativeImplementationsWebWorker(
          Uri.parse('native_executor.js'),
          timeout: const Duration(minutes: 1),
        )
      : NativeImplementationsIsolate(
          compute,
          vodozemacInit: () => vod.init(
            wasmPath:
                './assets/assets/vodozemac/${AppConfig.vodozemacVersion}/',
          ),
        );

  static Future<Client> createClient(
    String clientName,
    SharedPreferences store,
  ) async {
    final shareKeysWith = AppSettings.shareKeysWith.value;
    final enableSoftLogout = AppSettings.enableSoftLogout.value;

    PersonalPrivacy.installLogging();
    final client = Client(
      clientName,
      httpClient: PrivacyHttpClient(
        CustomHttpClient.createHTTPClient(),
        incognito: () => PersonalPrivacy.policy.incognito,
      ),
      verificationMethods: {
        KeyVerificationMethod.numbers,
        if (kIsWeb || PlatformInfos.isMobile || PlatformInfos.isLinux)
          KeyVerificationMethod.emoji,
      },
      importantStateEvents: <String>{
        'pl.personal.client.journal.v1',
        'm.bridge',
        'uk.half-shot.bridge',
        'com.beeper.bridge',
        'io.element.functional_members',
        'com.beeper.room_features',
        'pl.personal.chat.telegram.media_capabilities',
        // To make room emotes work
        'im.ponies.room_emotes',
        // Sticker packs imported by bridges (stable MSC2545 type).
        'm.room.image_pack',
        // To display call state in chat list
        MatrixRtcCallMember.eventType,
      },
      customImageResizer: PlatformInfos.supportsCustomImageResizer
          ? customImageResizer
          : null,
      logLevel: Level.warning,
      database: await flutterMatrixSdkDatabaseBuilder(clientName),
      supportedLoginTypes: {
        AuthenticationTypes.password,
        AuthenticationTypes.sso,
      },
      nativeImplementations: nativeImplementations,
      defaultNetworkRequestTimeout: const Duration(seconds: 60),
      enableDehydratedDevices: true,
      shareKeysWith:
          ShareKeysWith.values.singleWhereOrNull(
            (share) => share.name == shareKeysWith,
          ) ??
          ShareKeysWith.all,
      onSoftLogout: enableSoftLogout ? (c) => c.refreshAccessToken() : null,
      sendTimelineEventTimeout: Duration(
        seconds: AppSettings.sendTimelineEventTimeout.value,
      ),
    );
    client.syncErrorMaxTimeoutSec = 60;
    // No typed `/logout`, `/leave`, `/clearcache`…: formatting commands only.
    restrictComposerCommands(client);
    if (!PersonalPrivacy.policy.allowOnlinePresence) {
      client.syncPresence = PresenceType.offline;
    }
    PersonalPrivacy.bind(client);
    return client;
  }

  /// Phone sync settings for an app lifecycle change. The loop runs only in
  /// the foreground (FCM wakes the app otherwise), with short retries there
  /// (see [foregroundSyncRetryCapSec]). Background syncs happen only for a
  /// push (catch-up, reminder wake, key retry): they never page history into
  /// chats that came back limited, which cost a request per chat for
  /// nothing. Notifications come from pushes, and an opened chat pages its
  /// own history, exactly as after a foreground catch-up.
  static void applyMobileLifecycle(Client client, {required bool foreground}) {
    client.syncErrorMaxTimeoutSec = foregroundSyncRetryCapSec;
    client.requestHistoryOnLimitedTimeline = false;
    client.backgroundSync = foreground;
  }

  static WindowsInitializationSettings get windowsNotificationSettings =>
      WindowsInitializationSettings(
        appName: AppSettings.applicationName.value,
        appUserModelId: AppConfig.appId,
        guid: AppConfig.windowsNotificationGuid,
      );

  static Future<void> sendInitNotification(String title, String body) async {
    if (!PlatformInfos.supportsSystemNotifications) return;
    if (kIsWeb) {
      html.Notification(title, body: body);
      return;
    }

    final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

    await flutterLocalNotificationsPlugin.initialize(
      settings: InitializationSettings(
        android: const AndroidInitializationSettings('notifications_icon'),
        iOS: const DarwinInitializationSettings(),
        linux: LinuxInitializationSettings(
          defaultActionName: ChatLoomNotificationActions.open.name,
        ),
        windows: windowsNotificationSettings,
        macOS: const DarwinInitializationSettings(),
      ),
    );

    await flutterLocalNotificationsPlugin.show(
      id: 0,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'error_message',
          'Error Messages',
          importance: Importance.high,
          priority: Priority.max,
        ),
        iOS: DarwinNotificationDetails(sound: 'notification.caf'),
      ),
    );
  }
}

class ClientStartupAccount {
  final String _name;
  Client? client;
  PersonalDiagnostic? failure;
  bool available = false;
  ClientStartupAccount(this._name);
}

/// Keeps failed account handles outside Matrix until an explicit retry succeeds.
/// It never clears a registry, database or key in response to an error.
class ClientStartup extends ChangeNotifier {
  final SharedPreferences store;
  final Future<Client> Function(String, SharedPreferences) _factory;
  final Future<void> Function(Client, void Function())? _initializeClient;
  final bool initialize;
  final bool backgroundSync;
  final List<ClientStartupAccount> accounts = [];
  // Matrix owns mutations caused by real login/logout; retain this list identity.
  final List<Client> clients = [];
  PersonalDiagnostic? registryFailure;
  Future<void>? _restoring;
  bool _disposed = false;
  bool get busy => _restoring != null;
  int get failedCount => accounts.where((a) => a.failure != null).length;
  bool get hasFailures => registryFailure != null || failedCount != 0;

  ClientStartup({
    required this.store,
    Future<Client> Function(String, SharedPreferences)? clientFactory,
    Future<void> Function(Client, void Function())? initializeClient,
    this.initialize = true,
    this.backgroundSync = true,
  }) : _factory = clientFactory ?? ClientManager.createClient,
       _initializeClient = initializeClient;

  Future<void> restore() {
    if (_disposed) return Future.value();
    if (_restoring != null) return _restoring!;
    final restoring = _restoring = _restore()
        .catchError((Object error) {
          if (!_disposed) {
            registryFailure = PersonalDiagnostic.from(
              error,
              PersonalFailurePhase.registry,
            );
          }
        })
        .whenComplete(() {
          _restoring = null;
          if (!_disposed) notifyListeners();
        });
    notifyListeners();
    return restoring;
  }

  Future<void> _restore() async {
    // Yield so busy is established even when preferences validation fails early.
    await Future<void>.value();
    if (_disposed) return;
    if (accounts.isEmpty) {
      try {
        // Refresh only on retry: another isolate may have corrected preferences.
        if (registryFailure != null) await store.reload();
        if (_disposed) return;
        final raw = store.get(ClientManager.clientNamespace);
        if (raw != null &&
            (raw is! List ||
                raw.any((name) => name is! String || name.isEmpty))) {
          throw StateError('Account registry is invalid');
        }
        final names = raw == null ? <String>[] : List<String>.from(raw as List);
        if (names.isEmpty) {
          names.add(PlatformInfos.appDisplayName);
          await store.setStringList(ClientManager.clientNamespace, names);
        }
        if (_disposed) return;
        accounts.addAll(names.toSet().map(ClientStartupAccount.new));
        registryFailure = null;
      } catch (_) {
        registryFailure = const PersonalDiagnostic(
          'account_registry_invalid',
          PersonalFailurePhase.registry,
        );
        return;
      }
    }
    await Future.wait(
      accounts.where((a) => !a.available).map((entry) async {
        try {
          final client = entry.client ??= await _factory(entry._name, store);
          PersonalPerformanceProbe.startupPhase('client_created');
          if (_disposed) return;
          if (!backgroundSync) {
            client.backgroundSync = false;
            client.syncPresence = PresenceType.offline;
          }
          if (initialize) {
            void onMigration() {
              // Migration notification is optional and must not fail restoration.
              () async {
                final l10n = await lookupL10n(AppConfig.appLocale);
                await ClientManager.sendInitNotification(
                  l10n.databaseMigrationTitle,
                  l10n.databaseMigrationBody,
                );
              }().catchError((Object _) {});
            }

            if (_initializeClient != null) {
              await _initializeClient(client, onMigration);
            } else {
              await client.initWithRestore(onMigration: onMigration);
            }
            // Also cover alternate initializers: account usability includes local
            // rooms, account metadata and trusted device keys, independently per account.
            // Device keys stay required: preserve-mode SDK init already awaits
            // them, and publishing earlier would expose a session whose crypto
            // store may still fail (trust badges, sync and sends would degrade).
            await Future.wait<dynamic>([
              if (client.roomsLoading != null) client.roomsLoading!,
              if (client.accountDataLoading != null) client.accountDataLoading!,
              if (client.userDeviceKeysLoading != null)
                client.userDeviceKeysLoading!,
            ]);
          }
          if (_disposed) return;
          PersonalPerformanceProbe.startupPhase('client_available');
          entry.available = true;
          entry.failure = null;
          if ((!initialize || client.isLogged() || accounts.length == 1) &&
              !clients.contains(client)) {
            clients.add(client);
          }
          notifyListeners();
        } catch (error) {
          if (_disposed) return;
          entry.failure = PersonalDiagnostic.from(
            error is ClientInitException ? error.originalException : error,
            PersonalFailurePhase.accountRestore,
          );
          Logs().e('client_initialization_failed', entry.failure!.code);
          notifyListeners();
        }
      }),
    );
    if (_disposed) return;
    // Only a completed, explicit logged-out state is eligible for removal.
    // A failed restore is never interpreted as logout.
    if (initialize && accounts.length > 1) {
      final loggedOut = accounts
          .where((a) => a.available && !a.client!.isLogged())
          .toList();
      if (loggedOut.isNotEmpty && loggedOut.length < accounts.length) {
        for (final entry in loggedOut) {
          accounts.remove(entry);
          clients.remove(entry.client);
        }
        await store.setStringList(
          ClientManager.clientNamespace,
          accounts.map((a) => a._name).toList(),
        );
      }
    }
    for (final entry in accounts.where((entry) => entry.available)) {
      if (!clients.contains(entry.client)) clients.add(entry.client!);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:collection/collection.dart';
import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/personal/privacy_transport.dart';
import 'package:fluffychat/utils/custom_http_client.dart';
import 'package:fluffychat/utils/custom_image_resizer.dart';
import 'package:fluffychat/utils/init_with_restore.dart';
import 'package:fluffychat/utils/matrix_live_kit_calls/matrix_live_kit_call_member.dart';
import 'package:fluffychat/utils/notification_background_handler.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:matrix/matrix.dart';
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
    final clientNames = <String>{};
    try {
      final clientNamesList = store.getStringList(clientNamespace) ?? [];
      clientNames.addAll(clientNamesList);
    } catch (e, s) {
      Logs().w('Client names in store are corrupted', e, s);
      await store.remove(clientNamespace);
    }
    if (clientNames.isEmpty) {
      clientNames.add(PlatformInfos.appDisplayName);
      await store.setStringList(clientNamespace, clientNames.toList());
    }
    final clients = await Future.wait(
      clientNames.map((name) => (clientFactory ?? createClient)(name, store)),
    );
    final failedClients = <Client>{};
    if (initialize) {
      await Future.wait(
        clients.map((client) async {
          Future<void> onMigration() async {
            final l10n = await lookupL10n(PlatformDispatcher.instance.locale);
            await sendInitNotification(
              l10n.databaseMigrationTitle,
              l10n.databaseMigrationBody,
            );
          }

          try {
            if (initializeClient != null) {
              await initializeClient(client, onMigration);
            } else {
              await client.initWithRestore(onMigration: onMigration);
            }
          } catch (error) {
            failedClients.add(client);
            Logs().e(
              'client_initialization_failed',
              error.runtimeType.toString(),
            );
          }
        }),
      );
    }
    // A failed database/key restore is not a logout. Keep its namespace so
    // the existing encrypted session can be retried on the next launch.
    if (initialize && clients.length > 1) {
      final loggedOutClients = clients
          .where((c) => !c.isLogged() && !failedClients.contains(c))
          .toList();
      for (final client in loggedOutClients) {
        Logs().w('Removing a logged-out multi-account client.');
        clientNames.remove(client.clientName);
        clients.remove(client);
      }
      await store.setStringList(clientNamespace, clientNames.toList());
    }
    return clients;
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
        'com.beeper.room_features',
        'pl.personal.chat.telegram.media_capabilities',
        // To make room emotes work
        'im.ponies.room_emotes',
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
    if (!PersonalPrivacy.policy.allowOnlinePresence) {
      client.syncPresence = PresenceType.offline;
    }
    PersonalPrivacy.bind(client);
    return client;
  }

  static WindowsInitializationSettings get windowsNotificationSettings =>
      WindowsInitializationSettings(
        appName: AppSettings.applicationName.value,
        appUserModelId: AppConfig.appId,
        guid: AppConfig.windowsNotificationGuid,
      );

  static Future<void> sendInitNotification(String title, String body) async {
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
          defaultActionName: FluffyChatNotificationActions.open.name,
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

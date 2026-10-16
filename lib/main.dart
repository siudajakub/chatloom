// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io' show Directory;
import 'dart:isolate';
import 'dart:ui';

import 'package:collection/collection.dart';
import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/personal/media/media_access.dart';
import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/personal/performance_probe.dart';
import 'package:fluffychat/utils/client_manager.dart';
import 'package:fluffychat/utils/error_reporter.dart';
import 'package:fluffychat/utils/notification_background_handler.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/start_push_foreground_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_html/universal_html.dart' as web;

import 'config/setting_keys.dart';
import 'utils/background_push.dart';
import 'widgets/client_startup.dart';
import 'widgets/fluffy_chat_app.dart';

ReceivePort? mainIsolateReceivePort;

bool _vodozemacInitialized = false;

bool isIntegrationTest = false;

void main(List<String> args) => runZonedGuarded(() async {
  // Forward Flutter errors to global error reporter
  FlutterError.onError = (details) => Zone.current.handleUncaughtError(
    details.exception,
    details.stack ?? StackTrace.current,
  );

  isIntegrationTest = args.singleOrNull == 'integration_test';
  if (PlatformInfos.isAndroid) {
    final port = mainIsolateReceivePort = ReceivePort();
    IsolateNameServer.removePortNameMapping(AppConfig.mainIsolatePortName);
    IsolateNameServer.registerPortWithName(
      port.sendPort,
      AppConfig.mainIsolatePortName,
    );
    await waitForPushIsolateDone();
  }

  // Sanitize hash for OIDC:
  if (kIsWeb) {
    final hash = web.window.location.hash;
    if (hash.isNotEmpty && !hash.startsWith('/')) {
      web.window.location.hash = hash.replaceFirst('#', '#?');
    }
  }

  // Our background push shared isolate accesses flutter-internal things very early in the startup proccess
  // To make sure that the parts of flutter needed are started up already, we need to ensure that the
  // widget bindings are initialized already.
  WidgetsFlutterBinding.ensureInitialized();
  PersonalPerformanceProbe.install();

  PersonalPrivacy.installLogging();
  if (!kIsWeb) {
    try {
      final temporary = await getTemporaryDirectory();
      for (final folder in [
        'personal_audio',
        'personal_video',
        'personal_media',
      ]) {
        await MediaAccess.open(
          directory: Directory('${temporary.path}/$folder'),
        );
      }
    } catch (error) {
      Logs().w('private_media_cleanup_failed', error.runtimeType.toString());
    }
  }

  ErrorReporter.startupPhase = 'settings';
  final store = await AppSettings.init();
  Logs().i('Welcome to ${AppSettings.applicationName.value} <3');

  kEnableMatrixSdkBenchmarks = AppSettings.benchmarksInLogs.value;

  if (!_vodozemacInitialized) {
    ErrorReporter.startupPhase = 'crypto';
    await vod.init(
      wasmPath: './assets/assets/vodozemac/${AppConfig.vodozemacVersion}/',
    );
    _vodozemacInitialized = true;
  }

  Logs().nativeColors = !PlatformInfos.isIOS;

  // If the app starts in detached mode, we assume that it is in
  // background fetch mode for processing push notifications. This is
  // currently only supported on Android.
  if (PlatformInfos.isAndroid &&
      AppLifecycleState.detached == WidgetsBinding.instance.lifecycleState) {
    await ForegroundServices.startService('background_push');
    try {
    ErrorReporter.startupPhase = 'background_clients';
    final startup = ClientStartup(store: store);
    await startup.restore();
    final clients = startup.clients;

    // Do not send online presences when app is in background fetch mode.
    for (final client in clients) {
      client.backgroundSync = false;
      client.syncPresence = PresenceType.offline;
    }

    // In the background fetch mode we do not want to waste ressources with
    // starting the Flutter engine but process incoming push notifications.
    await BackgroundPush.clientOnly(clients).ready;
    // To start the flutter engine afterwards we add an custom observer.
    WidgetsBinding.instance.addObserver(
      AppStarter(clients, store, startup: startup),
    );
    Logs().i(
      '${AppSettings.applicationName.value} started in background-fetch mode. No GUI will be created unless the app is no longer detached.',
    );
    return;
    } finally {
      await ForegroundServices.stopService('background_push');
    }
  }

  ErrorReporter.startupPhase = 'clients';
  final startup = ClientStartup(store: store);
  unawaited(startup.restore());
  final clients = startup.clients;

  // Started in foreground mode.
  Logs().i(
    '${AppSettings.applicationName.value} started in foreground mode. Rendering GUI...',
  );
  ErrorReporter.startupPhase = 'gui';
  await startGui(clients, store, startup: startup);
}, ErrorReporter.onFlutterError);

/// Fetch the pincode for the applock and start the flutter engine.
Future<void> startGui(
  List<Client> clients,
  SharedPreferences store, {
  ClientStartup? startup,
}) async {
  // Fetch the pin for the applock if existing for mobile applications.
  String? pin;
  var useBiometrics = false;
  if (PlatformInfos.supportsAppLock) {
    try {
      pin = await const FlutterSecureStorage().read(
        key: 'chat.fluffy.app_lock',
      );
      useBiometrics =
          (await const FlutterSecureStorage().read(
            key: 'chat.fluffy.use_biometrics',
          )) ==
          'true';
    } catch (_) {
      Logs().e('app_lock_storage_unavailable');
      runApp(
        StartupLockFailureView(
          retry: () => startGui(clients, store, startup: startup),
        ),
      );
      return;
    }
  }

  if (PlatformInfos.isLinux || PlatformInfos.isWindows) {
    JustAudioMediaKit.ensureInitialized();
  }

  // Render healthy accounts immediately; room/account loading is handled by
  // their existing screens, independently of failed account restoration.

  runApp(
    startup != null
        ? ClientStartupView(
            startup: startup,
            appLockSettings: (pincode: pin, useBiometrics: useBiometrics),
          )
        : FluffyChatApp(
            clients: clients,
            appLockSettings: (pincode: pin, useBiometrics: useBiometrics),
            store: store,
          ),
  );
}

/// Watches the lifecycle changes to start the application when it
/// is no longer detached.
class AppStarter with WidgetsBindingObserver {
  final List<Client> clients;
  final SharedPreferences store;
  final ClientStartup? startup;
  bool guiStarted = false;

  AppStarter(this.clients, this.store, {this.startup});

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (guiStarted) return;
    if (state == AppLifecycleState.detached) return;

    Logs().i(
      '${AppSettings.applicationName.value} switches from the detached background-fetch mode to ${state.name} mode. Rendering GUI...',
    );
    // Switching to foreground mode needs to reenable send online sync presence.
    for (final client in clients) {
      client.backgroundSync = true;
      client.syncPresence = PersonalPrivacy.policy.allowOnlinePresence
          ? PresenceType.online
          : PresenceType.offline;
    }
    // Claim startup before its first await and release the one-shot observer.
    guiStarted = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(startGui(clients, store, startup: startup));
  }
}

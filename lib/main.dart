// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io' show Directory;
import 'dart:isolate';
import 'dart:ui';

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/personal/media/media_access.dart';
import 'package:chatloom/personal/performance_probe.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/utils/background_startup_recovery.dart';
import 'package:chatloom/utils/client_manager.dart';
import 'package:chatloom/utils/error_reporter.dart';
import 'package:chatloom/utils/flutter_error_routing.dart';
import 'package:chatloom/utils/notification_background_handler.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/utils/start_push_foreground_service.dart';
import 'package:collection/collection.dart';
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
import 'widgets/chatloom_app.dart';
import 'widgets/client_startup.dart';

ReceivePort? mainIsolateReceivePort;

bool _vodozemacInitialized = false;

bool isIntegrationTest = false;

void main(List<String> args) => runZonedGuarded(() async {
  PersonalPerformanceProbe.startupPhase('main');
  // Forward Flutter errors to global error reporter
  FlutterError.onError = (details) =>
      routeFlutterError(details, Zone.current.handleUncaughtError);

  isIntegrationTest = args.singleOrNull == 'integration_test';
  if (PlatformInfos.isAndroid) {
    // Before any await: pushes that start the app must not be dropped.
    BackgroundPush.bufferEarlyMessages();
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
  PersonalPerformanceProbe.startupPhase('binding');

  PersonalPrivacy.installLogging();
  if (!kIsWeb) {
    // Only leases of dead processes are swept, so this can wait for the first
    // frame. A background-fetch start without GUI leaves it to the next start.
    unawaited(
      WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) {
        PersonalPerformanceProbe.startupPhase('first_frame');
        return _cleanupPrivateMedia();
      }),
    );
  }

  ErrorReporter.startupPhase = 'settings';
  final store = await AppSettings.init();
  Logs().i('Welcome to ${AppSettings.applicationName.value} <3');
  PersonalPerformanceProbe.startupPhase('settings');

  kEnableMatrixSdkBenchmarks = AppSettings.benchmarksInLogs.value;

  if (!_vodozemacInitialized) {
    ErrorReporter.startupPhase = 'crypto';
    await vod.init(
      wasmPath: './assets/assets/vodozemac/${AppConfig.vodozemacVersion}/',
    );
    _vodozemacInitialized = true;
    PersonalPerformanceProbe.startupPhase('crypto');
  }

  Logs().nativeColors = !PlatformInfos.isIOS;

  // If the app starts in detached mode, we assume that it is in
  // background fetch mode for processing push notifications. This is
  // currently only supported on Android.
  if (PlatformInfos.isAndroid &&
      AppLifecycleState.detached == WidgetsBinding.instance.lifecycleState) {
    final recovery = BackgroundFailureStarter(store);
    WidgetsBinding.instance.addObserver(recovery);
    final acquired = await ForegroundServices.startService('background_push');
    try {
      ErrorReporter.startupPhase = 'background_clients';
      final startup = ClientStartup(store: store, backgroundSync: false);
      final restoring = startup.restore();
      try {
        await restoring.timeout(const Duration(seconds: 30));
      } catch (error, stack) {
        // Initialization cannot be cancelled halfway through database/crypto
        // loading. Retire its owned clients after any late completion; no client
        // in this background-only startup is allowed to start a sync loop.
        ErrorReporter.onFlutterError(error, stack);
        recovery.failed(
          restoring.then(
            (_) => closeBackgroundStartup(startup),
            onError: (Object _) => closeBackgroundStartup(startup),
          ),
        );
        return;
      }
      final clients = startup.clients;

      // Do not send online presences when app is in background fetch mode.
      for (final client in clients) {
        client.backgroundSync = false;
        client.syncPresence = PresenceType.offline;
      }

      // In the background fetch mode we do not want to waste ressources with
      // starting the Flutter engine but process incoming push notifications.
      final backgroundPush = BackgroundPush.clientOnly(clients);
      try {
        await backgroundPush.ready.timeout(const Duration(seconds: 30));
      } catch (error, stack) {
        backgroundPush.forgetClients(clients);
        ErrorReporter.onFlutterError(error, stack);
        recovery.failed(closeBackgroundStartup(startup));
        return;
      }
      // To start the flutter engine afterwards we add an custom observer.
      WidgetsBinding.instance.removeObserver(recovery);
      final starter = AppStarter(clients, store, startup: startup);
      WidgetsBinding.instance.addObserver(starter);
      final state = WidgetsBinding.instance.lifecycleState;
      if (state != null && state != AppLifecycleState.detached) {
        starter.didChangeAppLifecycleState(state);
      }
      Logs().i(
        '${AppSettings.applicationName.value} started in background-fetch mode. No GUI will be created unless the app is no longer detached.',
      );
      return;
    } finally {
      if (acquired) await ForegroundServices.stopService('background_push');
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

/// Removes plaintext leases left by dead processes (see [MediaAccess.open]).
Future<void> _cleanupPrivateMedia() async {
  try {
    final temporary = await getTemporaryDirectory();
    for (final folder in [
      'personal_audio',
      'personal_video',
      'personal_media',
    ]) {
      await MediaAccess.open(directory: Directory('${temporary.path}/$folder'));
    }
  } catch (error) {
    Logs().w('private_media_cleanup_failed', error.runtimeType.toString());
  }
  PersonalPerformanceProbe.startupPhase('media_cleanup');
}

Future<void> closeBackgroundStartup(ClientStartup startup) async {
  var failed = false;
  for (final account in startup.accounts) {
    try {
      await account.client?.dispose();
    } catch (_) {
      failed = true;
    }
  }
  startup.dispose();
  if (failed) throw StateError('Background storage cleanup failed');
}

/// A shared engine must still respond to opening the Activity after a timed-out
/// push startup. The fresh foreground startup never adopts abandoned clients.
class BackgroundFailureStarter with WidgetsBindingObserver {
  late final BackgroundStartupRecovery _recovery;
  bool _failed = false;

  BackgroundFailureStarter(SharedPreferences store) {
    _recovery = BackgroundStartupRecovery(
      startForeground: () async {
        WidgetsBinding.instance.removeObserver(this);
        final startup = ClientStartup(store: store);
        unawaited(startup.restore());
        await startGui(startup.clients, store, startup: startup);
      },
    );
  }

  void failed(Future<void> cleanup) {
    _failed = true;
    unawaited(_recovery.fail(cleanup).catchError(ErrorReporter.onFlutterError));
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == AppLifecycleState.resumed) {
      didChangeAppLifecycleState(AppLifecycleState.resumed);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _recovery.leaveForeground();
      return;
    }
    if (_failed) {
      // Cleanup can itself be delayed or fail. Show a content-free surface
      // immediately instead of leaving the Activity blank while storage is
      // still owned by the abandoned startup. Never open a second database.
      runApp(const BackgroundStartupFailureView());
    }
    unawaited(
      _recovery.requestForeground().catchError(ErrorReporter.onFlutterError),
    );
  }
}

class BackgroundStartupFailureView extends StatelessWidget {
  const BackgroundStartupFailureView({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Secure startup could not finish. Your accounts, data and keys are preserved. '
              'The app will retry when the previous startup has released storage. '
              'If this screen persists, close and reopen the app. Keep app data.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    ),
  );
}

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
      // Independent keystore reads; either failure still blocks the GUI.
      const storage = FlutterSecureStorage();
      final values = await Future.wait([
        storage.read(key: 'chat.fluffy.app_lock'),
        storage.read(key: 'chat.fluffy.use_biometrics'),
      ]);
      pin = values[0];
      useBiometrics = values[1] == 'true';
      PersonalPerformanceProbe.startupPhase('app_lock');
    } catch (_) {
      Logs().e('app_lock_storage_unavailable');
      runApp(
        StartupLockFailureView(
          store: store,
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

  PersonalPerformanceProbe.startupPhase('run_app');
  runApp(
    startup != null
        ? ClientStartupView(
            startup: startup,
            appLockSettings: (pincode: pin, useBiometrics: useBiometrics),
          )
        : ChatLoomApp(
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

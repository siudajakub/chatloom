// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// Copyright (C) 2020, 2021 Famedly GmbH
// Copyright (C) 2021 Fluffychat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:fcm_shared_isolate/fcm_shared_isolate.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/main.dart';
import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/personal/push_registration.dart';
import 'package:fluffychat/utils/notification_background_handler.dart';
import 'package:fluffychat/utils/push_helper.dart';
import 'package:fluffychat/widgets/fluffy_chat_app.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:unifiedpush/unifiedpush.dart';
import 'package:unifiedpush_ui/unifiedpush_ui.dart';

import '../config/app_config.dart';
import '../config/setting_keys.dart';
import '../widgets/matrix.dart';
import 'platform_infos.dart';
import 'start_push_foreground_service.dart';

class BackgroundPush {
  static BackgroundPush? _instance;
  final FlutterLocalNotificationsPlugin _flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  List<Client> _clients;

  List<Client> get clients => matrix?.widget.clients ?? _clients;

  MatrixState? matrix;
  late final Future<void> ready;

  /// The shared Android engine outlives its activity/widget. Drop the widget
  /// and its callbacks while retaining the registered push listeners.
  void detachMatrix(MatrixState owner) {
    if (!identical(matrix, owner)) return;
    _clients = List<Client>.from(owner.widget.clients);
    matrix = null;
    onFcmError = null;
  }
  final _registration = PushRegistration();
  final registrationChanges = ValueNotifier<int>(0);
  final _pusherPhases = <Client, PushRegistrationPhase>{};
  Future<void> _registrationQueue = Future<void>.value();
  Future<void> _tokenPersistence = Future<void>.value();
  int get registrationRevision => _registration.revision;

  String? get _fcmToken => _registration.token;
  String? get fcmToken => _fcmToken;
  String registrationDescription(Client client) {
    final view = PushRegistration()
      ..phase = _pusherPhases[client] ?? _registration.phase;
    view.rotated = _registration.rotated;
    return view.description;
  }

  void _changed() => registrationChanges.value++;

  Future<void> _acceptFcmToken(String token) {
    if (token.isEmpty) return Future<void>.value();
    if (_registration.observe(token)) {
      _pusherPhases.clear();
      _changed();
    }
    final revision = _registration.revision;
    _tokenPersistence = _tokenPersistence.catchError((Object _) {}).then((
      _,
    ) async {
      const storage = FlutterSecureStorage();
      final fingerprint = sha256.convert(utf8.encode(token)).toString();
      final previous = await storage.read(
        key: 'personal_fcm_token_fingerprint',
      );
      if (_registration.revision != revision) return;
      if (previous != null && previous != fingerprint) {
        _registration.rotated = true;
        _changed();
      }
      await storage.write(
        key: 'personal_fcm_token_fingerprint',
        value: fingerprint,
      );
    });
    return _tokenPersistence;
  }

  Future<void> _onNewFcmToken(String token) async {
    if (token.isEmpty) return;
    try {
      await _acceptFcmToken(token);
      if (upAction || !firebaseEnabled || _registration.updating) return;
      for (final client in List<Client>.from(clients)) {
        if (client.isLogged()) await _queueFirebaseRegistration(client);
      }
    } catch (_) {
      if (_fcmToken == token) {
        _registration.phase = PushRegistrationPhase.failed;
        _changed();
      }
    }
  }

  void beginRegistrationUpdate() {
    _registration.beginUpdate();
    _pusherPhases.clear();
    _changed();
  }

  void endRegistrationUpdate() {
    _registration.endUpdate();
    _pusherPhases.clear();
    _changed();
  }

  void invalidateRegistration() {
    _registration.invalidate();
    _pusherPhases.clear();
    _changed();
  }

  Future<void> _queueFirebaseRegistration(Client client) {
    final token = _fcmToken;
    if (token == null || token.isEmpty) return Future<void>.value();
    final revision = _registration.revision;
    final next = _registrationQueue.catchError((Object _) {}).then((_) async {
      if (revision != _registration.revision ||
          upAction ||
          _registration.updating) {
        return;
      }
      await setupPusher(
        client: client,
        gatewayUrl: AppSettings.pushNotificationsGatewayUrl.value,
        token: token,
      );
    });
    _registrationQueue = next;
    return next;
  }

  void Function(String errorMsg, {Uri? link})? onFcmError;
  L10n? l10n;

  Future<void> loadLocale() async {
    final context = matrix?.context;
    // inspired by _lookupL10n in .dart_tool/flutter_gen/gen_l10n/l10n.dart
    l10n ??=
        (context != null && context.mounted ? L10n.of(context) : null) ??
        (await L10n.delegate.load(PlatformDispatcher.instance.locale));
  }

  final pendingTests = <String, Completer<void>>{};
  bool firebaseEnabled = false;

  final firebase = FcmSharedIsolate();

  DateTime? lastReceivedPush;

  bool upAction = false;

  Future<void> _init() async {
    PersonalPrivacy.installLogging();
    firebaseEnabled = PlatformInfos.isAndroid;
    try {
      mainIsolateReceivePort?.listen((message) async {
        try {
          await notificationTap(
            NotificationResponseJson.fromJsonString(message),
            clients: clients,
            router: FluffyChatApp.router,
            l10n: l10n,
          );
        } catch (e, s) {
          Logs().wtf('Main Notification Tap crashed', e, s);
        }
      });
      if (PlatformInfos.isAndroid) {
        final port = ReceivePort();
        IsolateNameServer.removePortNameMapping('background_tab_port');
        IsolateNameServer.registerPortWithName(
          port.sendPort,
          'background_tab_port',
        );
        port.listen((message) async {
          try {
            await notificationTap(
              NotificationResponseJson.fromJsonString(message),
              clients: clients,
              router: FluffyChatApp.router,
              l10n: l10n,
            );
          } catch (e, s) {
            Logs().wtf('Main Notification Tap crashed', e, s);
          }
        });
      }
      await _flutterLocalNotificationsPlugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('notifications_icon'),
          iOS: DarwinInitializationSettings(),
        ),
        onDidReceiveNotificationResponse: (response) async {
          try {
            await notificationTap(
              response,
              clients: clients,
              router: FluffyChatApp.router,
              l10n: l10n,
            );
          } catch (_) {
            Logs().w('[Push] notification_action_failed');
          }
        },
        onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
      );
      Logs().v('Flutter Local Notifications initialized');
      if (firebaseEnabled) {
        firebase.setListeners(
          onMessage: handleFcmMessage,
          onNewToken: (token) => unawaited(_onNewFcmToken(token)),
        );
      }
      if (Platform.isAndroid) {
        await UnifiedPush.initialize(
          onNewEndpoint: _newUpEndpoint,
          onRegistrationFailed: (_, i) => _upUnregistered(i),
          onUnregistered: _upUnregistered,
          onMessage: _onUpMessage,
        );
      }
    } catch (e, s) {
      Logs().e('Unable to initialize Flutter local notifications', e, s);
    }
  }

  BackgroundPush._(this._clients) {
    ready = _init();
  }

  factory BackgroundPush.clientOnly(List<Client> clients) {
    final instance = _instance ??= BackgroundPush._(clients);
    instance._clients = clients;
    return instance;
  }

  factory BackgroundPush(
    MatrixState matrix, {
    void Function(String errorMsg, {Uri? link})? onFcmError,
  }) {
    final instance = BackgroundPush.clientOnly(matrix.widget.clients);
    instance.matrix = matrix;
    // ignore: prefer_initializing_formals
    instance.onFcmError = onFcmError;
    return instance;
  }

  /// Update only this account/device's pusher while its session and token are
  /// current. The private gateway allowlist is configured separately by J.
  Future<void> setupPusher({
    required Client client,
    String? gatewayUrl,
    String? token,
  }) async {
    if (gatewayUrl == null || token == null || token.isEmpty) return;
    final owner = client.userID;
    final device = client.deviceID;
    final ownFcmGateway =
        gatewayUrl == AppSettings.pushNotificationsGatewayUrl.value &&
        token == _fcmToken;
    final revision = _registration.revision;
    bool current() =>
        clients.contains(client) &&
        client.isLogged() &&
        client.userID == owner &&
        client.deviceID == device &&
        owner != null &&
        device != null &&
        (!ownFcmGateway ||
            (!upAction &&
                !_registration.updating &&
                gatewayUrl == AppSettings.pushNotificationsGatewayUrl.value &&
                _registration.current(revision, token, true)));
    if (!current()) return;
    final appDisplayName = PlatformInfos.appDisplayName;
    var appId = '${AppConfig.pushNotificationsAppId}.$device';
    if (appId.length > 64) appId = appId.substring(0, 64);
    final thisAppId = appId;
    var pushers = <Pusher>[];
    Pusher? desired;
    var alreadySet = false;
    if (ownFcmGateway) {
      _pusherPhases[client] = PushRegistrationPhase.registering;
      _changed();
    }
    try {
      final completed = await registerCurrentPush(
        current: current,
        prepare: () async {
          if (PlatformInfos.isIOS) await firebase.requestPermission();
          if (PlatformInfos.isAndroid && !isIntegrationTest) {
            await _flutterLocalNotificationsPlugin
                .resolvePlatformSpecificImplementation<
                  AndroidFlutterLocalNotificationsPlugin
                >()
                ?.requestNotificationsPermission();
          }
          pushers = await client.getPushers() ?? [];
          final nonce = ownFcmGateway
              ? await const FlutterSecureStorage().read(
                  key: 'personal_gateway_nonce',
                )
              : null;
          if (ownFcmGateway && !validGatewayNonce(nonce)) {
            throw StateError('Private gateway registration required');
          }
          desired = Pusher(
            pushkey: token,
            appId: thisAppId,
            appDisplayName: appDisplayName,
            deviceDisplayName: client.deviceName ?? appDisplayName,
            lang: 'en',
            data: PusherData(
              url: Uri.parse(gatewayUrl),
              format: AppSettings.pushNotificationsPusherFormat.value,
              additionalProperties: {
                'client_name': client.clientName,
                'data_message': pusherDataMessageFormat,
                'gateway_nonce': ?nonce,
              },
            ),
            kind: 'http',
          );
          alreadySet = pushers.any(
            (p) =>
                p.pushkey == token &&
                p.appId == thisAppId &&
                p.kind == 'http' &&
                p.appDisplayName == appDisplayName &&
                p.deviceDisplayName == desired!.deviceDisplayName &&
                p.lang == 'en' &&
                p.data.url.toString() == gatewayUrl &&
                p.data.format == desired!.data.format &&
                p.data.additionalProperties['client_name'] ==
                    client.clientName &&
                p.data.additionalProperties['data_message'] ==
                    pusherDataMessageFormat &&
                p.data.additionalProperties['gateway_nonce'] == nonce,
          );
        },
        post: () async {
          if (!alreadySet) await client.postPusher(desired!, append: true);
        },
        finish: () async {
          for (final old in pushers.where(
            (p) =>
                p.appId == thisAppId &&
                p.pushkey != token &&
                p.kind == 'http' &&
                p.data.url.toString() == gatewayUrl &&
                p.data.additionalProperties['client_name'] ==
                    client.clientName &&
                p.data.additionalProperties['data_message'] ==
                    pusherDataMessageFormat,
          )) {
            if (!current()) return;
            await client.deletePusher(old);
          }
        },
      );
      if (completed && ownFcmGateway) {
        _pusherPhases[client] = PushRegistrationPhase.pusherConfigured;
        _changed();
      }
    } catch (_) {
      if (current() && ownFcmGateway) {
        _pusherPhases[client] = PushRegistrationPhase.failed;
        _changed();
      }
      // No raw exception, token, account or gateway URL in diagnostics.
      Logs().w('[Push] registration_failed');
    }
  }

  Future<void> _processPush(Future<void> Function() process) async {
    final inBackground = PlatformInfos.isAndroid &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
    if (inBackground) await ForegroundServices.startService('background_push');
    try {
      await process();
    } catch (error) {
      // FcmSharedIsolate invokes a void callback and cannot observe its Future.
      // Handle failures here without exposing a payload or account identifier.
      Logs().w('[Push] processing_failed', error.runtimeType.toString());
    } finally {
      if (inBackground) await ForegroundServices.stopService('background_push');
    }
  }

  Future<void> handleFcmMessage(Map<String, dynamic> message) => _processPush(() async {
    final data = message.tryGetMap<String, Object>('data') ?? message;
    if (data['personal_wake'] == 'reminder') {
      await personalReminderWake(
        clients: clients,
        plugin: _flutterLocalNotificationsPlugin,
      );
      return;
    }
    await pushHelper(
      PushNotification.fromJson(data),
      clients: clients,
      l10n: l10n,
      activeRoomId: matrix?.activeRoomId,
      flutterLocalNotificationsPlugin: _flutterLocalNotificationsPlugin,
    );
  });

  final pusherDataMessageFormat = Platform.isAndroid;

  static bool _wentToRoomOnStartup = false;

  Future<void> setupPush(BuildContext context) async {
    await ready;
    if (!context.mounted) return;
    if (PlatformInfos.isAndroid &&
        (await UnifiedPush.getDistributors()).isNotEmpty &&
        context.mounted) {
      await UnifiedPushUi(
        context: context,
        instances: ['default'],
        unifiedPushFunctions: UPFunctions(),
        showNoDistribDialog: false,
        onNoDistribDialogDismissed: () {}, // TODO: Implement me
      ).registerAppWithDialog();
    } else {
      for (final client in clients) {
        Logs().d('SetupPush for Client ${client.clientName}');
        if (client.onLoginStateChanged.value != LoginState.loggedIn ||
            !PlatformInfos.isMobile ||
            matrix == null) {
          continue;
        }
        // Do not setup unifiedpush if this has been initialized by
        // an unifiedpush action
        if (upAction) {
          return;
        }
        await setupFirebase(client);
      }
    }

    // ignore: unawaited_futures
    _flutterLocalNotificationsPlugin.getNotificationAppLaunchDetails().then((
      details,
    ) {
      if (details == null ||
          !details.didNotificationLaunchApp ||
          _wentToRoomOnStartup) {
        return;
      }
      _wentToRoomOnStartup = true;
      final response = details.notificationResponse;
      if (response != null) {
        notificationTap(
          response,
          clients: clients,
          router: FluffyChatApp.router,
          l10n: l10n,
        );
      }
    });
  }

  Future<void> _noFcmWarning() async {
    if (matrix == null) {
      return;
    }
    if (AppSettings.showNoGoogle.value) {
      return;
    }
    await loadLocale();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (PlatformInfos.isAndroid) {
        onFcmError?.call(
          l10n!.noGoogleServicesWarning,
          link: Uri.parse(AppConfig.enablePushTutorial),
        );
        return;
      }
      onFcmError?.call(l10n!.oopsPushError);
    });
  }

  Future<void> setupFirebase(Client client) async {
    Logs().v('Setup firebase');
    if (!firebaseEnabled) {
      await _noFcmWarning();
      return;
    }
    // Query the native cache on every setup: a rotation may have happened
    // while this isolate was stopped. A newer callback wins over this read.
    try {
      if (PlatformInfos.isIOS) await firebase.requestPermission();
      for (var i = 0; i < 5; i++) {
        final revision = _registration.revision;
        final token = await firebase.getToken();
        if (revision == _registration.revision &&
            token != null &&
            token.isNotEmpty) {
          await _acceptFcmToken(token);
        }
        if (_fcmToken != null) break;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      if (_fcmToken == null) {
        _registration.phase = PushRegistrationPhase.tokenUnavailable;
        _changed();
        await _noFcmWarning();
        return;
      }
      await _tokenPersistence;
      await _queueFirebaseRegistration(client);
    } catch (_) {
      _pusherPhases[client] = PushRegistrationPhase.failed;
      _changed();
    }
  }

  Future<void> _newUpEndpoint(PushEndpoint newPushEndpoint, String i) async {
    final newEndpoint = newPushEndpoint.url;
    upAction = true;
    if (newEndpoint.isEmpty) {
      await _upUnregistered(i);
      return;
    }
    var endpoint =
        'https://matrix.gateway.unifiedpush.org/_matrix/push/v1/notify';
    try {
      final url = Uri.parse(newEndpoint)
          .replace(path: '/_matrix/push/v1/notify', query: '')
          .toString()
          .split('?')
          .first;
      final res = json.decode(
        utf8.decode((await http.get(Uri.parse(url))).bodyBytes),
      );
      if (res['gateway'] == 'matrix' ||
          (res['unifiedpush'] is Map &&
              res['unifiedpush']['gateway'] == 'matrix')) {
        endpoint = url;
      }
    } catch (_) {
      Logs().i('[Push] No self-hosted unified push gateway present');
    }
    Logs().i('[Push] UnifiedPush gateway selected');

    for (final client in clients) {
      await setupPusher(
        client: client,
        gatewayUrl: endpoint,
        token: newEndpoint,
      );
    }
    await AppSettings.unifiedPushEndpoint.setItem(newEndpoint);
    await AppSettings.unifiedPushRegistered.setItem(true);
  }

  Future<void> _upUnregistered(String i) async {
    upAction = true;
    Logs().i('[Push] Removing UnifiedPush endpoint...');
    await AppSettings.unifiedPushEndpoint.setItem(
      AppSettings.unifiedPushEndpoint.defaultValue,
    );
    await AppSettings.unifiedPushRegistered.setItem(false);
  }

  Future<void> _onUpMessage(PushMessage pushMessage, String i) => _processPush(() async {
    final message = pushMessage.content;
    upAction = true;
    final data = Map<String, dynamic>.from(
      json.decode(utf8.decode(message))['notification'],
    );
    // UP may strip the devices list
    data['devices'] ??= [];
    await pushHelper(
      PushNotification.fromJson(data),
      clients: clients,
      l10n: l10n,
      activeRoomId: matrix?.activeRoomId,
      flutterLocalNotificationsPlugin: _flutterLocalNotificationsPlugin,
    );
  });
}

class UPFunctions extends UnifiedPushFunctions {
  final List<String> features = [
    /*list of features*/
  ];

  @override
  Future<String?> getDistributor() async {
    return await UnifiedPush.getDistributor();
  }

  @override
  Future<List<String>> getDistributors() async {
    return await UnifiedPush.getDistributors(features);
  }

  @override
  Future<void> registerApp(String instance) async {
    await UnifiedPush.register(instance: instance, features: features);
  }

  @override
  Future<void> saveDistributor(String distributor) async {
    await UnifiedPush.saveDistributor(distributor);
  }
}

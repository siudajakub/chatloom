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

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/main.dart';
import 'package:chatloom/personal/automatic_push.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/own_sender.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/push_diagnostics.dart';
import 'package:chatloom/personal/push_registration.dart';
import 'package:chatloom/utils/notification_background_handler.dart';
import 'package:chatloom/utils/push_helper.dart';
import 'package:chatloom/widgets/chatloom_app.dart';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:fcm_shared_isolate/fcm_shared_isolate.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart' show PersonalNotificationMode;
import 'package:unifiedpush/unifiedpush.dart';
import 'package:unifiedpush_ui/unifiedpush_ui.dart';

import '../config/app_config.dart';
import '../config/setting_keys.dart';
import '../widgets/matrix.dart';
import 'platform_infos.dart';
import 'push_registration_retry.dart';
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
    setRegistrationForeground(false);
    _clients = List<Client>.from(owner.widget.clients);
    matrix = null;
    onFcmError = null;
  }

  void forgetClients(Iterable<Client> abandoned) {
    final owned = abandoned.toSet();
    for (final client in owned) {
      _registrationRetry.forget(client);
      _pusherPhases.remove(client);
    }
    _clients = _clients.where((client) => !owned.contains(client)).toList();
  }

  final _registration = PushRegistration();
  final registrationChanges = ValueNotifier<int>(0);
  final _pusherPhases = <Client, PushRegistrationPhase>{};
  Future<void> _registrationQueue = Future<void>.value();
  Future<void> _tokenPersistence = Future<void>.value();
  late final PushRegistrationRetry<Client> _registrationRetry;

  void setRegistrationForeground(bool foreground) =>
      _registrationRetry.setForeground(foreground);
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
      _registrationRetry.reset();
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
    _registrationRetry.reset();
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
    _registrationRetry.reset();
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
        gatewayUrl:
            usesAutomaticPush(AppSettings.pushNotificationsGatewayUrl.value)
            ? personalPushGateway
            : AppSettings.pushNotificationsGatewayUrl.value,
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
        (await L10n.delegate.load(AppConfig.appLocale));
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
            router: ChatLoomApp.router,
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
              router: ChatLoomApp.router,
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
              router: ChatLoomApp.router,
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
    _registrationRetry = PushRegistrationRetry<Client>(
      retry: _queueFirebaseRegistration,
      eligible: (client) =>
          clients.contains(client) &&
          client.isLogged() &&
          !upAction &&
          !_registration.updating &&
          usesAutomaticPush(AppSettings.pushNotificationsGatewayUrl.value),
      onExhausted: (client) {
        _pusherPhases[client] = PushRegistrationPhase.failed;
        _changed();
      },
    );
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
    instance.setRegistrationForeground(
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    );
    // Surfaces that only need the shared instance (e.g. settings) must not
    // drop the error callback registered by MatrixState.
    if (onFcmError != null) instance.onFcmError = onFcmError;
    unawaited(instance._openLaunchNotification());
    return instance;
  }

  /// A notification tap that launched the app opens its chat as soon as the
  /// router has rendered and an account is signed in, independent of push
  /// registration (which may wait for permission dialogs or the network).
  Future<void> _openLaunchNotification() async {
    if (_wentToRoomOnStartup) return;
    try {
      await ready;
      final details = await _flutterLocalNotificationsPlugin
          .getNotificationAppLaunchDetails();
      final response = details?.notificationResponse;
      if (details == null ||
          !details.didNotificationLaunchApp ||
          response == null ||
          _wentToRoomOnStartup) {
        return;
      }
      _wentToRoomOnStartup = true;
      await WidgetsBinding.instance.endOfFrame;
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!clients.any((client) => client.isLogged()) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      await notificationTap(
        response,
        clients: clients,
        router: ChatLoomApp.router,
        l10n: l10n,
      );
    } catch (_) {
      Logs().w('[Push] launch_notification_failed');
    }
  }

  /// Update only this account/device's pusher while its session and token are
  /// current. The default gateway enrolls with an OpenID identity proof first.
  Future<void> setupPusher({
    required Client client,
    String? gatewayUrl,
    String? token,
  }) async {
    if (gatewayUrl == null || token == null || token.isEmpty) return;
    if (!clients.contains(client) || !client.isLogged()) return;
    final owner = client.userID;
    final device = client.deviceID;
    final configuredGateway = AppSettings.pushNotificationsGatewayUrl.value;
    final ownFcmGateway =
        (gatewayUrl == configuredGateway ||
            (usesAutomaticPush(configuredGateway) &&
                gatewayUrl == personalPushGateway)) &&
        token == _fcmToken;
    final automatic = ownFcmGateway && usesAutomaticPush(configuredGateway);
    if (automatic && clients.where((c) => c.isLogged()).length != 1) {
      _pusherPhases[client] = PushRegistrationPhase.multipleAccounts;
      _changed();
      return;
    }
    final revision = _registration.revision;
    bool current() =>
        clients.contains(client) &&
        client.isLogged() &&
        client.userID == owner &&
        client.deviceID == device &&
        owner != null &&
        device != null &&
        (!automatic || clients.where((c) => c.isLogged()).length == 1) &&
        (!ownFcmGateway ||
            (!upAction &&
                !_registration.updating &&
                configuredGateway ==
                    AppSettings.pushNotificationsGatewayUrl.value &&
                _registration.current(revision, token, true)));
    if (!current()) return;
    final appDisplayName = PlatformInfos.appDisplayName;
    var appId = '${AppConfig.pushNotificationsAppId}.$device';
    if (appId.length > 64) appId = appId.substring(0, 64);
    final thisAppId = appId;
    var pushers = <Pusher>[];
    Pusher? desired;
    var alreadySet = false;
    var permissionGranted = true;
    String? nonce;
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
            permissionGranted =
                await _flutterLocalNotificationsPlugin
                    .resolvePlatformSpecificImplementation<
                      AndroidFlutterLocalNotificationsPlugin
                    >()
                    ?.areNotificationsEnabled() ??
                false;
          }
          if (!current()) return;
          pushers = await client.getPushers() ?? [];
          if (!current()) return;
          nonce = ownFcmGateway
              ? await const FlutterSecureStorage().read(
                  key: 'personal_gateway_nonce',
                )
              : null;
          if (!current()) return;
          if (automatic) {
            if (!validGatewayNonce(nonce)) {
              nonce = newPushNonce();
              await const FlutterSecureStorage().write(
                key: 'personal_gateway_nonce',
                value: nonce,
              );
            }
            if (!current()) return;
            final transport = http.Client();
            try {
              final enrolled = await enrollAutomaticPush(
                transport: transport,
                user: owner!,
                appId: thisAppId,
                token: token,
                nonce: nonce!,
                openId: () async =>
                    (await client.requestOpenIdToken(owner, {})).toJson(),
                current: current,
              );
              if (!enrolled) return;
            } finally {
              transport.close();
            }
          }
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
              format: automatic
                  ? 'event_id_only'
                  : AppSettings.pushNotificationsPusherFormat.value,
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
      if (completed && ownFcmGateway && current()) {
        _registrationRetry.forget(client);
        _pusherPhases[client] = !permissionGranted
            ? PushRegistrationPhase.permissionRequired
            : automatic
            ? PushRegistrationPhase.automaticallyConfigured
            : PushRegistrationPhase.pusherConfigured;
        _changed();
      }
    } catch (error) {
      if (current() && ownFcmGateway) {
        _pusherPhases[client] =
            error is PushEnrollmentFailure && error.forbidden
            ? PushRegistrationPhase.notAuthorized
            : automatic
            ? PushRegistrationPhase.retrying
            : PushRegistrationPhase.failed;
        _changed();
        if (automatic && !(error is PushEnrollmentFailure && error.forbidden)) {
          _registrationRetry.failed(client);
        } else {
          _registrationRetry.forget(client);
        }
      }
      // No raw exception, token, account or gateway URL in diagnostics.
      Logs().w('[Push] registration_failed');
    }
  }

  Future<void> _processPush(Future<void> Function() process) async {
    final inBackground =
        PlatformInfos.isAndroid &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
    final acquired =
        inBackground &&
        await ForegroundServices.startService('background_push');
    try {
      await process();
    } catch (error) {
      // FcmSharedIsolate invokes a void callback and cannot observe its Future.
      // Handle failures here without exposing a payload or account identifier.
      Logs().w('[Push] processing_failed', error.runtimeType.toString());
    } finally {
      if (acquired) await ForegroundServices.stopService('background_push');
    }
  }

  /// Real FCM messages: a remote `personal_test` key is ignored.
  Future<void> handleFcmMessage(Map<String, dynamic> message) =>
      _handleFcmMessage(message);

  Future<void> _handleFcmMessage(
    Map<String, dynamic> message, {
    bool test = false,
  }) =>
      _processPush(() async {
        final data = message.tryGetMap<String, Object>('data') ?? message;
        final kind = pushKindOf(data, test: test);
        await PushDiagnostics.received(kind);
        if (kind == PushKind.reminder) {
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
          test: kind == PushKind.test,
        );
      });

  /// Runs the real FCM message path with the gateway's exact data map for
  /// the newest message from someone else. Only the "already read" and
  /// "chat open" checks are skipped; the title says "(test)". Returns the
  /// recorded outcome; nothing leaves the device.
  Future<PushDiagnosticsEntry?> sendTestNotification(Client client) async {
    final room = await testNotificationRoom(client);
    if (room == null) return null;
    final unread = client.rooms.fold<int>(
      0,
      (count, room) => count + room.notificationCount,
    );
    await _handleFcmMessage(
      testFcmData(
        eventId: room.lastEvent!.eventId,
        roomId: room.id,
        unread: unread,
      ),
      test: true,
    );
    return (await PushDiagnostics.read()).last;
  }

  /// Read-only checks of this device's pusher against local registration
  /// state. Exposes yes/no answers only, never the values.
  Future<PushPusherCheck?> checkPusher(Client client) async {
    final device = client.deviceID;
    if (!client.isLogged() || device == null) return null;
    var appId = '${AppConfig.pushNotificationsAppId}.$device';
    if (appId.length > 64) appId = appId.substring(0, 64);
    final pushers = (await client.getPushers() ?? const <Pusher>[])
        .where((p) => p.appId == appId && p.kind == 'http')
        .toList();
    final token = _fcmToken;
    final pusher =
        pushers.firstWhereOrNull((p) => p.pushkey == token) ??
        pushers.firstOrNull;
    final configured = AppSettings.pushNotificationsGatewayUrl.value;
    final gateway = usesAutomaticPush(configured)
        ? personalPushGateway
        : configured;
    String? nonce;
    try {
      nonce = await const FlutterSecureStorage().read(
        key: 'personal_gateway_nonce',
      );
    } catch (_) {
      nonce = null;
    }
    return PushPusherCheck(
      exists: pusher != null,
      tokenMatches: pusher != null && token != null && pusher.pushkey == token,
      urlMatches: pusher != null && pusher.data.url.toString() == gateway,
      formatEventIdOnly: pusher?.data.format == 'event_id_only',
      nonceMatches:
          pusher != null &&
          nonce != null &&
          pusher.data.additionalProperties['gateway_nonce'] == nonce,
    );
  }

  final pusherDataMessageFormat = Platform.isAndroid;

  static bool _wentToRoomOnStartup = false;

  Future<void> setupPush(BuildContext context) async {
    await ready;
    if (!context.mounted) return;
    final foreground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    setRegistrationForeground(foreground);
    if (foreground) _registrationRetry.reset();
    // Permission dialogs belong to a visible setup, never to token callbacks
    // or automatic background retries.
    if (PlatformInfos.isAndroid && !isIntegrationTest) {
      await _flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      if (!context.mounted) return;
    }
    if (PlatformInfos.isAndroid &&
        (!usesAutomaticPush(AppSettings.pushNotificationsGatewayUrl.value) ||
            AppSettings.unifiedPushRegistered.value) &&
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
      for (final client in List<Client>.from(clients)) {
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
    // A notification that launched the app is opened by
    // _openLaunchNotification, independent of this setup.
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
        onFcmError?.call(l10n!.noGoogleServicesWarning);
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
      if (!clients.contains(client) || !client.isLogged()) return;
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

  Future<void> _onUpMessage(PushMessage pushMessage, String i) =>
      _processPush(() async {
        final message = pushMessage.content;
        upAction = true;
        final data = Map<String, dynamic>.from(
          json.decode(utf8.decode(message))['notification'],
        );
        // UP may strip the devices list
        data['devices'] ??= [];
        await PushDiagnostics.received(
          data['event_id'] is String ? PushKind.message : PushKind.countOnly,
        );
        await pushHelper(
          PushNotification.fromJson(data),
          clients: clients,
          l10n: l10n,
          activeRoomId: matrix?.activeRoomId,
          flutterLocalNotificationsPlugin: _flutterLocalNotificationsPlugin,
        );
      });
}

/// Exactly the data map the Personal gateway sends to FCM. The test flag is
/// passed in-process, never inside the data.
Map<String, String> testFcmData({
  required String eventId,
  required String roomId,
  required int unread,
}) => {
  'event_id': eventId,
  'room_id': roomId,
  'counts': jsonEncode({'unread': unread}),
  'devices': '[]',
};

/// Newest joined chat whose last event is a message from somebody else,
/// preferring chats that notify for every message.
Future<Room?> testNotificationRoom(Client client) async {
  final own = OwnSenderResolver.of(client);
  final candidates =
      client.rooms.where((room) {
        final last = room.lastEvent;
        return room.membership == Membership.join &&
            !PersonalPrivacy.isJournal(room) &&
            last != null &&
            last.eventId.startsWith(r'$') &&
            {
              EventTypes.Message,
              EventTypes.Encrypted,
              EventTypes.Sticker,
            }.contains(last.type) &&
            last.messageType != MessageTypes.Notice &&
            !own.isOwnEvent(last);
      }).toList()..sort(
        (a, b) =>
            b.lastEvent!.originServerTs.compareTo(a.lastEvent!.originServerTs),
      );
  if (candidates.isEmpty) return null;
  InboxProjection? projection;
  try {
    final personal = PersonalClient.of(client);
    await personal.loadLocal();
    projection = InboxProjection(personal);
  } catch (_) {
    projection = null;
  }
  return candidates.firstWhereOrNull(
        (room) =>
            room.pushRuleState == PushRuleState.notify &&
            (projection == null ||
                projection.notificationModeFor(room) ==
                    PersonalNotificationMode.all),
      ) ??
      candidates.first;
}

class PushPusherCheck {
  final bool exists;
  final bool tokenMatches;
  final bool urlMatches;
  final bool formatEventIdOnly;
  final bool nonceMatches;
  const PushPusherCheck({
    required this.exists,
    required this.tokenMatches,
    required this.urlMatches,
    required this.formatEventIdOnly,
    required this.nonceMatches,
  });

  bool get healthy =>
      exists && tokenMatches && urlMatches && formatEventIdOnly && nonceMatches;
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

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
import 'package:chatloom/utils/notification_client_routing.dart';
import 'package:chatloom/utils/personal_secure_storage.dart';
import 'package:chatloom/utils/push_helper.dart';
import 'package:chatloom/widgets/chatloom_app.dart';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:fcm_shared_isolate/fcm_shared_isolate.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart' show PersonalNotificationMode;
import 'package:unifiedpush/unifiedpush.dart';
import 'package:unifiedpush_ui/unifiedpush_ui.dart';

import '../config/app_config.dart';
import '../config/setting_keys.dart';
import '../widgets/matrix.dart';
import 'background_push_catch_up.dart';
import 'platform_infos.dart';
import 'push_registration_retry.dart';
import 'start_push_foreground_service.dart';

class BackgroundPush {
  /// Method channel of `fcm_shared_isolate` (Kotlin and Dart side).
  static const fcmChannel = 'fcm_shared_isolate';

  /// Keeps every FCM message that arrives before the push listener exists.
  ///
  /// A push that starts the app cold reaches Dart long before startup has
  /// opened the encrypted store and created [BackgroundPush]. Until then
  /// Flutter buffers platform messages per channel, by default only one: a
  /// second message (another chat writing during start-up) silently replaced
  /// the first. Called first thing in `main`, before any await; needs no
  /// binding.
  static void bufferEarlyMessages() {
    try {
      channelBuffers.resize(fcmChannel, 64);
    } catch (_) {}
  }

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

  void setRegistrationForeground(bool foreground) {
    _registrationRetry.setForeground(foreground);
    if (foreground) _recoverOnResume();
  }

  int get registrationRevision => _registration.revision;

  /// Last time [_recoverOnResume] started a fresh series.
  DateTime? _lastResumeRecovery;

  /// How long a failed setup waits before returning to the app retries it.
  static const resumeRecoveryInterval = Duration(minutes: 30);

  /// The bounded retries stop after five attempts (about 13 minutes). A
  /// gateway or network outage can outlast them, and the app may then stay
  /// in memory for days without another start. Coming back to the app after
  /// that starts a fresh series, at most every [resumeRecoveryInterval]; it
  /// never shows a permission dialog. A build without Firebase is not
  /// retried: no attempt can succeed.
  void _recoverOnResume() {
    if (!firebaseEnabled ||
        upAction ||
        _registration.updating ||
        !usesAutomaticPush(AppSettings.pushNotificationsGatewayUrl.value)) {
      return;
    }
    final now = DateTime.now();
    final last = _lastResumeRecovery;
    if (last != null && now.difference(last) < resumeRecoveryInterval) return;
    for (final client in List<Client>.from(clients)) {
      if (!client.isLogged()) continue;
      final phase = registrationPhase(client);
      if (phase != PushRegistrationPhase.failed &&
          phase != PushRegistrationPhase.tokenUnavailable) {
        continue;
      }
      _lastResumeRecovery = now;
      _registrationRetry.forget(client);
      unawaited(setupFirebase(client, quiet: true));
    }
  }

  String? get _fcmToken => _registration.token;
  String? get fcmToken => _fcmToken;

  /// Why the last token request failed (a [pushSetupFailureDetail] word), or
  /// null once a token was received in this process.
  String? tokenFailure;

  /// Whether this build can talk to Firebase at all; false when the APK was
  /// built without `google-services.json`. Null until a token was requested.
  bool? get firebaseConfigured => _fcmToken != null
      ? true
      : tokenFailure == null
      ? null
      : tokenFailure != firebaseNotConfiguredDetail;

  /// Pause between two token requests of one setup.
  @visibleForTesting
  static Duration tokenRetryDelay = const Duration(seconds: 1);

  /// The notify URL the account's pusher should point at.
  String get gatewayUrl {
    final configured = AppSettings.pushNotificationsGatewayUrl.value;
    return usesAutomaticPush(configured) ? personalPushGateway : configured;
  }

  /// Whether the next pusher update is posted even when an identical pusher
  /// is listed (one-tap re-register).
  bool _forcePusherPost = false;
  String registrationDescription(Client client) {
    final view = PushRegistration()
      ..phase = _pusherPhases[client] ?? _registration.phase;
    view.rotated = _registration.rotated;
    return view.description;
  }

  /// Current setup phase of [client]'s notifications (inbox status row);
  /// `unknown` where automatic push is not used.
  PushRegistrationPhase registrationPhase(Client client) =>
      !firebaseEnabled || upAction
      ? PushRegistrationPhase.unknown
      : _pusherPhases[client] ?? _registration.phase;

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
      const storage = personalSecureStorage;
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
        ),
        onDidReceiveNotificationResponse: (response) async {
          // A warm tap arrives here; Android also keeps it as the activity's
          // intent, which a later launch check must not open again.
          handledLaunchNotifications.add(response);
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
    } catch (e, s) {
      Logs().e('Unable to initialize Flutter local notifications', e, s);
    }
    // Independent of the step above: a failed notification setup must not
    // leave FCM messages and token updates without a listener forever.
    try {
      if (firebaseEnabled) {
        firebase.setListeners(
          onMessage: handleFcmMessage,
          onNewToken: (token) => unawaited(_onNewFcmToken(token)),
        );
      }
    } catch (_) {
      Logs().w('[Push] fcm_listener_failed');
    }
    try {
      if (Platform.isAndroid) {
        await UnifiedPush.initialize(
          onNewEndpoint: _newUpEndpoint,
          onRegistrationFailed: (_, i) => _upUnregistered(i),
          onUnregistered: _upUnregistered,
          onMessage: _onUpMessage,
        );
      }
    } catch (_) {
      Logs().w('[Push] unifiedpush_init_failed');
    }
  }

  BackgroundPush._(this._clients) {
    _registrationRetry = PushRegistrationRetry<Client>(
      // Without a token there is nothing to register yet: fetch it again.
      retry: (client) => _fcmToken == null
          ? setupFirebase(client, quiet: true)
          : _queueFirebaseRegistration(client),
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
    // Settings pages ask for the shared instance with the same MatrixState;
    // only a new app surface (MatrixState) checks the launch notification.
    final attached = !identical(instance.matrix, matrix);
    instance.matrix = matrix;
    instance.setRegistrationForeground(
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    );
    // Surfaces that only need the shared instance (e.g. settings) must not
    // drop the error callback registered by MatrixState.
    if (onFcmError != null) instance.onFcmError = onFcmError;
    if (attached) unawaited(instance._openLaunchNotification());
    return instance;
  }

  /// Notification responses already opened in this process (warm taps and
  /// launches), so a launch check never replays one (code-client CC-21).
  @visibleForTesting
  static final handledLaunchNotifications = HandledNotificationResponses();

  /// A notification tap that launched the app opens its chat as soon as the
  /// router has rendered and an account is signed in, independent of push
  /// registration (which may wait for permission dialogs or the network).
  /// Android reports the activity's current intent, which after a warm tap
  /// is that tap: such a response, or one already opened, is never replayed.
  Future<void> _openLaunchNotification() async {
    try {
      await ready;
      final details = await _flutterLocalNotificationsPlugin
          .getNotificationAppLaunchDetails();
      final response = details?.notificationResponse;
      if (details == null ||
          !details.didNotificationLaunchApp ||
          response == null ||
          !handledLaunchNotifications.add(response)) {
        return;
      }
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
    if (gatewayUrl == null || gatewayUrl.isEmpty) return;
    if (token == null || token.isEmpty) return;
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
    // Which step a failure belongs to, for the diagnostics page.
    var step = PushSetupStep.pusher;
    final force = ownFcmGateway && _forcePusherPost;
    try {
      final completed = await registerCurrentPush(
        current: current,
        prepare: () async {
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
              ? await personalSecureStorage.read(
                  key: 'personal_gateway_nonce',
                )
              : null;
          if (!current()) return;
          if (automatic) {
            if (!validGatewayNonce(nonce)) {
              nonce = newPushNonce();
              await personalSecureStorage.write(
                key: 'personal_gateway_nonce',
                value: nonce,
              );
            }
            if (!current()) return;
            final transport = http.Client();
            step = PushSetupStep.gateway;
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
              unawaited(
                PushDiagnostics.setup(
                  PushSetupStep.gateway,
                  ok: true,
                  detail: 'registered',
                ),
              );
            } finally {
              transport.close();
            }
            step = PushSetupStep.pusher;
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
          alreadySet =
              !force &&
              pushers.any(
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
          // A token belongs to this one install. The same token under an
          // older ChatLoom app id is a session of this phone that was signed
          // out without its pusher being removed. The gateway moved the
          // token to the new app id and rejects the old one; a homeserver
          // that removes pushers by token on rejection could then remove
          // the current pusher too. Remove the stale one first.
          if (!ownFcmGateway) return;
          for (final stale in pushers.where(
            (p) =>
                p.pushkey == token &&
                p.appId != thisAppId &&
                p.appId.startsWith('${AppConfig.pushNotificationsAppId}.') &&
                p.kind == 'http' &&
                p.data.url.toString() == gatewayUrl,
          )) {
            if (!current()) return;
            try {
              await client.deletePusher(stale);
            } catch (_) {
              // Best effort: the current pusher is already saved.
              Logs().w('[Push] stale_pusher_cleanup_failed');
            }
          }
        },
      );
      if (completed && ownFcmGateway && current()) {
        if (force) _forcePusherPost = false;
        unawaited(
          PushDiagnostics.setup(
            PushSetupStep.pusher,
            ok: true,
            detail: alreadySet ? 'already_set' : 'posted',
          ),
        );
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
        unawaited(
          PushDiagnostics.setup(
            step,
            ok: false,
            detail: pushSetupFailureDetail(error),
          ),
        );
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
        final outcome = await pushHelper(
          PushNotification.fromJson(data),
          clients: clients,
          activeRoomId: matrix?.activeRoomId,
          flutterLocalNotificationsPlugin: _flutterLocalNotificationsPlugin,
          test: kind == PushKind.test,
        );
        if (kind == PushKind.message) await _catchUpAfter(outcome);
      });

  /// Catch-up after a message notification shown in the background (see
  /// [PushCatchUp]); runs inside the push's short foreground service.
  @visibleForTesting
  final pushCatchUp = PushCatchUp();

  Future<void> _catchUpAfter(PushOutcome outcome) async {
    if (!PushCatchUp.wanted(
      outcome,
      mobile: PlatformInfos.isMobile,
      lifecycle: WidgetsBinding.instance.lifecycleState,
    )) {
      return;
    }
    // The gateway's pushes carry no account: the single signed-in one.
    final client = selectNotificationClient<Client>(
      clients,
      null,
      (client) => client.clientName,
      isLoggedIn: (client) => client.isLogged(),
    );
    if (client == null) return;
    await pushCatchUp.run(client);
  }

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
    final gateway = gatewayUrl;
    String? nonce;
    try {
      nonce = await personalSecureStorage.read(
        key: 'personal_gateway_nonce',
      );
    } catch (_) {
      nonce = null;
    }
    return PushPusherCheck(
      exists: pusher != null,
      tokenKnown: token != null,
      tokenMatches: pusher != null && token != null && pusher.pushkey == token,
      urlMatches: pusher != null && pusher.data.url.toString() == gateway,
      formatEventIdOnly: pusher?.data.format == 'event_id_only',
      nonceMatches:
          pusher != null &&
          nonce != null &&
          pusher.data.additionalProperties['gateway_nonce'] == nonce,
    );
  }

  /// Plain GET of the gateway's notify URL from this phone (see
  /// [probePushGateway]); sends no token, key or account.
  Future<PushGatewayProbe> probeGateway() async {
    final transport = http.Client();
    try {
      return await probePushGateway(transport, gatewayUrl);
    } finally {
      transport.close();
    }
  }

  final pusherDataMessageFormat = Platform.isAndroid;

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

  /// Fetches the FCM token and registers it. [quiet] (automatic retries)
  /// never shows the "no Google services" dialog again.
  Future<void> setupFirebase(Client client, {bool quiet = false}) async {
    Logs().v('Setup firebase');
    if (!firebaseEnabled) {
      await _noFcmWarning();
      return;
    }
    // Query the native cache on every setup: a rotation may have happened
    // while this isolate was stopped. A newer callback wins over this read.
    try {
      Object? failure;
      for (var i = 0; i < 5; i++) {
        final revision = _registration.revision;
        try {
          final token = await firebase.getToken().timeout(
            const Duration(seconds: 20),
          );
          failure = null;
          if (revision == _registration.revision &&
              token != null &&
              token.isNotEmpty) {
            await _acceptFcmToken(token);
          }
        } catch (error) {
          // Each attempt fails on its own: Play services may still be
          // starting. A build without Firebase can never get a token.
          failure = error;
          if (pushSetupFailureDetail(error) == firebaseNotConfiguredDetail) {
            break;
          }
        }
        if (_fcmToken != null) break;
        await Future<void>.delayed(tokenRetryDelay);
      }
      if (_fcmToken == null) {
        final detail = failure == null
            ? 'token_unavailable'
            : pushSetupFailureDetail(failure);
        tokenFailure = detail;
        _pusherPhases.remove(client);
        final noFirebase = detail == firebaseNotConfiguredDetail;
        _registration.phase = noFirebase
            ? PushRegistrationPhase.firebaseUnavailable
            : PushRegistrationPhase.tokenUnavailable;
        _changed();
        Logs().w('[Push] token_unavailable', detail);
        unawaited(
          PushDiagnostics.setup(PushSetupStep.token, ok: false, detail: detail),
        );
        if (noFirebase) return;
        if (usesAutomaticPush(AppSettings.pushNotificationsGatewayUrl.value)) {
          // Try again later in the foreground (bounded), not only on restart.
          _registrationRetry.failed(client);
        }
        if (!quiet) await _noFcmWarning();
        return;
      }
      tokenFailure = null;
      unawaited(PushDiagnostics.setup(PushSetupStep.token, ok: true));
      await _tokenPersistence;
      await _queueFirebaseRegistration(client);
    } catch (_) {
      if (!clients.contains(client) || !client.isLogged()) return;
      _pusherPhases[client] = PushRegistrationPhase.failed;
      _changed();
    }
  }

  /// One-tap repair from the diagnostics page: a fresh registration series
  /// (token, gateway, pusher) that also re-posts the account's pusher. It is
  /// a visible action, so Android may ask for the notification permission.
  Future<void> reregister(BuildContext context) async {
    _lastResumeRecovery = null;
    beginRegistrationUpdate();
    endRegistrationUpdate();
    _forcePusherPost = true;
    if (!context.mounted) return;
    await setupPush(context);
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
        final outcome = await pushHelper(
          PushNotification.fromJson(data),
          clients: clients,
          activeRoomId: matrix?.activeRoomId,
          flutterLocalNotificationsPlugin: _flutterLocalNotificationsPlugin,
        );
        await _catchUpAfter(outcome);
      });
}

/// Notification responses already opened, by content (id, action, payload).
/// Bounded; the same tap reported again (Android keeps it as the activity
/// intent) is recognized, a new notification is not.
class HandledNotificationResponses {
  static const _limit = 32;
  final _keys = <String>[];

  static String _key(NotificationResponse response) => [
    response.notificationResponseType.name,
    response.id,
    response.actionId,
    response.payload,
  ].join('\u0000');

  /// Records [response]; false when it was already recorded.
  bool add(NotificationResponse response) {
    final key = _key(response);
    if (_keys.contains(key)) return false;
    _keys.add(key);
    if (_keys.length > _limit) _keys.removeAt(0);
    return true;
  }

  bool contains(NotificationResponse response) =>
      _keys.contains(_key(response));

  @visibleForTesting
  void clear() => _keys.clear();
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

  /// Whether this process knows its FCM token; without it [tokenMatches]
  /// cannot be decided.
  final bool tokenKnown;
  final bool tokenMatches;
  final bool urlMatches;
  final bool formatEventIdOnly;
  final bool nonceMatches;
  const PushPusherCheck({
    required this.exists,
    this.tokenKnown = true,
    required this.tokenMatches,
    required this.urlMatches,
    required this.formatEventIdOnly,
    required this.nonceMatches,
  });

  /// Everything the gateway needs: the pusher exists, carries this phone's
  /// token, points at the gateway and has the gateway key. The format is not
  /// required: Beeper's homeserver drops it and the gateway accepts that.
  bool get healthy => exists && tokenMatches && urlMatches && nonceMatches;
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

// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/events/round_mini_player.dart';
import 'package:chatloom/personal/media/media_access.dart';
import 'package:chatloom/personal/person_location.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/round_video/round_capture_controller.dart';
import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:chatloom/personal/round_video/telegram_round_service.dart';
import 'package:chatloom/personal/voice_playback.dart';
import 'package:chatloom/utils/client_manager.dart';
import 'package:chatloom/utils/init_with_restore.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/matrix_file_extension.dart';
import 'package:chatloom/utils/notification_background_handler.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/utils/sync_network_recovery.dart';
import 'package:chatloom/utils/uia_request_manager.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:chatloom/widgets/chatloom_app.dart';
import 'package:chatloom/widgets/future_loading_dialog.dart';
import 'package:collection/collection.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_html/html.dart' as html;
import 'package:url_launcher/url_launcher_string.dart';

import '../config/app_config.dart';
import '../config/setting_keys.dart';
import '../pages/key_verification/key_verification_dialog.dart';
import '../utils/account_bundles.dart';
import '../utils/background_push.dart';
import 'local_notifications_extension.dart';

class Matrix extends StatefulWidget {
  final Widget? child;

  final List<Client> clients;

  final Map<String, String>? queryParameters;

  final SharedPreferences store;

  const Matrix({
    this.child,
    required this.clients,
    required this.store,
    this.queryParameters,
    super.key,
  });

  @override
  MatrixState createState() => MatrixState();

  /// Returns the (nearest) Client instance of your application.
  static MatrixState of(BuildContext context) =>
      Provider.of<MatrixState>(context, listen: false);
}

class MatrixState extends State<Matrix> {
  int _activeClient = -1;
  String? activeBundle;

  SharedPreferences get store => widget.store;

  BackgroundPush? backgroundPush;

  final ValueNotifier<String?> activeCallRoomId = ValueNotifier(null);
  final ValueNotifier<CallPosition> callPosition = ValueNotifier(
    CallPosition.fullScreen,
  );

  Client get client {
    if (_activeClient < 0 || _activeClient >= widget.clients.length) {
      return currentBundle!.first!;
    }
    return widget.clients[_activeClient];
  }

  bool get isMultiAccount => widget.clients.length > 1;

  int getClientIndexByMatrixId(String matrixId) =>
      widget.clients.indexWhere((client) => client.userID == matrixId);

  void setActiveClient(Client? cl) {
    if (cl != client) {
      PersonalPrivacy.invalidatePlayedIntents();
      unawaited(
        RoundPlaybackCoordinator.shared
            .stopAll(suspend: false)
            .catchError((Object _) {}),
      );
      unawaited(
        RoundCaptureController.interruptActive().catchError((Object _) {}),
      );
    }
    final i = widget.clients.indexWhere((c) => c == cl);
    if (i != -1) {
      _activeClient = i;
    } else {
      Logs().w('Tried to set an unknown client ${cl!.userID} as active');
    }
  }

  List<Client?>? get currentBundle {
    if (!hasComplexBundles) {
      return List.from(widget.clients);
    }
    final bundles = accountBundles;
    if (bundles.containsKey(activeBundle)) {
      return bundles[activeBundle];
    }
    return bundles.values.first;
  }

  Map<String?, List<Client?>> get accountBundles {
    final resBundles =
        <String?, List<({Client? client, AccountBundle? bundle})>>{};
    for (var i = 0; i < widget.clients.length; i++) {
      final bundles = widget.clients[i].accountBundles;
      for (final bundle in bundles) {
        if (bundle.name == null) {
          continue;
        }
        resBundles[bundle.name] ??= [];
        resBundles[bundle.name]!.add((
          client: widget.clients[i],
          bundle: bundle,
        ));
      }
    }
    for (final b in resBundles.values) {
      b.sort(
        (a, b) => a.bundle!.priority == null
            ? 1
            : b.bundle!.priority == null
            ? -1
            : a.bundle!.priority!.compareTo(b.bundle!.priority!),
      );
    }
    return resBundles.map(
      (k, v) => MapEntry(k, v.map((vv) => vv.client).toList()),
    );
  }

  bool get hasComplexBundles => accountBundles.values.any((v) => v.length > 1);

  Client? _loginClientCandidate;

  AudioPlayer? _audioPlayer;
  Stream<Duration>? _audioProgress;
  StreamSubscription<ProcessingState>? _audioCompletion;
  List<Event> Function()? _audioContinuation;

  /// The one voice player (a single decoder): a new note replaces it.
  AudioPlayer? get audioPlayer => _audioPlayer;
  set audioPlayer(AudioPlayer? player) {
    if (identical(player, _audioPlayer)) return;
    _audioPlayer = player;
    _audioProgress = null;
    _audioContinuation = null;
    unawaited(_audioCompletion?.cancel());
    _audioCompletion = null;
  }

  /// Position updates for the voice UI, created once per player: 5–10 per
  /// second instead of `positionStream`'s up to 60 on short notes.
  Stream<Duration> audioProgress(AudioPlayer player) =>
      identical(player, _audioPlayer)
      ? _audioProgress ??= player.createPositionStream(
          minPeriod: const Duration(milliseconds: 100),
          maxPeriod: const Duration(milliseconds: 200),
        )
      : const Stream<Duration>.empty();

  /// Voice notes played in this session (in memory), for continuation.
  final voicePlayed = VoicePlayedNotes();

  /// The voice speed, remembered across notes and restarts like Telegram.
  double get voiceSpeed {
    try {
      return VoicePlayback.validSpeed(
        AppSettings.personalVoicePlaybackSpeed.value,
      );
    } catch (_) {
      return 1;
    }
  }

  Future<void> setVoiceSpeed(AudioPlayer player, double speed) async {
    await player.setSpeed(speed);
    try {
      await AppSettings.personalVoicePlaybackSpeed.setItem(speed);
    } catch (_) {
      /* The player keeps the speed for this note. */
    }
  }

  RoundPlaybackHandle? audioPlaybackHandle;
  RoundPlaybackHandle reserveAudio() =>
      audioPlaybackHandle ??= RoundPlaybackCoordinator.shared.register(
        pause: _pauseAudio,
        stop: closeAudioPlayer,
        // Backgrounding without a lock pauses the note and keeps its
        // position; a lock or an account switch still closes it.
        retain: _pauseAudio,
      );
  Future<void> _pauseAudio() async {
    final current = audioPlayer;
    if (current == null) {
      await closeAudioPlayer();
      return;
    }
    try {
      await current.pause();
    } catch (_) {
      // A player that cannot pause is released; it never keeps playing.
      await closeAudioPlayer();
    }
  }

  Future<void> playAudio() async {
    final player = audioPlayer;
    if (player == null) return;
    final handle = reserveAudio();
    if ((handle.isCurrent || await handle.acquireAudible()) &&
        handle.isCurrent &&
        identical(player, audioPlayer)) {
      unawaited(player.play().catchError((Object _) {}));
    }
  }

  /// Watches [player], just created for a note, for its end. Then it is
  /// released and, given a [continuation], the following voice notes play
  /// (Telegram). [continuation] is read only once the note has ended.
  void watchAudio(AudioPlayer player, {List<Event> Function()? continuation}) {
    if (!identical(player, audioPlayer)) return;
    _audioContinuation = continuation;
    unawaited(_audioCompletion?.cancel());
    _audioCompletion = player.processingStateStream
        .where((state) => state == ProcessingState.completed)
        .take(1)
        .listen(
          (_) => unawaited(_audioCompleted(player)),
          onError: (Object _) {},
        );
  }

  Future<void> _audioCompleted(AudioPlayer player) async {
    if (!identical(player, audioPlayer)) return;
    var queue = const <Event>[];
    try {
      queue = _audioContinuation?.call() ?? const <Event>[];
    } catch (_) {
      /* No continuation. */
    }
    final speed = voiceSpeed;
    final coordinator = RoundPlaybackCoordinator.shared;
    // Reserved while the ended note still holds audio, so nothing the user
    // starts meanwhile is taken over by a slow download of the next one.
    final token =
        queue.isNotEmpty &&
            audioPlaybackHandle?.isCurrent == true &&
            PersonalPrivacy.surfaceUnlocked
        ? coordinator.beginContinuation()
        : null;
    try {
      await closeAudioPlayer();
    } catch (_) {
      /* Released either way. */
    }
    if (token == null) return;
    await VoiceContinuation.run(
      queue,
      token: token,
      speed: speed,
      allowed: () =>
          mounted && PersonalPrivacy.surfaceUnlocked && !coordinator.suspended,
      detached: (items) => RoundMiniPlayerController.shared.continueQueue(
        items,
        token: token,
        speed: speed,
      ),
    );
  }

  ManagedMediaFile? audioLease;
  int audioRequestGeneration = 0;
  MediaAccess? _audioAccess;
  Future<MediaAccess> get audioMediaAccess async =>
      _audioAccess ??= await MediaAccess.open(
        directory: Directory(
          '${(await getTemporaryDirectory()).path}/personal_audio',
        ),
      );
  Future<void> closeAudioPlayer({bool invalidateRequests = true}) async {
    if (invalidateRequests) audioRequestGeneration++;
    final player = audioPlayer;
    final lease = audioLease;
    audioPlaybackHandle?.dispose();
    audioPlaybackHandle = null;
    audioPlayer = null;
    audioLease = null;
    voiceMessageEventId.value = null;
    try {
      try {
        await player?.stop();
      } finally {
        await player?.dispose();
      }
    } finally {
      await lease?.close();
    }
  }

  final ValueNotifier<String?> voiceMessageEventId = ValueNotifier(null);

  Future<Client> getLoginClient() async {
    if (widget.clients.isNotEmpty && !client.isLogged()) {
      return client;
    }
    final candidate = _loginClientCandidate ??=
        await ClientManager.createClient(
            '${AppConfig.legacyStorageAppName}-${DateTime.now().millisecondsSinceEpoch}',
            store,
          )
          ..onLoginStateChanged.stream
              .where((l) => l == LoginState.loggedIn)
              .first
              .then((_) {
                if (!widget.clients.contains(_loginClientCandidate)) {
                  widget.clients.add(_loginClientCandidate!);
                }
                ClientManager.addClientNameToStore(
                  _loginClientCandidate!.clientName,
                  store,
                );
                _registerSubs(_loginClientCandidate!.clientName);
                setActiveClient(_loginClientCandidate);
                _loginClientCandidate = null;
                ChatLoomApp.router.go('/backup');
              });
    if (widget.clients.isEmpty) widget.clients.add(candidate);
    return candidate;
  }

  Client? getClientByName(String name) =>
      widget.clients.firstWhereOrNull((c) => c.clientName == name);

  final onRoomKeyRequestSub = <String, StreamSubscription>{};
  final onKeyVerificationRequestSub = <String, StreamSubscription>{};
  final onNotification = <String, StreamSubscription>{};
  final onPersonalReminder = <String, StreamSubscription>{};
  final onLogoutSub = <String, StreamSubscription<LoginState>>{};
  final onUiaRequest = <String, StreamSubscription<UiaRequest>>{};

  String? _cachedPassword;
  Timer? _cachedPasswordClearTimer;

  String? get cachedPassword => _cachedPassword;

  set cachedPassword(String? p) {
    Logs().d('Password cached');
    _cachedPasswordClearTimer?.cancel();
    _cachedPassword = p;
    _cachedPasswordClearTimer = Timer(const Duration(minutes: 10), () {
      _cachedPassword = null;
      Logs().d('Cached Password cleared');
    });
  }

  String? get activeRoomId {
    final route = ChatLoomApp.router.routeInformationProvider.value.uri.path;
    if (!route.startsWith('/rooms/')) return null;
    return route.split('/')[2];
  }

  @override
  void initState() {
    super.initState();
    _listener = AppLifecycleListener(onStateChange: didChangeAppLifecycleState);
    initMatrix();
  }

  AppLifecycleListener? _listener;
  StreamSubscription<List<ConnectivityResult>>? _networkChanges;

  @override
  void didUpdateWidget(covariant Matrix oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Startup retries append only successfully restored clients. Reuse the
    // active healthy account and subscribe to the newly available account.
    for (final client in widget.clients) {
      _registerSubs(client.clientName);
    }
  }

  void _registerSubs(String name) {
    final c = getClientByName(name);
    if (c == null) {
      Logs().w(
        'Attempted to register subscriptions for non-existing client $name',
      );
      return;
    }
    onRoomKeyRequestSub[name] ??= c.onRoomKeyRequest.stream.listen((
      RoomKeyRequest request,
    ) async {
      if (widget.clients.any(
        ((cl) =>
            cl.userID == request.requestingDevice.userId &&
            cl.identityKey == request.requestingDevice.curve25519Key),
      )) {
        Logs().i(
          '[Key Request] Request is from one of our own clients, forwarding the key...',
        );
        await request.forwardKey();
      }
    });
    onKeyVerificationRequestSub[name] ??= c.onKeyVerificationRequest.stream
        .listen((KeyVerification request) async {
          var hidPopup = false;
          request.onUpdate = () {
            if (!hidPopup &&
                {
                  KeyVerificationState.done,
                  KeyVerificationState.error,
                }.contains(request.state)) {
              ChatLoomApp.router.pop('dialog');
            }
            hidPopup = true;
          };
          request.onUpdate = null;
          hidPopup = true;
          await KeyVerificationDialog(request: request).show(
            ChatLoomApp.router.routerDelegate.navigatorKey.currentContext ??
                context,
          );
        });
    onLogoutSub[name] ??= c.onLoginStateChanged.stream
        .where((state) => state == LoginState.loggedOut)
        .listen((_) {
          final loggedInWithMultipleClients = widget.clients.length > 1;

          _cancelSubs(c.clientName);
          backgroundPush?.forgetClients([c]);
          PersonalPrivacy.forget(c);
          PersonalClient.of(c).dispose();
          widget.clients.remove(c);
          ClientManager.removeClientNameFromStore(c.clientName, store);
          InitWithRestoreExtension.deleteSessionBackup(name);

          if (loggedInWithMultipleClients) {
            final snackbarContext =
                ChatLoomApp.router.routerDelegate.navigatorKey.currentContext ??
                context;

            if (!snackbarContext.mounted) return;
            final l10n = L10n.of(snackbarContext);
            ScaffoldMessenger.of(
              snackbarContext,
            ).showSnackBar(SnackBar(content: Text(l10n.oneClientLoggedOut)));
            return;
          }
          ChatLoomApp.router.go('/');
        });
    onUiaRequest[name] ??= c.onUiaRequest.stream.listen(uiaRequestHandler);
    if (!kIsWeb && c.isLogged()) {
      final personal = PersonalClient.of(c);
      if (PlatformInfos.supportsSystemNotifications) {
        onPersonalReminder[name] ??= personal.changes.listen((_) {
          for (final event in personal.dueReminderEvents) {
            unawaited(showLocalNotification(event).catchError((Object _) {}));
          }
        });
      }
      unawaited(personal.load());
    }

    if (PlatformInfos.isWeb || PlatformInfos.isDesktop) {
      if (PlatformInfos.supportsSystemNotifications) {
        FlutterLocalNotificationsPlugin().initialize(
          settings: InitializationSettings(
            linux: LinuxInitializationSettings(
              defaultActionName: ChatLoomNotificationActions.open.name,
            ),
            windows: ClientManager.windowsNotificationSettings,
            macOS: const DarwinInitializationSettings(),
          ),
          onDidReceiveNotificationResponse: (response) => notificationTap(
            response,
            clients: widget.clients,
            router: ChatLoomApp.router,
            l10n: null,
          ),
        );
      }
      c.onSync.stream.first.then((s) {
        if (!mounted || !widget.clients.contains(c) || !c.isLogged()) return;
        if (kIsWeb) html.Notification.requestPermission();
        onNotification[name] ??= c.onNotification.stream.listen(
          showLocalNotification,
        );
      });
    }
  }

  void _cancelSubs(String name) {
    onPersonalReminder.remove(name)?.cancel();
    onUiaRequest.remove(name)?.cancel();
    onRoomKeyRequestSub[name]?.cancel();
    onRoomKeyRequestSub.remove(name);
    onKeyVerificationRequestSub[name]?.cancel();
    onKeyVerificationRequestSub.remove(name);
    onLogoutSub[name]?.cancel();
    onLogoutSub.remove(name);
    onNotification[name]?.cancel();
    onNotification.remove(name);
  }

  void initMatrix() {
    for (final c in widget.clients) {
      _registerSubs(c.clientName);
    }

    if (PlatformInfos.isDesktop || PlatformInfos.isMobile) {
      // A Wi-Fi <-> mobile switch leaves the long-poll on a dead socket for up
      // to 40 s plus the retry backoff; restart it at once while the app is
      // open. The platform callback is event-driven: no polling.
      final recovery = SyncNetworkRecovery(
        foreground: () =>
            !PlatformInfos.isMobile ||
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
      );
      _networkChanges = Connectivity().onConnectivityChanged.listen(
        (networks) => unawaited(
          recovery
              .onNetworksChanged(widget.clients, networks)
              .catchError((Object _) {}),
        ),
        onError: (Object _, StackTrace _) {
          // Keep automatic retries if the optional platform watcher is unavailable.
          Logs().w('Network recovery watcher unavailable');
        },
      );
    }
    if (PlatformInfos.isMobile) {
      for (final client in widget.clients) {
        client.syncErrorMaxTimeoutSec = foregroundSyncRetryCapSec;
      }
    }

    if (PlatformInfos.isMobile) {
      backgroundPush = BackgroundPush(
        this,
        onFcmError: (errorMsg, {Uri? link}) async {
          final context =
              ChatLoomApp.router.routerDelegate.navigatorKey.currentContext ??
              this.context;
          if (!context.mounted) return;
          final result = await showOkCancelAlertDialog(
            context: context,
            title: L10n.of(context).pushNotificationsNotAvailable,
            message: errorMsg,
            okLabel: link == null
                ? L10n.of(context).ok
                : L10n.of(context).learnMore,
            cancelLabel: L10n.of(context).doNotShowAgain,
          );
          if (result == OkCancelResult.ok && link != null) {
            launchUrlString(
              link.toString(),
              mode: LaunchMode.externalApplication,
            );
          }
          if (result == OkCancelResult.cancel) {
            await AppSettings.showNoGoogle.setItem(true);
          }
        },
      );
    }
  }

  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    backgroundPush?.setRegistrationForeground(foreground);
    for (final client in widget.clients) {
      client.syncPresence = PersonalPrivacy.policy.allowOnlinePresence
          ? (state == AppLifecycleState.resumed
                ? null
                : PresenceType.unavailable)
          : PresenceType.offline;
      if (PlatformInfos.isMobile) {
        // The loop only runs in the foreground on phones; keep its retries
        // short there (see [foregroundSyncRetryCapSec]).
        client.syncErrorMaxTimeoutSec = foregroundSyncRetryCapSec;
        client.backgroundSync = foreground;
        client.requestHistoryOnLimitedTimeline = !foreground;
        Logs().v('Set background sync to', foreground);
      } else if (foreground) {
        // Resume promptly even if the desktop sync loop is backing off offline.
        unawaited(client.oneShotSync().catchError((Object _) {}));
      }
    }
  }

  @override
  void dispose() {
    _cachedPasswordClearTimer?.cancel();
    _cachedPassword = null;
    backgroundPush?.detachMatrix(this);
    unawaited(
      RoundPlaybackCoordinator.shared.stopAll().catchError((Object _) {}),
    );
    for (final client in widget.clients) {
      unawaited(TelegramRoundService.closeFor(client));
    }
    closeAudioPlayer();
    _listener?.dispose();
    unawaited(_networkChanges?.cancel());

    for (final sub in onPersonalReminder.values) {
      sub.cancel();
    }
    onPersonalReminder.clear();
    for (final sub in onRoomKeyRequestSub.values) {
      sub.cancel();
    }
    for (final sub in onKeyVerificationRequestSub.values) {
      sub.cancel();
    }
    for (final sub in onLogoutSub.values) {
      sub.cancel();
    }
    for (final sub in onNotification.values) {
      sub.cancel();
    }
    for (final sub in onUiaRequest.values) {
      sub.cancel();
    }
    onRoomKeyRequestSub.clear();
    onKeyVerificationRequestSub.clear();
    onLogoutSub.clear();
    onNotification.clear();
    onUiaRequest.clear();

    voiceMessageEventId.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Provider(
      create: (_) => this,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child ?? const SizedBox.shrink(),
          Positioned(
            left: 16,
            right: 16,
            bottom: MediaQuery.viewInsetsOf(context).bottom + 80,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: RoundMiniPlayer(
                  onOpenSource: (event) {
                    if (client != event.room.client) {
                      setActiveClient(event.room.client);
                    }
                    ChatLoomApp.router.go(
                      conversationLocation(event.room, eventId: event.eventId),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> dehydrateAction(BuildContext context) async {
    final l10n = L10n.of(context);
    final response = await showOkCancelAlertDialog(
      context: context,
      isDestructive: true,
      title: l10n.dehydrate,
      message: l10n.dehydrateWarning,
    );
    if (response != OkCancelResult.ok) {
      return;
    }
    if (!context.mounted) return;
    final result = await showFutureLoadingDialog(
      context: context,
      future: client.exportDump,
    );
    final export = result.result;
    if (export == null) return;

    final exportBytes = Uint8List.fromList(const Utf8Codec().encode(export));

    final exportFileName =
        'chatloom-export-${DateFormat(DateFormat.YEAR_MONTH_DAY).format(DateTime.now())}.fluffybackup';

    final file = MatrixFile(bytes: exportBytes, name: exportFileName);
    if (!context.mounted) return;
    file.save(context);
  }
}

enum CallPosition { fullScreen, top }

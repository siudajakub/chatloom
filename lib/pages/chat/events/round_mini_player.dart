// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/round_video/round_media_loader.dart';
import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:chatloom/personal/round_video/round_playback_queue.dart';
import 'package:chatloom/personal/round_video/telegram_round_service.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/scheduler.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:video_player/video_player.dart';

import '../conversation_motion.dart';
import 'round_video_stage.dart';
import 'round_video_view.dart';

/// Ownership transfer, not a second player or a copied plaintext file.
class RoundDetachedPlayback {
  final Event event;
  VideoPlayerController? video;
  AudioPlayer? audio;
  RoundLoadedMedia? media;
  RoundPlaybackHandle? handle;
  final RoundPlaybackIntent intent;
  final List<Event> queue;
  bool userInitiated, locallyPlayed, receiptAttempted;
  double speed;

  /// Enlarge the next round when it continues in its own row.
  final bool enlarge;

  /// Loader of the row that started the queue; null uses the default.
  final RoundMediaLoader? loader;

  /// Continuation preparing this detached item, if any.
  RoundContinuationToken? continuation;
  bool loading = false, disposed = false;
  bool reporting = false;

  /// Set once when playback ends or fails, so duplicate end events (and a
  /// failure racing a completion) continue the queue exactly once.
  bool finished = false;
  String? error;
  RoundMediaCancellation? request;
  StreamSubscription<Object?>? positionSubscription,
      stateSubscription,
      redactionSubscription;
  VoidCallback? serviceListener;
  TelegramRoundService? boundService;
  RoundDetachedPlayback({
    required this.event,
    this.video,
    this.audio,
    this.media,
    this.handle,
    required this.intent,
    this.queue = const [],
    this.userInitiated = false,
    this.locallyPlayed = false,
    this.receiptAttempted = false,
    this.speed = 1,
    this.enlarge = false,
    this.loader,
  });
  Duration get position =>
      video?.value.position ?? audio?.position ?? Duration.zero;
  Duration get duration =>
      video?.value.duration ?? audio?.duration ?? Duration.zero;
  bool get playing => video?.value.isPlaying ?? audio?.playing ?? false;

  Future<void> cancelPlaybackSubscriptions() async {
    final pending = <Future<void>>[
      if (positionSubscription != null) positionSubscription!.cancel(),
      if (stateSubscription != null) stateSubscription!.cancel(),
    ];
    positionSubscription = null;
    stateSubscription = null;
    await Future.wait(pending);
  }

  Future<void> cancelSubscriptions() async {
    final playback = cancelPlaybackSubscriptions();
    final redaction = redactionSubscription?.cancel();
    redactionSubscription = null;
    await playback;
    await redaction;
  }

  @override
  String toString() => 'RoundDetachedPlayback(managed)';
}

/// Persists audible playback when a timeline row is recycled, and drives
/// autoplay continuation (the next round or voice message after one ended).
/// Lifetime ends on explicit stop, completion, lock/background, source
/// invalidation or switch. Holds at most one decoder; nothing it does throws
/// into the zone (which would open the global error dialog).
class RoundMiniPlayerController extends ChangeNotifier
    with WidgetsBindingObserver {
  static final shared = RoundMiniPlayerController();
  RoundDetachedPlayback? _current;
  final RoundMediaLoader _loader;
  final RoundPlaybackCoordinator _coordinator;
  bool _closed = false;
  RoundMiniPlayerController({
    RoundMediaLoader? loader,
    RoundPlaybackCoordinator? coordinator,
  }) : _loader = loader ?? RoundMediaLoader(),
       _coordinator = coordinator ?? RoundPlaybackCoordinator.shared {
    WidgetsBinding.instance.addObserver(this);
  }
  RoundDetachedPlayback? get current => _current;

  /// Test seams: the verified bridge state lookup (SQLCipher store), the
  /// media loader and the voice player of detached continuations.
  @visibleForTesting
  static Future<Map<String, dynamic>?> Function(Event event)? debugMediaState;
  @visibleForTesting
  static RoundMediaLoader? debugLoader;
  @visibleForTesting
  static AudioPlayer Function()? debugCreateAudio;

  /// A codec that never reports `initialized` must not hold the queue.
  static const _initializeTimeout = Duration(seconds: 20);

  bool _valid(RoundDetachedPlayback session) =>
      identical(session, _current) &&
      !session.disposed &&
      PersonalPrivacy.surfaceUnlocked &&
      !_coordinator.suspended &&
      !session.event.redacted &&
      RoundMediaPolicy.fromContent(session.event.content).canPlay &&
      TelegramRoundService.of(
            session.event.room.client,
          ).verifiedMediaStateSnapshot(session.event)?['expired'] !=
          true;

  void _notify() {
    if (_closed) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_closed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  void adopt(RoundDetachedPlayback session) {
    final previous = _current;
    _current = session;
    if (previous != null && previous != session) {
      unawaited(_disposeSession(previous));
    }
    _bind(session);
    _notify();
  }

  RoundDetachedPlayback? takeFor(Event event) {
    final session = _current;
    if (session == null ||
        !_valid(session) ||
        session.finished ||
        event.redacted ||
        !RoundMediaPolicy.fromContent(event.content).canPlay ||
        RoundVideoDescriptor.fromContent(event.content) == null ||
        session.event.attachmentMxcUrl != event.attachmentMxcUrl ||
        session.video == null ||
        session.loading ||
        !identical(session.event.room.client, event.room.client) ||
        session.event.room.id != event.room.id ||
        session.event.eventId != event.eventId) {
      return null;
    }
    _unbind(session);
    _current = null;
    _notify();
    return session;
  }

  RoundStageActions _stageActions(RoundDetachedPlayback session) =>
      RoundStageActions(
        toggle: toggle,
        seek: seek,
        setSpeed: setSpeed,
        stop: () => _stopSession(session),
        reportPlayed: reportPlayed,
        canReportPlayed: () {
          if (!identical(_current, session) || session.reporting) return false;
          final service = TelegramRoundService.of(session.event.room.client);
          return session.locallyPlayed &&
              service.incognito &&
              service.canExplicitlyReport(session.event);
        },
        event: session.event,
      );

  void _bind(RoundDetachedPlayback session) {
    session.handle?.rebind(
      pause: () => _stopSession(session),
      stop: () => _stopSession(session),
    );
    final video = session.video;
    // A row recycled while enlarged hands its stage to this owner.
    if (video != null) {
      RoundStageController.shared.rebind(video, _stageActions(session));
    }
    session.video?.addListener(_onProgress);
    session.positionSubscription = session.audio?.positionStream.listen(
      (_) => _onProgress(),
    );
    session.stateSubscription = session.audio?.playerStateStream.listen(
      (_) => _onProgress(),
    );
    final service = TelegramRoundService.of(session.event.room.client);
    session.boundService = service;
    session.serviceListener = () {
      if (!identical(_current, session) || session.disposed) return;
      if (!_valid(session)) unawaited(_stopSession(session));
    };
    service.addListener(session.serviceListener!);
    session.redactionSubscription = session
        .event
        .room
        .client
        .onTimelineEvent
        .stream
        .listen((event) {
          if (!identical(_current, session) || session.disposed) return;
          if (event.room.id == session.event.room.id &&
              event.type == EventTypes.Redaction &&
              event.redacts == session.event.eventId) {
            unawaited(_stopSession(session));
          }
        });
  }

  void _unbind(RoundDetachedPlayback session) {
    session.video?.removeListener(_onProgress);
    unawaited(session.cancelSubscriptions().catchError((Object _) {}));
    if (session.serviceListener != null) {
      session.boundService?.removeListener(session.serviceListener!);
      session.serviceListener = null;
      session.boundService = null;
    }
  }

  void _onProgress() {
    final session = _current;
    if (session == null || session.finished) return;
    if (!_valid(session)) {
      unawaited(_stopSession(session));
      return;
    }
    // Loading reports its own errors through [_playDetached].
    if (session.loading) return;
    if (session.video?.value.hasError == true) {
      unawaited(_finish(session));
      return;
    }
    if (session.intent.didAdvance(
      position: session.position,
      isPlaying: session.playing,
      audiblePermit: session.handle?.isCurrent == true,
    )) {
      session.locallyPlayed = true;
      final service = TelegramRoundService.of(session.event.room.client);
      if (!session.receiptAttempted &&
          !service.incognito &&
          RoundVideoDescriptor.fromContent(session.event.content) != null) {
        session.receiptAttempted = true;
        unawaited(
          service.onUserStartedPlaying(session.event).catchError((Object _) {}),
        );
      }
    }
    final complete =
        session.duration > Duration.zero &&
        (session.video?.value.isCompleted == true ||
            session.audio?.processingState == ProcessingState.completed ||
            session.position >= session.duration);
    if (complete && session.handle?.isCurrent == true) {
      unawaited(_finish(session));
      return;
    }
    _notify();
  }

  Future<void> toggle() async {
    final session = _current;
    if (session == null || session.loading || !_valid(session)) return;
    if (session.video == null && session.audio == null) return;
    try {
      if (session.playing) {
        await _pause(session);
        session.handle?.releaseAudible();
      } else {
        if (!await session.handle!.acquireAudible() ||
            !_valid(session) ||
            !session.handle!.isCurrent) {
          return;
        }
        if (session.position >= session.duration) await seek(Duration.zero);
        session.userInitiated = true;
        session.intent.begin(position: session.position, userInitiated: true);
        await session.video?.play();
        final audio = session.audio;
        if (audio != null) {
          unawaited(audio.play().catchError((Object _) => _finish(session)));
        }
      }
    } catch (_) {
      await _stopSession(session);
    }
    _notify();
  }

  Future<void> _pause(RoundDetachedPlayback session) async {
    session.userInitiated = false;
    session.intent.pause();
    try {
      await session.video?.pause();
      await session.audio?.pause();
    } catch (_) {
      // A player that cannot pause is released; it never keeps playing.
      await _stopSession(session);
    }
    _notify();
  }

  Future<void> seek(Duration position) async {
    final session = _current;
    if (session == null || !_valid(session)) return;
    session.intent.begin(
      position: position,
      userInitiated: session.userInitiated,
    );
    try {
      await session.video?.seekTo(position);
      await session.audio?.seek(position);
    } catch (_) {
      /* The position stays where the player is. */
    }
    _notify();
  }

  Future<void> setSpeed(double value) async {
    final session = _current;
    if (session == null || !_valid(session)) return;
    session.speed = value.clamp(.2, 3.0);
    try {
      await session.video?.setPlaybackSpeed(session.speed);
      await session.audio?.setSpeed(session.speed);
    } catch (_) {
      /* The next item applies the chosen speed. */
    }
    _notify();
  }

  Future<void> reportPlayed() async {
    final session = _current;
    if (session == null ||
        !_valid(session) ||
        !session.locallyPlayed ||
        session.reporting) {
      return;
    }
    final service = TelegramRoundService.of(session.event.room.client);
    if (!service.canExplicitlyReport(session.event)) return;
    session.reporting = true;
    session.error = null;
    _notify();
    try {
      // On success the action disappears (canExplicitlyReport is false).
      await service.explicitlyReportPlayed(session.event);
    } catch (_) {
      session.error = 'Playback receipt was not sent.';
    } finally {
      session.reporting = false;
      _notify();
    }
  }

  /// The current detached item ended: continue its queue.
  Future<void> advance() async {
    final session = _current;
    if (session != null) await _finish(session);
  }

  /// Ends [session] once (completion or a decoder error) and continues its
  /// queue. The continuation is reserved while [session] still holds audio,
  /// and its decoder is released before the next one opens.
  Future<void> _finish(RoundDetachedPlayback session) async {
    if (session.finished || session.disposed) return;
    session.finished = true;
    final token = session.queue.isNotEmpty && session.handle?.isCurrent == true
        ? _coordinator.beginContinuation()
        : null;
    await _stopSession(session);
    if (token == null) return;
    await continueQueue(
      session.queue,
      token: token,
      speed: session.speed,
      enlarge: session.enlarge,
      loader: session.loader,
    );
  }

  static bool _isRound(Event event) =>
      RoundVideoDescriptor.fromContent(
        event.content,
        redacted: event.redacted,
      ) !=
      null;

  static bool _continuable(Event event) =>
      !event.redacted &&
      event.type == EventTypes.Message &&
      RoundMediaPolicy.fromContent(event.content).canPersist &&
      (_isRound(event) || event.messageType == MessageTypes.Audio);

  /// Plays [queue] in order after an item ended, like Telegram: a round with a
  /// mounted timeline row plays there (scrolled into view, enlarged again when
  /// the finished one was); anything else plays detached here. An item that
  /// cannot play is skipped; an explicit play, lock, background or account
  /// switch ([token]) stops the walk. Continuation is audible but never
  /// creates played receipts. The token is always ended when the walk stops,
  /// unless a newer driver claimed it. Never throws.
  Future<void> continueQueue(
    List<Event> queue, {
    required RoundContinuationToken token,
    double speed = 1,
    bool enlarge = false,
    RoundMediaLoader? loader,
  }) async {
    var handedOff = false;
    try {
      final claim = token.claim();
      final pending = List<Event>.of(queue);
      while (pending.isNotEmpty) {
        if (!token.active ||
            _closed ||
            _coordinator.suspended ||
            !PersonalPrivacy.surfaceUnlocked) {
          return;
        }
        final event = pending.removeAt(0);
        if (!_continuable(event)) continue;
        final rest = List<Event>.unmodifiable(pending);
        final target = _isRound(event)
            ? RoundContinuationTargets.shared.targetFor(event)
            : null;
        final result = target != null
            ? await target.startContinuation(
                rest,
                token: token,
                speed: speed,
                enlarge: enlarge,
              )
            : await _playDetached(
                event,
                rest,
                token: token,
                speed: speed,
                enlarge: enlarge,
                loader: loader,
              );
        switch (result) {
          case RoundStartResult.started:
            return;
          case RoundStartResult.failed:
            continue;
          case RoundStartResult.aborted:
            // Superseded (explicit play, lock, background): stop.
            if (!token.active) return;
            // A row disposed while preparing handed this item and the rest
            // to a newer driver, which now owns (and ends) the token.
            if (!token.isClaimedBy(claim)) {
              handedOff = true;
              return;
            }
            // Busy or gone without a decision: skip it, keep going.
            continue;
        }
      }
    } catch (_) {
      /* Ends the token below. */
    } finally {
      if (!handedOff) token.end();
    }
  }

  /// One detached continuation item; [RoundStartResult.failed] skips it.
  Future<RoundStartResult> _playDetached(
    Event event,
    List<Event> rest, {
    required RoundContinuationToken token,
    required double speed,
    required bool enlarge,
    RoundMediaLoader? loader,
  }) async {
    final round = _isRound(event);
    final session =
        RoundDetachedPlayback(
            event: event,
            intent: RoundPlaybackIntent(),
            queue: rest,
            speed: speed,
            enlarge: enlarge,
            loader: loader,
          )
          ..loading = true
          ..continuation = token;
    session.handle = _coordinator.register(
      pause: () => _stopSession(session),
      stop: () => _stopSession(session),
      // A voice queue keeps playing while a Mac window is hidden (MAC-04).
      keepWhileHidden: !round,
    );
    final previous = _current;
    _current = session;
    if (previous != null && !identical(previous, session)) {
      unawaited(_disposeSession(previous));
    }
    _bind(session);
    _notify();
    try {
      // Reserve audio before any async preparation: a later explicit player
      // cancels this continuation instead of being stolen by a slow download.
      if (!await session.handle!.acquireAudible(continuation: token) ||
          !_valid(session)) {
        await _stopSession(session);
        return RoundStartResult.aborted;
      }
      final state =
          await (debugMediaState?.call(event) ??
              TelegramRoundService.of(event.room.client).mediaState(event));
      if (state?['expired'] == true) {
        await _stopSession(session);
        return RoundStartResult.failed;
      }
      if (!_valid(session)) {
        await _stopSession(session);
        return RoundStartResult.aborted;
      }
      final request = session.request = RoundMediaCancellation(
        sourceValid: () => _valid(session) && session.handle!.isCurrent,
      );
      final source = loader ?? debugLoader ?? _loader;
      final media = round
          ? await source.load(event, cancellation: request)
          : await source.loadVoice(event, cancellation: request);
      if (!_valid(session)) {
        await media.close();
        await _stopSession(session);
        return RoundStartResult.aborted;
      }
      session.media = media;
      if (round) {
        final video = session.video = media.lease != null
            ? VideoPlayerController.file(media.lease!.file)
            : VideoPlayerController.networkUrl(media.dataUri!);
        video.addListener(_onProgress);
        await video.initialize().timeout(_initializeTimeout);
        await video.setPlaybackSpeed(session.speed);
      } else {
        final audio = session.audio = debugCreateAudio?.call() ?? AudioPlayer();
        session.positionSubscription = audio.positionStream.listen(
          (_) => _onProgress(),
        );
        session.stateSubscription = audio.playerStateStream.listen(
          (_) => _onProgress(),
        );
        if (media.lease != null) {
          await audio.setFilePath(media.lease!.file.path);
        } else {
          await audio.setAudioSource(AudioSource.uri(media.dataUri!));
        }
        await audio.setSpeed(session.speed);
      }
      if (!_valid(session) || !session.handle!.isCurrent) {
        await _stopSession(session);
        return RoundStartResult.aborted;
      }
      session.loading = false;
      session.continuation = null;
      // Continuation is audible but receipt-silent. A later explicit tap
      // can create played intent; assembly/queue autoplay cannot.
      session.intent.begin(position: session.position, userInitiated: false);
      await session.video?.play();
      final audio = session.audio;
      if (audio != null) {
        unawaited(audio.play().catchError((Object _) => _finish(session)));
      }
      _notify();
      return RoundStartResult.started;
    } catch (_) {
      final superseded = session.disposed || session.handle?.isCurrent != true;
      await _stopSession(session);
      return superseded ? RoundStartResult.aborted : RoundStartResult.failed;
    }
  }

  /// Explicit stop (bar, stage, lifecycle): also ends a continuation that is
  /// preparing this item, so the walk does not skip on to the next one.
  Future<void> stop() async {
    final session = _current;
    session?.continuation?.end();
    if (session != null) await _stopSession(session);
  }

  Future<void> _stopSession(RoundDetachedPlayback session) async {
    if (identical(_current, session)) _current = null;
    await _disposeSession(session);
    _notify();
  }

  /// Never throws: callers are listeners, lifecycle hooks and unawaited.
  Future<void> _disposeSession(RoundDetachedPlayback session) async {
    if (session.disposed) return;
    session.disposed = true;
    session.request?.cancel();
    session.intent.pause();
    final video = session.video, audio = session.audio, media = session.media;
    // Detach before awaiting: no stage, row or listener may reach a
    // controller whose native player is going away.
    session.video = null;
    session.audio = null;
    session.media = null;
    if (video != null) RoundStageController.shared.release(video);
    video?.removeListener(_onProgress);
    _unbind(session);
    session.handle?.dispose();
    try {
      await video?.dispose();
    } catch (_) {
      /* The native player is released either way. */
    }
    try {
      await audio?.dispose();
    } catch (_) {
      /* As above. */
    }
    try {
      await media?.close();
    } catch (_) {
      /* Startup cleanup removes a lease left behind. */
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    // The shade or a system dialog (inactive) keeps a detached voice note
    // playing; a round stops at once (its played receipt is foreground-only).
    final session = _current;
    if (state == AppLifecycleState.inactive &&
        session != null &&
        !_isRound(session.event)) {
      return;
    }
    // A hidden Mac window keeps a detached voice note playing too (MAC-04).
    // The app lock decides through the coordinator: a configured lock stops
    // it, as on every other lock.
    if (state == AppLifecycleState.hidden &&
        session != null &&
        !_isRound(session.event) &&
        RoundPlaybackCoordinator.keepsVoiceWhenHidden) {
      return;
    }
    unawaited(stop());
  }

  @override
  void dispose() {
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(stop());
    super.dispose();
  }
}

/// Host in the unlocked app shell. Reopening navigates to this exact source.
class RoundMiniPlayer extends StatelessWidget {
  final ValueChanged<Event> onOpenSource;
  final RoundMiniPlayerController? controller;
  const RoundMiniPlayer({
    super.key,
    required this.onOpenSource,
    this.controller,
  });
  @override
  Widget build(BuildContext context) {
    final control = controller ?? RoundMiniPlayerController.shared;
    final stage = RoundStageController.shared;
    // The app shell hosts this above the Navigator (lib/widgets/matrix.dart),
    // outside every Overlay. A Slider keeps its value indicator in an
    // OverlayPortal and tooltips need one too: without this Overlay the bar
    // throws while building, also in release, which opened the global error
    // dialog on every progress tick once autoplay moved on.
    return Overlay.wrap(
      clipBehavior: Clip.none,
      alwaysSizeToContent: true,
      child: ListenableBuilder(
        listenable: Listenable.merge([control, stage]),
        // Grows in when playback detaches from its row and collapses
        // (keeping its last frame, without input) when it stops or is staged.
        builder: (context, _) =>
            ConversationReveal(child: _bar(context, control, stage)),
      ),
    );
  }

  Widget? _bar(
    BuildContext context,
    RoundMiniPlayerController control,
    RoundStageController stage,
  ) {
    final session = control.current;
    // The enlarged stage already shows this playback.
    if (session == null || stage.isStaged(session.video)) {
      return null;
    }
    final duration = session.duration;
    final maxMs = duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;
    return SafeArea(
      top: false,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        elevation: 4,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => onOpenSource(session.event),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            RoundVideoDescriptor.fromContent(
                                      session.event.content,
                                    ) !=
                                    null
                                ? 'Round video'
                                : session.loading
                                ? 'Loading message…'
                                : 'Voice message',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            '${RoundVideoView.formatTime(session.position)} / ${RoundVideoView.formatTime(duration)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    tooltip: session.playing ? 'Pause' : 'Play',
                    onPressed:
                        session.loading ||
                            (session.video == null && session.audio == null)
                        ? null
                        : control.toggle,
                    icon: NotionMorphSwitcher(
                      child: Icon(
                        session.playing ? Icons.pause : Icons.play_arrow,
                        key: ValueKey(session.playing),
                      ),
                    ),
                  ),
                  // No Navigator exists above the shell, so no popup menu:
                  // a tap cycles speeds like voice messages and the stage.
                  Tooltip(
                    message: 'Playback speed',
                    child: TextButton(
                      onPressed: session.loading
                          ? null
                          : () => control.setSpeed(
                              RoundVideoView.nextSpeed(session.speed),
                            ),
                      child: Text(RoundVideoView.speedLabel(session.speed)),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Stop playback',
                    onPressed: control.stop,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              if (session.loading)
                const LinearProgressIndicator()
              else
                Slider(
                  value: session.position.inMilliseconds.toDouble().clamp(
                    0.0,
                    maxMs,
                  ),
                  max: maxMs,
                  semanticFormatterCallback: (value) =>
                      RoundVideoView.formatTime(
                        Duration(milliseconds: value.round()),
                      ),
                  onChanged: (value) =>
                      control.seek(Duration(milliseconds: value.round())),
                ),
              if (session.locallyPlayed &&
                  TelegramRoundService.of(
                    session.event.room.client,
                  ).incognito &&
                  TelegramRoundService.of(
                    session.event.room.client,
                  ).canExplicitlyReport(session.event))
                TextButton(
                  onPressed: session.reporting ? null : control.reportPlayed,
                  child: const Text('Send playback receipt'),
                ),
              if (session.error != null)
                Text(
                  session.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

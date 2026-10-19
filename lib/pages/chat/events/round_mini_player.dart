// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/personal/round_video/round_media_loader.dart';
import 'package:fluffychat/personal/round_video/round_playback_coordinator.dart';
import 'package:fluffychat/personal/round_video/telegram_round_service.dart';
import 'package:fluffychat/ui/notion/notion.dart';
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
  bool loading = false, disposed = false;
  bool reporting = false;
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

/// Persists audible playback when a timeline row is recycled. Lifetime ends on
/// explicit stop, completion, lock/background, source invalidation or switch.
class RoundMiniPlayerController extends ChangeNotifier
    with WidgetsBindingObserver {
  static final shared = RoundMiniPlayerController();
  RoundDetachedPlayback? _current;
  final RoundMediaLoader _loader;
  final RoundPlaybackCoordinator _coordinator;
  bool _advancing = false;
  bool _closed = false;
  RoundMiniPlayerController({
    RoundMediaLoader? loader,
    RoundPlaybackCoordinator? coordinator,
  }) : _loader = loader ?? RoundMediaLoader(),
       _coordinator = coordinator ?? RoundPlaybackCoordinator.shared {
    WidgetsBinding.instance.addObserver(this);
  }
  RoundDetachedPlayback? get current => _current;

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
    unawaited(session.cancelSubscriptions());
    if (session.serviceListener != null) {
      session.boundService?.removeListener(session.serviceListener!);
      session.serviceListener = null;
      session.boundService = null;
    }
  }

  void _onProgress() {
    final session = _current;
    if (session == null) return;
    if (!_valid(session)) {
      unawaited(_stopSession(session));
      return;
    }
    if (session.video?.value.hasError == true) {
      unawaited(_fail(session));
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
        session.video?.value.isCompleted == true ||
        session.audio?.processingState == ProcessingState.completed ||
        session.duration > Duration.zero &&
            session.position >= session.duration;
    if (complete && !_advancing && session.handle?.isCurrent == true) {
      unawaited(advance());
    }
    _notify();
  }

  Future<void> toggle() async {
    final session = _current;
    if (session == null || session.loading || !_valid(session)) return;
    if (session.video == null && session.audio == null) return;
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
      try {
        await session.video?.play();
        unawaited(
          session.audio?.play().catchError((Object _) {
            unawaited(_fail(session));
          }),
        );
      } catch (_) {
        await _stopSession(session);
      }
    }
    _notify();
  }

  Future<void> _pause(RoundDetachedPlayback session) async {
    session.userInitiated = false;
    session.intent.pause();
    await session.video?.pause();
    await session.audio?.pause();
    _notify();
  }

  Future<void> seek(Duration position) async {
    final session = _current;
    if (session == null || !_valid(session)) return;
    session.intent.begin(
      position: position,
      userInitiated: session.userInitiated,
    );
    await session.video?.seekTo(position);
    await session.audio?.seek(position);
    _notify();
  }

  Future<void> setSpeed(double value) async {
    final session = _current;
    if (session == null || !_valid(session)) return;
    session.speed = value.clamp(.2, 3.0);
    await session.video?.setPlaybackSpeed(session.speed);
    await session.audio?.setSpeed(session.speed);
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
    _notify();
    try {
      await service.explicitlyReportPlayed(session.event);
    } catch (_) {
      session.error = 'Playback receipt was not sent.';
    } finally {
      session.reporting = false;
      _notify();
    }
  }

  Future<void> advance() async {
    if (_advancing) return;
    final previous = _current;
    if (previous == null) return;
    _advancing = true;
    try {
      final queue = List<Event>.from(previous.queue);
      final speed = previous.speed;
      await _stopSession(previous);
      if (_coordinator.suspended || !PersonalPrivacy.surfaceUnlocked) return;
      while (queue.isNotEmpty) {
        final event = queue.removeAt(0);
        final policy = RoundMediaPolicy.fromContent(event.content);
        if (event.redacted || !policy.canPersist) continue;
        final round = RoundVideoDescriptor.fromContent(event.content) != null;
        if (!round && event.messageType != MessageTypes.Audio) continue;
        final session = RoundDetachedPlayback(
          event: event,
          intent: RoundPlaybackIntent(),
          queue: List.unmodifiable(queue),
          speed: speed,
        )..loading = true;
        session.handle = _coordinator.register(
          pause: () => _stopSession(session),
          stop: () => _stopSession(session),
        );
        _current = session;
        _bind(session);
        _notify();
        try {
          // Reserve this continuation before any async preparation. A later
          // explicit player invalidates/cancels it instead of being stolen by
          // a slow queued download finishing afterwards.
          if (!await session.handle!.acquireAudible() || !_valid(session)) {
            await _stopSession(session);
            return;
          }
          final state = await TelegramRoundService.of(
            event.room.client,
          ).mediaState(event);
          if (state?['expired'] == true) {
            await _stopSession(session);
            continue;
          }
          if (!_valid(session)) {
            await _stopSession(session);
            return;
          }
          final request = session.request = RoundMediaCancellation(
            sourceValid: () => _valid(session) && session.handle!.isCurrent,
          );
          final media = round
              ? await _loader.load(event, cancellation: request)
              : await _loader.loadVoice(event, cancellation: request);
          if (!_valid(session)) {
            await media.close();
            await _stopSession(session);
            return;
          }
          session.media = media;
          if (round) {
            final video = session.video = media.lease != null
                ? VideoPlayerController.file(media.lease!.file)
                : VideoPlayerController.networkUrl(media.dataUri!);
            video.addListener(_onProgress);
            await video.initialize().timeout(const Duration(seconds: 20));
            await video.setPlaybackSpeed(session.speed);
          } else {
            final audio = session.audio = AudioPlayer();
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
            return;
          }
          session.loading = false;
          // Continuation is audible but receipt-silent. A later explicit tap
          // can create played intent; assembly/queue autoplay cannot.
          session.intent.begin(
            position: session.position,
            userInitiated: false,
          );
          await session.video?.play();
          unawaited(
            session.audio?.play().catchError((Object _) {
              unawaited(_stopSession(session));
            }),
          );
          _notify();
          return;
        } catch (_) {
          if (!session.disposed) await _fail(session);
          return;
        }
      }
    } finally {
      _advancing = false;
    }
  }

  Future<void> stop() async {
    final session = _current;
    if (session != null) await _stopSession(session);
  }

  Future<void> _fail(RoundDetachedPlayback session) async {
    if (session.disposed) return;
    session.request?.cancel();
    session.intent.pause();
    session.handle?.releaseAudible();
    final video = session.video, audio = session.audio, media = session.media;
    // Detach before awaiting: a row remounting meanwhile must not take
    // ([takeFor]) and render a controller whose native player is going away.
    session.video = null;
    session.audio = null;
    session.media = null;
    if (video != null) RoundStageController.shared.release(video);
    video?.removeListener(_onProgress);
    await session.cancelPlaybackSubscriptions();
    try {
      await video?.dispose();
      await audio?.dispose();
    } finally {
      await media?.close();
    }
    session.loading = false;
    session.error = 'Playback failed. Open the message and try again.';
    _notify();
  }

  Future<void> _stopSession(RoundDetachedPlayback session) async {
    if (identical(_current, session)) _current = null;
    await _disposeSession(session);
    _notify();
  }

  Future<void> _disposeSession(RoundDetachedPlayback session) async {
    if (session.disposed) return;
    session.disposed = true;
    session.request?.cancel();
    session.intent.pause();
    final video = session.video;
    if (video != null) RoundStageController.shared.release(video);
    _unbind(session);
    session.handle?.dispose();
    try {
      await session.video?.dispose();
      await session.audio?.dispose();
    } finally {
      await session.media?.close();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(stop());
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
    return ListenableBuilder(
      listenable: Listenable.merge([control, stage]),
      // Grows in when playback detaches from its row and collapses (keeping
      // its last frame, without input) when it stops or is staged.
      builder: (context, _) =>
          ConversationReveal(child: _bar(context, control, stage)),
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
                  PopupMenuButton<double>(
                    tooltip: 'Playback speed',
                    initialValue: session.speed,
                    onSelected: control.setSpeed,
                    itemBuilder: (_) => [
                      for (final speed in const [
                        .2,
                        .5,
                        1.0,
                        1.2,
                        1.5,
                        1.7,
                        2.0,
                        2.5,
                        3.0,
                      ])
                        PopupMenuItem(value: speed, child: Text('$speed×')),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          minWidth: 24,
                          minHeight: 24,
                        ),
                        child: Center(
                          widthFactor: 1,
                          heightFactor: 1,
                          child: Text('${session.speed}×'),
                        ),
                      ),
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

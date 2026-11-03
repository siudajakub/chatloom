// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:chatloom/personal/media_transcript.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:video_player/video_player.dart';

import 'round_video_view.dart';

/// Callbacks of whoever currently owns the staged controller: the timeline
/// row while it is mounted, otherwise the mini player.
class RoundStageActions {
  final Future<void> Function() toggle;
  final Future<void> Function(Duration position) seek;
  final Future<void> Function(double speed) setSpeed;

  /// Stops playback; the owner releases the stage before disposing.
  final Future<void> Function() stop;
  final Future<void> Function()? save, forward, reportPlayed, next;
  final bool Function()? canReportPlayed;

  /// Global rect of the inline circle, or null when the row is gone.
  final Rect? Function()? sourceRect;

  /// Poster shown until the first frame is ready (never a bare surface).
  final Uint8List? Function()? thumbnail;

  /// The message playing, for its live transcript (null: none).
  final Event? event;

  const RoundStageActions({
    required this.toggle,
    required this.seek,
    required this.setSpeed,
    required this.stop,
    this.save,
    this.forward,
    this.reportPlayed,
    this.next,
    this.canReportPlayed,
    this.sourceRect,
    this.thumbnail,
    this.event,
  });
}

/// Single enlarged round over a dimmed backdrop. It never owns or disposes the
/// [VideoPlayerController]: shrinking only pops the route, so playback
/// continues inline with the same controller. Owners call [release] before
/// they dispose a controller.
class RoundStageController extends ChangeNotifier {
  static final shared = RoundStageController();

  VideoPlayerController? _video;
  RoundStageActions? _actions;
  RoundStageRoute? _route;
  Object? _contentOwner;
  WidgetBuilder? _content;
  bool _waiting = false;

  VideoPlayerController? get video => _video;
  RoundStageActions? get actions => _actions;
  bool get isOpen => _route != null && !_route!._removing;

  bool isPresenting(Object? owner) =>
      owner != null &&
      (identical(owner, _video) || identical(owner, _contentOwner));

  bool isStaged(VideoPlayerController? video) =>
      video != null && identical(video, _video);

  void _notify() {
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => notifyListeners());
      SchedulerBinding.instance.scheduleFrame();
    } else {
      notifyListeners();
    }
  }

  /// Enlarges [video]. Re-presenting the staged controller only rebinds.
  bool present(
    BuildContext context, {
    required VideoPlayerController video,
    required RoundStageActions actions,
  }) {
    final existing = _route;
    if (existing != null && existing.isActive && !existing._removing) {
      _replace(video, actions);
      return true;
    }
    if (identical(video, _video)) {
      final current = _route;
      if (current != null && current.isActive && !current._removing) {
        rebind(video, actions);
        return true;
      }
      // Play again during the shrink flight: that route is already leaving,
      // so a rebind alone would leave the row blank (staged) with no stage.
      _video = null;
      _actions = null;
      _route = null;
    }
    final previous = _video;
    if (previous != null) release(previous);
    final navigator = Navigator.maybeOf(context, rootNavigator: true);
    if (navigator == null) return false;
    final route = RoundStageRoute._(
      stage: this,
      reducedMotion: NotionMotion.reduced(context),
    );
    _video = video;
    _actions = actions;
    _contentOwner = null;
    _content = null;
    _waiting = false;
    _route = route;
    unawaited(navigator.push(route));
    _notify();
    return true;
  }

  void _replace(VideoPlayerController video, RoundStageActions actions) {
    _video = video;
    _actions = actions;
    _content = null;
    _contentOwner = null;
    _waiting = false;
    _notify();
  }

  /// The queue replaces media inside the existing route. A user who closed
  /// it while the next download ran must never have it opened again.
  bool presentContinuation({
    required VideoPlayerController video,
    required RoundStageActions actions,
  }) {
    if (!isOpen) return false;
    _replace(video, actions);
    return true;
  }

  /// Detach before disposing a finished decoder, retaining the route while
  /// the queue prepares its next round or voice note.
  void holdForContinuation(Object owner) {
    if (!isPresenting(owner)) return;
    _video = null;
    _actions = null;
    _contentOwner = null;
    _content = null;
    _waiting = true;
    _notify();
  }

  bool presentContent({required Object owner, required WidgetBuilder builder}) {
    if (!isOpen) return false;
    _video = null;
    _actions = null;
    _contentOwner = owner;
    _content = builder;
    _waiting = false;
    _notify();
    return true;
  }

  void releaseContent(Object owner) {
    if (!identical(owner, _contentOwner)) return;
    final route = _route;
    _clear();
    route?._remove();
  }

  void finishContinuation() {
    if (!_waiting) return;
    _waiting = false;
    _notify();
  }

  /// Ownership moved (row ↔ mini player); the controller stays the same.
  void rebind(VideoPlayerController video, RoundStageActions actions) {
    if (!identical(video, _video)) return;
    _actions = actions;
    _notify();
  }

  /// Detaches the stage from [video] without animation. Must run before the
  /// owner disposes [video]; no stage widget uses it afterwards.
  void release(VideoPlayerController video) {
    if (!identical(video, _video)) return;
    final route = _route;
    _clear();
    route?._remove();
  }

  /// Shrinks back into the row with the reverse flight; playback continues.
  void shrink() => _route?._shrink();

  void _routeGone(RoundStageRoute route) {
    if (identical(route, _route)) _clear();
  }

  void _clear() {
    _video = null;
    _actions = null;
    _route = null;
    _contentOwner = null;
    _content = null;
    _waiting = false;
    _notify();
  }
}

class RoundStageRoute extends PopupRoute<void> {
  final RoundStageController stage;
  final bool reducedMotion;
  bool _removing = false;

  RoundStageRoute._({required this.stage, required this.reducedMotion});

  @override
  Color? get barrierColor => NotionMediaColors.viewer.withValues(alpha: 1);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Shrink round video';

  @override
  Duration get transitionDuration =>
      reducedMotion ? Duration.zero : NotionMotion.medium;

  @override
  Duration get reverseTransitionDuration =>
      reducedMotion ? Duration.zero : NotionMotion.reverse;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => ListenableBuilder(
    listenable: stage,
    builder: (context, _) {
      final video = stage.video;
      if (!identical(stage._route, this)) return const SizedBox.shrink();
      if (video != null) {
        return RoundVideoStage(
          key: ObjectKey(video),
          controller: stage,
          video: video,
          animation: animation,
          route: this,
        );
      }
      final content = stage._content;
      if (content != null) return content(context);
      return Material(
        type: MaterialType.transparency,
        child: SafeArea(
          child: Stack(
            children: [
              Align(
                alignment: AlignmentDirectional.topEnd,
                child: Padding(
                  padding: const EdgeInsets.all(NotionSpace.md),
                  child: IconButton(
                    tooltip: 'Close media player',
                    color: NotionMediaColors.onScrim,
                    onPressed: stage.shrink,
                    icon: const Icon(Icons.close),
                  ),
                ),
              ),
              Center(
                child: stage._waiting
                    ? const NotionDelayedSpinner(
                        key: ValueKey('round-stage-continuing'),
                        color: NotionMediaColors.onScrim,
                      )
                    : Text(
                        'Playback finished',
                        style: NotionType.callout.copyWith(
                          color: NotionMediaColors.onScrim,
                        ),
                      ),
              ),
            ],
          ),
        ),
      );
    },
  );

  void _shrink() {
    final navigator = this.navigator;
    if (navigator == null || !isActive || _removing) return;
    if (isCurrent) {
      _removing = true;
      navigator.pop();
    } else {
      _remove();
    }
  }

  void _remove() {
    if (_removing) return;
    _removing = true;
    void remove() {
      final navigator = this.navigator;
      if (navigator != null && navigator.mounted && isActive) {
        navigator.removeRoute(this);
      }
    }

    // Owners release while their State is being disposed (tree locked).
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => remove());
      SchedulerBinding.instance.scheduleFrame();
    } else {
      remove();
    }
  }

  @override
  void dispose() {
    stage._routeGone(this);
    super.dispose();
  }
}

/// Enlarged circle, flown from the row's circle and back.
class RoundVideoStage extends StatefulWidget {
  final RoundStageController controller;
  final VideoPlayerController video;
  final Animation<double> animation;

  /// Route showing this stage; a leaving route stops rendering the
  /// controller once a newer stage owns it.
  final RoundStageRoute? route;

  const RoundVideoStage({
    super.key,
    required this.controller,
    required this.video,
    required this.animation,
    this.route,
  });

  static const double maxDiameter = 420;

  /// Play / loading / error mark in the middle of the enlarged circle.
  static const double _glyphSize = 40;

  @override
  State<RoundVideoStage> createState() => _RoundVideoStageState();
}

class _RoundVideoStageState extends State<RoundVideoStage> {
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: widget.animation,
    curve: NotionMotion.emphasized,
    reverseCurve: NotionMotion.exitFast,
  );

  /// The controller's position for the live transcript.
  late final _position = MediaPositionListenable(
    widget.video,
    () => widget.video.value.position,
  );

  @override
  void dispose() {
    _curve.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final actions = widget.controller.actions;
      final route = widget.route;
      // Released: the owner is about to dispose the controller.
      if (!widget.controller.isStaged(widget.video) ||
          actions == null ||
          (route != null && !identical(widget.controller._route, route))) {
        return const SizedBox.shrink();
      }
      return MediaTranscriptBuilder(
        event: actions.event,
        builder: (context, transcript) => ValueListenableBuilder<bool>(
          valueListenable: MediaTranscriptPreference.visible,
          builder: (context, visible, _) =>
              _stage(context, actions, transcript, visible ? transcript : null),
        ),
      );
    },
  );

  /// The circle with its controls under it; with a [shown] transcript the
  /// circle gets smaller at the top, the transcript follows playback in the
  /// middle and the controls sit at the bottom (Apple Music lyrics). Circle
  /// and controls glide between the two layouts ([NotionLayoutFlip]).
  Widget _stage(
    BuildContext context,
    RoundStageActions actions,
    MediaTranscript? transcript,
    MediaTranscript? shown,
  ) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    const controlsHeight = NotionSize.touchTarget * 2 + NotionSpace.md;
    final showing = shown != null;
    final sideBySide =
        showing &&
        size.width >= NotionSize.contentMaxWidth &&
        size.width > size.height;
    final available =
        size.height - padding.vertical - 2 * NotionSpace.md - controlsHeight;
    final diameter = math
        .min(
          math.min(
            (sideBySide ? size.width / 2 : size.width) - 2 * NotionSpace.inset,
            // The transcript takes the larger part of the height.
            showing && !sideBySide ? available * .42 : available,
          ),
          RoundVideoStage.maxDiameter,
        )
        .clamp(NotionSize.touchTarget, RoundVideoStage.maxDiameter);
    final top = showing && !sideBySide
        ? padding.top + NotionSpace.md
        : math.max(
            padding.top + NotionSpace.md,
            (size.height - diameter - controlsHeight) / 2,
          );
    final target = Rect.fromLTWH(
      ((sideBySide ? size.width / 2 : size.width) - diameter) / 2,
      top,
      diameter,
      diameter,
    );
    Widget constrained(Widget child) => Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: RoundVideoStage.maxDiameter,
        ),
        child: child,
      ),
    );
    final event = actions.event;
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            key: const ValueKey('round-stage-backdrop'),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTap: widget.controller.shrink,
              onVerticalDragEnd: _dragEnd,
            ),
          ),
          AnimatedBuilder(
            key: const ValueKey('round-stage-circle'),
            animation: _curve,
            builder: (context, child) {
              final source = _sourceRect(actions);
              final from =
                  source ??
                  Rect.fromCenter(
                    center: target.center,
                    width: diameter * .8,
                    height: diameter * .8,
                  );
              final t = _curve.value;
              return Positioned.fromRect(
                rect: Rect.lerp(from, target, t)!,
                child: source == null
                    ? Opacity(opacity: t.clamp(0.0, 1.0), child: child)
                    : child!,
              );
            },
            child: NotionLayoutFlip(trigger: showing, child: _circle(actions)),
          ),
          if (shown != null)
            Positioned(
              key: const ValueKey('round-stage-transcript'),
              left: sideBySide
                  ? size.width / 2 + NotionSpace.xs
                  : NotionSpace.inset,
              right: NotionSpace.inset,
              top: sideBySide
                  ? padding.top + NotionSpace.md
                  : target.bottom + NotionSpace.md,
              bottom: padding.bottom + NotionSpace.md + controlsHeight,
              child: FadeTransition(
                opacity: _curve,
                child: constrained(
                  MediaSyncedTranscript(
                    transcript: shown,
                    position: _position,
                    duration: _ready(widget.video.value)
                        ? widget.video.value.duration
                        : null,
                    declaredDuration: event == null
                        ? null
                        : declaredMediaDuration(event),
                    onSeek: (position) => unawaited(
                      actions.seek(position).catchError((Object _) {}),
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            key: const ValueKey('round-stage-controls'),
            left: NotionSpace.inset,
            right: NotionSpace.inset,
            top: showing ? null : target.bottom + NotionSpace.md,
            bottom: showing ? padding.bottom + NotionSpace.md : null,
            child: FadeTransition(
              opacity: _curve,
              child: NotionLayoutFlip(
                trigger: showing,
                child: constrained(
                  _controls(actions, transcript: transcript != null),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The owner's circle, or null. Never throws into this build: an
  /// exception here would replace the whole stage with an ErrorWidget (a
  /// full-screen grey box in release builds).
  Rect? _sourceRect(RoundStageActions actions) {
    try {
      final rect = actions.sourceRect?.call();
      return rect != null && rect.isFinite && !rect.isEmpty ? rect : null;
    } catch (_) {
      return null;
    }
  }

  void _dragEnd(DragEndDetails details) {
    if ((details.primaryVelocity ?? 0) > NotionDismissDrag.defaultVelocity) {
      widget.controller.shrink();
    }
  }

  Widget _circle(RoundStageActions actions) {
    final colors = context.notion.colors;
    Uint8List? poster;
    try {
      poster = actions.thumbnail?.call();
    } catch (_) {
      poster = null;
    }
    final surface = RepaintBoundary(
      child: ClipOval(
        child: ColoredBox(
          color: colors.surface,
          child: ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: widget.video,
            // Built only for a ready controller: an erroneous or not yet
            // initialized player has no native view to embed.
            builder: (context, value, player) => Stack(
              fit: StackFit.expand,
              children: [
                if (poster != null)
                  Image.memory(
                    poster,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    excludeFromSemantics: true,
                    errorBuilder: (_, _, _) => const SizedBox.expand(),
                  ),
                if (_ready(value))
                  FittedBox(
                    fit: BoxFit.cover,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: value.size.width > 0 ? value.size.width : 1,
                      height: value.size.height > 0 ? value.size.height : 1,
                      child: player,
                    ),
                  ),
              ],
            ),
            child: VideoPlayer(widget.video),
          ),
        ),
      ),
    );
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: widget.video,
      child: surface,
      builder: (context, value, surface) {
        final total = value.duration.inMilliseconds;
        final progress = total > 0
            ? value.position.inMilliseconds / total
            : 0.0;
        final failed = value.hasError;
        final loading =
            !failed &&
            (!value.isInitialized || value.isBuffering && value.isPlaying);
        return Semantics(
          container: true,
          button: true,
          label: 'Round video, enlarged',
          value: failed
              ? 'Playback failed'
              : loading
              ? 'Loading'
              : '${RoundVideoView.formatTime(value.position)} of '
                    '${RoundVideoView.formatTime(value.duration)}',
          onTap: failed ? widget.controller.shrink : actions.toggle,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTap: failed ? widget.controller.shrink : actions.toggle,
            onVerticalDragEnd: _dragEnd,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(child: surface!),
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: RoundProgressPainter(
                        progress: progress,
                        color: roundVideoOnScrim,
                        track: roundVideoScrim,
                        strokeWidth: 4,
                      ),
                    ),
                  ),
                ),
                if (failed || loading || !value.isPlaying)
                  IgnorePointer(
                    child: DecoratedBox(
                      decoration: const ShapeDecoration(
                        shape: CircleBorder(),
                        color: roundVideoScrim,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(NotionSpace.sm),
                        child: SizedBox.square(
                          dimension: RoundVideoStage._glyphSize,
                          child: failed
                              ? const Icon(
                                  Icons.error_outline,
                                  key: ValueKey('round-stage-error'),
                                  color: roundVideoOnScrim,
                                  size: RoundVideoStage._glyphSize,
                                )
                              : loading
                              ? const NotionDelayedSpinner(
                                  key: ValueKey('round-stage-loading'),
                                  size: RoundVideoStage._glyphSize,
                                  delay: Duration.zero,
                                  color: roundVideoOnScrim,
                                )
                              : const Icon(
                                  Icons.play_arrow,
                                  color: roundVideoOnScrim,
                                  size: RoundVideoStage._glyphSize,
                                ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  static bool _canReport(RoundStageActions actions) {
    try {
      return actions.canReportPlayed?.call() ?? false;
    } catch (_) {
      return false;
    }
  }

  static bool _ready(VideoPlayerValue value) =>
      value.isInitialized && !value.hasError;

  Widget _controls(RoundStageActions actions, {required bool transcript}) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: widget.video,
      builder: (context, value, _) => NotionMediaPlaybackControls(
        playing: value.isPlaying,
        position: value.position,
        duration: value.duration,
        speed: value.playbackSpeed,
        playLabel: 'Play round video',
        pauseLabel: 'Pause round video',
        onToggle: _ready(value) ? actions.toggle : null,
        onSeek: _ready(value) ? actions.seek : null,
        onSpeedCycle: !_ready(value)
            ? null
            : () => actions.setSpeed(
                RoundVideoView.nextSpeed(value.playbackSpeed),
              ),
        onSpeedPicker: !_ready(value)
            ? null
            : () => showRoundSpeedPicker(
                context,
                speed: value.playbackSpeed,
                onChanged: actions.setSpeed,
              ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (transcript) const MediaTranscriptToggle(),
            NotionMediaActionsButton(
              actions: [
                if (actions.next != null)
                  NotionMediaAction(
                    label: 'Next message',
                    icon: Icons.skip_next,
                    onPressed: actions.next,
                  ),
                if (actions.save != null)
                  NotionMediaAction(
                    label: 'Save round video',
                    icon: Icons.download_outlined,
                    onPressed: actions.save,
                  ),
                if (actions.forward != null)
                  NotionMediaAction(
                    label: 'Forward in Telegram',
                    icon: Icons.forward_outlined,
                    onPressed: actions.forward,
                  ),
                if (actions.reportPlayed != null && _canReport(actions))
                  NotionMediaAction(
                    label: 'Send playback receipt',
                    icon: Icons.done_all,
                    onPressed: actions.reportPlayed,
                  ),
                NotionMediaAction(
                  label: 'Stop playback',
                  icon: Icons.stop,
                  onPressed: actions.stop,
                ),
              ],
            ),
            IconButton(
              tooltip: 'Shrink round video',
              color: roundVideoOnScrim,
              onPressed: widget.controller.shrink,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }
}

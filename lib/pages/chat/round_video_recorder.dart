// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import '../../personal/media/media_access.dart';
import '../../personal/round_video/round_capture_backend.dart';
import '../../personal/round_video/round_capture_controller.dart';
import '../../personal/round_video/round_media_preparer.dart';
import 'notion_conversation.dart' show NotionSendButton, notionAudioTime;
import 'voice_record_button.dart' show RecordingDot, VoiceRecordLayout;

/// The caller freezes and positively authorizes account/room/reply before this
/// function. Returned media still owns a plaintext codec lease: stage it in the
/// encrypted durable store and close it after the write has committed.
Future<PreparedRoundMedia?> showRoundVideoRecorder(
  BuildContext context, {
  required MediaAccess mediaAccess,
  required RoundCaptureProfile profile,
  String? targetLabel,
  RoundCaptureGestureController? gesture,
}) {
  if (gesture != null &&
      gesture.phase != RoundCaptureGesturePhase.holding &&
      gesture.phase != RoundCaptureGesturePhase.locked) {
    return Future<PreparedRoundMedia?>.value();
  }
  return Navigator.of(context, rootNavigator: true).push(
    RoundRecorderRoute(
      builder: (_) => RoundVideoRecorder(
        mediaAccess: mediaAccess,
        profile: profile,
        targetLabel: targetLabel,
        gesture: gesture,
      ),
    ),
  );
}

/// Modal over the chat, like Telegram's InstantCameraView: the conversation
/// stays visible but dimmed and blurred behind the camera circle
/// ([RoundRecorderBackdrop]), and the pointer that opened it keeps driving the
/// composer button underneath. The recorder animates its own open/close (and
/// the backdrop's fade) from [animation].
class RoundRecorderRoute extends PopupRoute<PreparedRoundMedia> {
  final WidgetBuilder builder;
  RoundRecorderRoute({required this.builder});

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => null;

  @override
  Duration get transitionDuration => NotionMotion.short;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => builder(context);
}

/// Geometry from Telegram Android (InstantCameraView / AndroidUtilities).
abstract final class RoundRecorderLayout {
  /// The ring is drawn this far outside the circle.
  static const double ringGap = NotionSpace.xs;
  static const double ringWidth = 3;

  /// Composer row height (= ChatInputRow.height).
  static const double panelHeight = 56;

  /// Shortest trim span in review.
  static const int minTrimMs = 1000;

  /// Camera flip: two quarter turns around the vertical axis. The lens switch
  /// starts with the turn (not at its half-way point), so the new camera is
  /// usually live when the turn ends; Telegram turns for 580 ms.
  static final Duration flip = NotionMotion.short * 2;

  /// min(screen) − 28 dp on a tall screen, otherwise 0.6 × min(screen).
  static double circleSize(Size screen) {
    final short = math.min(screen.width, screen.height);
    return screen.height > screen.width * 1.3
        ? short - (NotionSpace.xl + NotionSpace.xxs)
        : short * 0.6;
  }
}

class RoundVideoRecorder extends StatefulWidget {
  final MediaAccess mediaAccess;
  final RoundCaptureProfile profile;
  final String? targetLabel;
  final RoundCaptureGestureController? gesture;
  const RoundVideoRecorder({
    required this.mediaAccess,
    required this.profile,
    this.targetLabel,
    this.gesture,
    super.key,
  });

  @override
  State<RoundVideoRecorder> createState() => _RoundVideoRecorderState();
}

class _RoundVideoRecorderState extends State<RoundVideoRecorder>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  late RoundCaptureController _controller;
  VideoPlayerController? _player;
  Future<void> _playerDisposal = Future<void>.value();
  PreparedRoundMedia? _playerMedia;
  RangeValues? _trimRange;
  bool _scrubbing = false;
  bool _previewMuted = true;
  bool _screenFlash = false;
  bool _closing = false;
  bool _externalStarted = false;
  bool _externalFinishing = false;
  bool _externalDetached = false;
  RoundCaptureState? _lastState;
  double? _zoomDraft;
  int? _zoomDraftRevision;
  double? _pinchStartZoom;
  int? _pinchRevision;
  double _zoomBackFrom = 1;
  double _zoomBackTo = 1;

  late final AnimationController _flip = AnimationController(
    vsync: this,
    duration: RoundRecorderLayout.flip,
  )..addStatusListener(_flipStatus);

  /// Zoom springs back to none when the pinch ends (Telegram: 350 ms).
  late final AnimationController _zoomBack = AnimationController(
    vsync: this,
    duration: NotionMotion.long,
  )..addListener(_zoomBackTick);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.gesture?.addListener(_gestureChanged);
    _setup();
  }

  void _setup() {
    _controller = RoundCaptureController(
      backend: AndroidRoundCaptureBackend(widget.mediaAccess),
      profile: widget.profile,
    )..addListener(_changed);
    _lastState = _controller.state;
    unawaited(_controller.initialize());
    _externalGestureChanged();
  }

  void _changed() {
    if (!mounted || _closing) return;
    final state = _controller.state;
    if (state == RoundCaptureState.recording &&
        _lastState != RoundCaptureState.recording) {
      // Telegram ticks when the camera actually records, and on resume.
      NotionHaptics.longPress();
    }
    _lastState = state;
    _externalGestureChanged();
    if (_controller.state == RoundCaptureState.review &&
        _controller.prepared != _playerMedia) {
      unawaited(_loadReview(_controller.prepared!));
    }
    setState(() {});
  }

  /// The composer pointer moved, locked, released or cancelled.
  void _gestureChanged() {
    _externalGestureChanged();
    if (mounted && !_closing) setState(() {});
  }

  bool get _holding =>
      !_externalDetached &&
      widget.gesture?.phase == RoundCaptureGesturePhase.holding;

  void _externalGestureChanged() {
    final gesture = widget.gesture;
    if (gesture == null || _closing || _externalDetached) return;
    final phase = gesture.phase;
    if (phase == RoundCaptureGesturePhase.canceled) {
      unawaited(_discard());
      return;
    }
    if (phase == RoundCaptureGesturePhase.released) {
      if (_externalFinishing) return;
      if (_controller.state == RoundCaptureState.recording &&
          !_controller.locked &&
          !_controller.wasInterrupted) {
        // Telegram: releasing without lock sends at once, no preview.
        _externalFinishing = true;
        unawaited(_finishAndSend());
      } else if (_controller.state == RoundCaptureState.initializing ||
          _controller.state == RoundCaptureState.ready ||
          (_controller.state == RoundCaptureState.preparing &&
              _controller.prepared == null &&
              !_controller.isFinalizing &&
              !_controller.wasInterrupted)) {
        // Releasing during initial permission/camera/start never begins or
        // resurrects a recording later when asynchronous setup completes.
        unawaited(_discard());
      }
      return;
    }
    if (phase == RoundCaptureGesturePhase.locked) _controller.lock();
    if (!_externalStarted &&
        _controller.state == RoundCaptureState.ready &&
        !_controller.controlsBusy &&
        (phase == RoundCaptureGesturePhase.holding ||
            phase == RoundCaptureGesturePhase.locked)) {
      _externalStarted = true;
      unawaited(
        _controller.start(lock: phase == RoundCaptureGesturePhase.locked),
      );
    }
  }

  /// Release, send arrow while locked, or send from pause. Shorter than
  /// [RoundCaptureController.minimumDurationMs] is discarded silently; a
  /// limit or interruption during finishing always opens review instead.
  Future<void> _finishAndSend() async {
    final controller = _controller;
    if (controller.duration.inMilliseconds <
        RoundCaptureController.minimumDurationMs) {
      await _discard();
      return;
    }
    await controller.finish();
    if (mounted &&
        !_closing &&
        identical(controller, _controller) &&
        !controller.wasInterrupted) {
      await _accept();
    }
  }

  Future<void> _loadReview(PreparedRoundMedia media) async {
    _playerMedia = media;
    _trimRange = RangeValues(0, media.durationMs.toDouble());
    await _disposeReviewPlayer();
    if (!mounted || _closing || _playerMedia != media) return;
    final player = VideoPlayerController.file(
      File(media.path),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    );
    _player = player;
    try {
      await player.initialize();
      if (!mounted || _closing || _player != player) return;
      player.addListener(_loopPreview);
      // Telegram: the preview loops muted; a tap on the circle unmutes.
      await player.setVolume(_previewMuted ? 0 : 1);
      await player.play();
      if (mounted && !_closing) setState(() {});
    } catch (_) {
      // Keep the validated draft available even if native preview fails.
      if (mounted && !_closing) setState(() {});
    }
  }

  /// Loops the preview between the trim handles.
  void _loopPreview() {
    final player = _player;
    final range = _trimRange;
    if (player == null || range == null || _scrubbing || _closing) return;
    final value = player.value;
    final position = value.position.inMilliseconds;
    if (value.isCompleted || (value.isPlaying && position >= range.end)) {
      unawaited(
        player.seekTo(Duration(milliseconds: range.start.round())).then((_) {
          if (!_closing && identical(_player, player)) return player.play();
        }),
      );
    }
  }

  /// Join every previous player cleanup too: a late review initialization or
  /// replacement must not keep a codec open after this route returns its lease.
  Future<void> _disposeReviewPlayer() {
    final player = _player;
    _player = null;
    player?.removeListener(_loopPreview);
    _playerDisposal = Future.wait<void>([
      _playerDisposal,
      if (player != null) player.dispose(),
    ]).then<void>((_) {});
    return _playerDisposal;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_player?.pause());
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_controller.interrupt());
    }
  }

  void _setZoom(double value) {
    final preview = _controller.preview;
    if (preview == null || !_controller.canZoom) return;
    final zoom = value.clamp(preview.minZoom, preview.maxZoom);
    setState(() {
      _zoomDraft = zoom;
      _zoomDraftRevision = preview.cameraRevision;
    });
    unawaited(
      _controller.setZoom(zoom).then((_) {
        if (!mounted ||
            _closing ||
            _zoomDraft != zoom ||
            _zoomDraftRevision != preview.cameraRevision) {
          return;
        }
        setState(() => _zoomDraft = null);
      }),
    );
  }

  double get _zoom {
    final preview = _controller.preview;
    if (preview == null) return 1;
    return (_zoomDraftRevision == preview.cameraRevision ? _zoomDraft : null) ??
        preview.zoom;
  }

  void _springZoomBack() {
    _pinchStartZoom = null;
    final preview = _controller.preview;
    if (preview == null || !_controller.canZoom) return;
    final from = _zoom;
    final to = preview.minZoom;
    if ((from - to).abs() < 0.01) return;
    if (NotionMotion.reduced(context)) {
      _setZoom(to);
      return;
    }
    _zoomBackFrom = from;
    _zoomBackTo = to;
    _zoomBack.forward(from: 0);
  }

  void _zoomBackTick() {
    if (!mounted || _closing || _pinchStartZoom != null) return;
    final t = NotionMotion.standard.transform(_zoomBack.value);
    _setZoom(lerpDouble(_zoomBackFrom, _zoomBackTo, t)!);
  }

  /// Telegram flips the circle around its vertical axis. The native lens
  /// switch starts at once, overlapping the turn instead of waiting for its
  /// half-way point; a lens that is still opening when the turn ends shows
  /// its last frame under a scrim until the first new frame arrives.
  void _switchCamera() {
    if (!_controller.canSwitchCamera || _flip.isAnimating) return;
    unawaited(_controller.switchCamera());
    if (!NotionMotion.reduced(context)) _flip.forward(from: 0);
  }

  void _flipStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted && !_closing) {
      setState(() {});
    }
  }

  /// The turn is over but the new lens has not delivered a frame yet.
  bool get _awaitingLens => _controller.switchingCamera && !_flip.isAnimating;

  Future<void> _discard() async {
    if (_closing) return;
    _closing = true;
    try {
      await _disposeReviewPlayer();
    } finally {
      try {
        await _controller.cancel();
      } finally {
        await _controller.backend.dispose();
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _accept() async {
    if (_closing || _controller.state != RoundCaptureState.review) return;
    _closing = true;
    final prepared = _controller.takePrepared();
    try {
      await _disposeReviewPlayer();
    } finally {
      await _controller.backend.dispose(keepPrepared: true);
    }
    if (mounted) {
      Navigator.of(context).pop(prepared);
    } else {
      await prepared.close();
    }
  }

  /// Review send: a trimmed span is re-encoded first (Telegram re-encodes
  /// trimmed rounds too); a failed trim keeps the original for review.
  Future<void> _sendReview() async {
    final prepared = _controller.prepared;
    final range = _trimRange;
    if (_closing ||
        _controller.state != RoundCaptureState.review ||
        prepared == null) {
      return;
    }
    if (range != null &&
        (range.start > 0 || range.end < prepared.durationMs.toDouble())) {
      await _disposeReviewPlayer();
      _playerMedia = null;
      await _controller.trim(range.start.round(), range.end.round());
      if (!mounted ||
          _closing ||
          _controller.state != RoundCaptureState.review ||
          _controller.controlErrorCode != null) {
        return;
      }
    }
    await _accept();
  }

  Future<void> _recordAgain() async {
    if (_closing) return;
    _closing = true;
    _playerMedia = null;
    _externalStarted = true; // Re-recording uses the visible controls.
    _externalDetached = true;
    try {
      await _disposeReviewPlayer();
    } finally {
      try {
        await _controller.cancel();
      } finally {
        await _controller.backend.dispose();
      }
    }
    // Removed meanwhile: dispose() already released this controller.
    if (!mounted) return;
    _controller.removeListener(_changed);
    _controller.dispose();
    _zoomDraft = null;
    _pinchStartZoom = null;
    _screenFlash = false;
    _closing = false;
    _setup();
    setState(() {});
  }

  /// Telegram discards a recording paused before the minimum length.
  void _pause() {
    if (!_controller.canPause) return;
    if (_controller.duration.inMilliseconds <
        RoundCaptureController.minimumDurationMs) {
      unawaited(_discard());
      return;
    }
    unawaited(_controller.pause());
  }

  void _toggleMute() {
    setState(() => _previewMuted = !_previewMuted);
    unawaited(_player?.setVolume(_previewMuted ? 0 : 1));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.gesture?.removeListener(_gestureChanged);
    _flip.dispose();
    _zoomBack.dispose();
    _controller.removeListener(_changed);
    _controller.dispose();
    unawaited(_disposeReviewPlayer());
    super.dispose();
  }

  String get _status => switch (_controller.state) {
    RoundCaptureState.initializing => 'Opening camera…',
    RoundCaptureState.ready =>
      _controller.controlsBusy
          ? 'Updating camera controls…'
          : 'Tap the camera button to record',
    RoundCaptureState.recording =>
      _controller.locked
          ? 'Recording locked'
          : 'Recording. Release to send, slide to cancel, slide up to lock.',
    RoundCaptureState.paused => 'Recording paused',
    RoundCaptureState.preparing =>
      _controller.isFinalizing ? 'Preparing round video…' : 'Starting camera…',
    RoundCaptureState.review =>
      _controller.stoppedAtLimit
          ? 'Time limit reached. Review before sending'
          : 'Review before sending',
    RoundCaptureState.canceled => 'Recording cancelled',
    RoundCaptureState.failed => switch (_controller.errorCode) {
      'permission_denied' => 'Camera and microphone access is required.',
      'unsupported_android' || 'unsupported_platform' =>
        'Round video recording requires Android 7 or later.',
      'recording_too_short' => 'The recording is too short. Record again.',
      'interrupted' => 'Recording was interrupted. Record again.',
      _ => 'The recording could not be prepared. Record again.',
    },
  };

  String? get _controlError => switch (_controller.controlErrorCode) {
    null => null,
    'trim_failed' =>
      'Could not trim the recording. The original is still available.',
    'camera_switch_failed' =>
      'Could not switch cameras. Your recording is still available.',
    'torch_unavailable' => 'Light is unavailable on this camera.',
    'zoom_unavailable' => 'Zoom is unavailable on this camera.',
    'permission_denied' =>
      'Camera access changed. Finish or cancel this recording.',
    'stale_camera' || 'busy' => 'The camera changed. Try the control again.',
    _ => 'Could not change the camera control. Try again.',
  };

  /// Opening (and, on pop, closing) animation: Telegram scales the circle
  /// from 0.1, fades it in and lifts it from half the screen height.
  double _openProgress(BuildContext context) {
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || NotionMotion.reduced(context)) return 1;
    return NotionMotion.emphasized.transform(animation.value);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    final route = ModalRoute.of(context)?.animation;
    final anchor = widget.gesture?.anchor;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    // The record circle sits where the composer button (and the finger) is.
    final action = Offset(
      anchor?.center.dx ??
          (rtl
              ? NotionSpace.xs + NotionSize.touchTarget / 2
              : screen.width - NotionSpace.xs - NotionSize.touchTarget / 2),
      anchor?.center.dy ??
          screen.height -
              media.padding.bottom -
              RoundRecorderLayout.panelHeight / 2,
    );
    final panelTop = math.min(
      action.dy - RoundRecorderLayout.panelHeight / 2,
      screen.height - media.padding.bottom - RoundRecorderLayout.panelHeight,
    );
    final flashOn =
        _screenFlash &&
        _controller.frontCamera &&
        _controller.preview?.torchAvailable != true &&
        _controller.state == RoundCaptureState.recording;
    final body = Stack(
      children: [
        // Dim everything behind the recorder; the flat dim fades with the
        // route and is blurred only once the route has settled.
        Positioned.fill(
          child: _fade(context, route, const RoundRecorderBackdrop()),
        ),
        // Front camera "flash": the screen lights the face while recording.
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: flashOn ? 1 : 0,
              duration: NotionMotion.of(
                context,
                flashOn ? NotionMotion.long : NotionMotion.medium,
              ),
              curve: NotionMotion.standard,
              child: const ColoredBox(color: NotionMediaColors.onScrim),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: media.padding.top,
          bottom: screen.height - panelTop,
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: _openTransform(
                    context,
                    route,
                    _circle(context, screen),
                  ),
                ),
              ),
              _fade(context, route, _cameraControls(context)),
            ],
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: panelTop,
          bottom: 0,
          child: _fade(context, route, _panel(context)),
        ),
        ..._actionLayer(context, action),
        Positioned(
          left: NotionSpace.md,
          right: NotionSpace.md,
          top: media.padding.top + NotionSpace.xs,
          child: _fade(context, route, _notices(context)),
        ),
      ],
    );
    return PopScope(
      // System back cannot escape while asynchronous cleanup is still pending.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_discard());
      },
      child: Material(type: MaterialType.transparency, child: body),
    );
  }

  Widget _openTransform(
    BuildContext context,
    Animation<double>? route,
    Widget child,
  ) {
    if (route == null) return child;
    return AnimatedBuilder(
      animation: route,
      child: child,
      builder: (context, child) {
        final t = _openProgress(context);
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, (1 - t) * MediaQuery.sizeOf(context).height / 2),
            child: Transform.scale(scale: 0.1 + 0.9 * t, child: child),
          ),
        );
      },
    );
  }

  Widget _fade(BuildContext context, Animation<double>? route, Widget child) {
    if (route == null || NotionMotion.reduced(context)) return child;
    return FadeTransition(opacity: route, child: child);
  }

  /// The camera circle with Telegram's white progress ring around it.
  Widget _circle(BuildContext context, Size screen) {
    final state = _controller.state;
    final review = state == RoundCaptureState.review;
    final preview = _controller.preview;
    final player = _player;
    final size = RoundRecorderLayout.circleSize(screen);
    final controller = _controller;
    double progress() => review
        ? 0.0
        : (controller.duration.inMilliseconds / widget.profile.maxDurationMs)
              .clamp(0.0, 1.0);
    final Widget content;
    if (review && player?.value.isInitialized == true) {
      content = FittedBox(
        fit: BoxFit.cover,
        child: SizedBox.fromSize(
          size: player!.value.size,
          child: VideoPlayer(player),
        ),
      );
    } else if (!review && preview != null) {
      content = FittedBox(
        fit: BoxFit.cover,
        child: Transform.flip(
          flipX: preview.mirrored,
          child: RotatedBox(
            quarterTurns: preview.rotation ~/ 90,
            child: SizedBox(
              width: preview.width.toDouble(),
              height: preview.height.toDouble(),
              child: Texture(textureId: preview.textureId),
            ),
          ),
        ),
      );
    } else {
      content = const SizedBox.expand();
    }
    final zoomable =
        state == RoundCaptureState.recording && _controller.canZoom;
    final zoom = _zoom;
    final awaitingLens = _awaitingLens;
    Widget circle = SizedBox.square(
      dimension: size,
      child: ClipOval(
        child: ColoredBox(
          color: NotionMediaColors.stageScrim,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // The live texture repaints on its own layer; the ring, clock and
              // panel ticks never re-record it.
              RepaintBoundary(child: content),
              IgnorePointer(
                child: AnimatedOpacity(
                  key: const Key('round_flip_waiting'),
                  opacity: awaitingLens ? 1 : 0,
                  duration: NotionMotion.of(context, NotionMotion.quick),
                  curve: NotionMotion.standard,
                  child: ColoredBox(
                    color: NotionMediaColors.scrim,
                    child: awaitingLens
                        ? const Center(
                            child: NotionDelayedSpinner(
                              size: NotionSize.iconLg,
                              color: NotionMediaColors.onScrim,
                            ),
                          )
                        : const SizedBox.expand(),
                  ),
                ),
              ),
              if (state == RoundCaptureState.paused)
                const ColoredBox(
                  color: NotionMediaColors.scrim,
                  child: Center(
                    child: Icon(
                      Icons.pause,
                      size: NotionSize.iconLg * 2,
                      color: NotionMediaColors.onScrim,
                    ),
                  ),
                ),
              if (state == RoundCaptureState.initializing ||
                  (state == RoundCaptureState.preparing &&
                      _controller.isFinalizing) ||
                  (review && player?.value.isInitialized != true))
                const Center(
                  child: NotionDelayedSpinner(
                    size: NotionSize.iconLg,
                    color: NotionMediaColors.onScrim,
                  ),
                ),
              if (review)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: NotionSpace.lg,
                  child: Center(
                    child: NotionPop(
                      key: ValueKey(_previewMuted),
                      bounce: false,
                      child: DecoratedBox(
                        decoration: const ShapeDecoration(
                          color: NotionMediaColors.scrim,
                          shape: CircleBorder(),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(NotionSpace.xs),
                          child: Icon(
                            _previewMuted
                                ? Icons.volume_off_outlined
                                : Icons.volume_up_outlined,
                            size: NotionSize.icon,
                            color: NotionMediaColors.onScrim,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    String zoomLabel(double value) => '${value.toStringAsFixed(1)} times zoom';
    final zoomIn = zoomable && preview != null && zoom < preview.maxZoom
        ? math.min(zoom + 0.5, preview.maxZoom)
        : null;
    final zoomOut = zoomable && preview != null && zoom > preview.minZoom
        ? math.max(zoom - 0.5, preview.minZoom)
        : null;
    final showZoom = zoomIn != null || zoomOut != null;
    circle = Semantics(
      container: true,
      button: review,
      label: review
          ? (_previewMuted ? 'Play preview sound' : 'Mute preview')
          : 'Camera preview',
      // Screen readers zoom with increase/decrease instead of a pinch.
      value: showZoom ? zoomLabel(zoom) : null,
      increasedValue: showZoom ? zoomLabel(zoomIn ?? zoom) : null,
      decreasedValue: showZoom ? zoomLabel(zoomOut ?? zoom) : null,
      onTap: review ? _toggleMute : null,
      onIncrease: zoomIn == null ? null : () => _setZoom(zoomIn),
      onDecrease: zoomOut == null ? null : () => _setZoom(zoomOut),
      excludeSemantics: true,
      child: GestureDetector(
        key: const Key('round_camera_circle'),
        onTap: review ? _toggleMute : null,
        // Telegram: pinch while recording, springing back on release.
        onScaleStart: zoomable
            ? (_) {
                _zoomBack.stop();
                _pinchStartZoom = zoom;
                _pinchRevision = preview?.cameraRevision;
              }
            : null,
        onScaleUpdate: zoomable
            ? (details) {
                if (details.pointerCount < 2 ||
                    _pinchStartZoom == null ||
                    _pinchRevision != _controller.preview?.cameraRevision) {
                  return;
                }
                _setZoom(_pinchStartZoom! * details.scale);
              }
            : null,
        onScaleEnd: zoomable ? (_) => _springZoomBack() : null,
        child: circle,
      ),
    );
    return SizedBox.square(
      dimension:
          size +
          2 * (RoundRecorderLayout.ringGap + RoundRecorderLayout.ringWidth),
      child: CustomPaint(
        // The ring repaints from the recording clock; nothing rebuilds.
        painter: _ProgressRing(progress: progress, repaint: controller.elapsed),
        child: Center(
          child: AnimatedBuilder(
            animation: _flip,
            child: circle,
            builder: (context, child) {
              final t = NotionMotion.emphasized.transform(_flip.value);
              final turn = (t < 0.5 ? t : t - 1) * math.pi;
              if (turn == 0) return child!;
              return Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.001)
                  ..rotateY(turn),
                child: child,
              );
            },
          ),
        ),
      ),
    );
  }

  static final ButtonStyle _mediaButton = IconButton.styleFrom(
    minimumSize: const Size.square(NotionSize.touchTarget),
    backgroundColor: NotionMediaColors.scrim,
    foregroundColor: NotionMediaColors.onScrim,
    disabledBackgroundColor: NotionMediaColors.scrim,
    disabledForegroundColor: NotionMediaColors.onScrim.withAlpha(97),
    shape: const CircleBorder(),
  );

  /// Flip and flash, bottom-left of the camera area like Telegram.
  Widget _cameraControls(BuildContext context) {
    final preview = _controller.preview;
    final state = _controller.state;
    final visible =
        preview != null &&
        (state == RoundCaptureState.ready || _controller.active);
    if (!visible) {
      return const SizedBox(height: NotionSize.touchTarget + NotionSpace.xs);
    }
    final torch = preview.torchAvailable;
    final screenFlash = !torch && _controller.frontCamera;
    final on = torch ? preview.torchEnabled : screenFlash && _screenFlash;
    final flashTooltip = torch
        ? (on ? 'Turn light off' : 'Turn light on')
        : screenFlash
        ? (on ? 'Turn screen flash off' : 'Turn screen flash on')
        : 'Light unavailable on this camera';
    final onFlash = torch
        ? (_controller.canSetTorch ? () => _controller.setTorch(!on) : null)
        : screenFlash
        ? () => setState(() => _screenFlash = !_screenFlash)
        : null;
    return Padding(
      padding: const EdgeInsets.only(
        left: NotionSpace.xs,
        right: NotionSpace.xs,
        bottom: NotionSpace.xs,
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: !preview.canSwitchCamera
                ? 'Only one camera available'
                : _controller.active && !preview.canSwitchDuringRecording
                ? 'Camera switching is unavailable while recording'
                : 'Switch camera',
            onPressed: _controller.canSwitchCamera && !_flip.isAnimating
                ? _switchCamera
                : null,
            style: _mediaButton,
            icon: const Icon(Icons.cameraswitch_outlined),
          ),
          const SizedBox(width: NotionSpace.xs),
          Semantics(
            toggled: on,
            child: IconButton(
              tooltip: flashTooltip,
              onPressed: onFlash,
              style: _mediaButton,
              icon: Icon(on ? Icons.flash_on : Icons.flash_off),
            ),
          ),
        ],
      ),
    );
  }

  /// Destination (and silent marker) plus control errors, over the chat.
  Widget _notices(BuildContext context) {
    final error = _controlError;
    Widget pill(String text, {bool live = false}) => Semantics(
      liveRegion: live,
      child: DecoratedBox(
        decoration: const ShapeDecoration(
          color: NotionMediaColors.scrim,
          shape: StadiumBorder(),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: NotionSpace.sm,
            vertical: NotionSpace.xxs,
          ),
          child: Text(
            text,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: NotionType.footnote.copyWith(
              color: NotionMediaColors.onScrim,
            ),
          ),
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.targetLabel != null) pill(widget.targetLabel!),
        if (error != null) ...[
          const SizedBox(height: NotionSpace.xs),
          pill(error, live: true),
        ],
      ],
    );
  }

  /// Red dot and elapsed time; the live region announces state changes.
  Widget _clock(BuildContext context, {required bool live}) {
    final colors = context.notion.colors;
    return Semantics(
      container: true,
      liveRegion: true,
      label: _status,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RecordingDot(active: live),
          const SizedBox(width: NotionSpace.xs),
          ListenableBuilder(
            listenable: _controller.elapsed,
            builder: (context, _) => Text(
              notionAudioTime(_controller.duration),
              style: NotionType.callout.copyWith(
                color: colors.text,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusText(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    child: Text(
      _status,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: context.notion.typography.footnoteMuted,
    ),
  );

  Widget _deleteButton() => IconButton(
    tooltip: 'Delete recording',
    onPressed: _discard,
    icon: const Icon(Icons.delete_outline),
  );

  /// The composer row while recording (Telegram's record panel).
  Widget _panel(BuildContext context) {
    final colors = context.notion.colors;
    final state = _controller.state;
    final locked =
        _controller.locked ||
        (!_externalDetached &&
            widget.gesture?.phase == RoundCaptureGesturePhase.locked);
    // The record circle / send button is drawn over this end of the row.
    const reserve = SizedBox(width: NotionSize.touchTarget + NotionSpace.md);
    final List<Widget> children;
    if (state == RoundCaptureState.failed) {
      children = [
        Expanded(child: _statusText(context)),
        NotionButton.ghost(label: 'Record again', onPressed: _recordAgain),
        NotionButton.ghost(label: 'Close', onPressed: _discard),
      ];
    } else if (state == RoundCaptureState.review) {
      final prepared = _controller.prepared!;
      final range = _trimRange;
      final player = _player;
      children = [
        _deleteButton(),
        Expanded(
          child:
              range != null &&
                  prepared.durationMs > RoundRecorderLayout.minTrimMs
              ? Semantics(
                  label: 'Trim round video',
                  child: RangeSlider(
                    values: range,
                    max: prepared.durationMs.toDouble(),
                    semanticFormatterCallback: (value) =>
                        '${(value / 1000).toStringAsFixed(1)} seconds',
                    onChangeStart: (_) {
                      _scrubbing = true;
                      unawaited(player?.pause());
                    },
                    onChanged: (value) {
                      if (value.end - value.start <
                          RoundRecorderLayout.minTrimMs) {
                        return;
                      }
                      final movedStart = value.start != range.start;
                      setState(() => _trimRange = value);
                      unawaited(
                        player?.seekTo(
                          Duration(
                            milliseconds: (movedStart ? value.start : value.end)
                                .round(),
                          ),
                        ),
                      );
                    },
                    onChangeEnd: (_) {
                      _scrubbing = false;
                      final start = _trimRange?.start ?? 0;
                      unawaited(
                        player
                            ?.seekTo(Duration(milliseconds: start.round()))
                            .then((_) => player.play()),
                      );
                    },
                  ),
                )
              : Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: _clock(context, live: false),
                ),
        ),
        reserve,
      ];
    } else if (state == RoundCaptureState.paused) {
      children = [
        _deleteButton(),
        _clock(context, live: false),
        Expanded(
          child: Center(
            child: NotionButton.ghost(
              label: 'Preview',
              onPressed: _controller.controlsBusy
                  ? null
                  : () => unawaited(_controller.finish()),
            ),
          ),
        ),
        reserve,
      ];
    } else if (state == RoundCaptureState.preparing &&
        _controller.isFinalizing) {
      children = [
        const SizedBox(width: NotionSpace.md),
        _clock(context, live: false),
        const SizedBox(width: NotionSpace.sm),
        Expanded(child: _statusText(context)),
        reserve,
      ];
    } else if (locked) {
      children = [
        const SizedBox(width: NotionSpace.md),
        _clock(context, live: state == RoundCaptureState.recording),
        Expanded(
          child: Center(
            child: NotionButton.ghost(label: 'Cancel', onPressed: _discard),
          ),
        ),
        reserve,
      ];
    } else if (_holding) {
      children = [
        const SizedBox(width: NotionSpace.md),
        _clock(context, live: state == RoundCaptureState.recording),
        const SizedBox(width: NotionSpace.sm),
        Expanded(child: _slideToCancel(context)),
        reserve,
      ];
    } else {
      children = [
        const SizedBox(width: NotionSpace.md),
        Expanded(child: _statusText(context)),
        reserve,
      ];
    }
    return ColoredBox(
      color: colors.background,
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          height: RoundRecorderLayout.panelHeight,
          child: Row(children: children),
        ),
      ),
    );
  }

  Widget _slideToCancel(BuildContext context) {
    final colors = context.notion.colors;
    final gesture = widget.gesture!;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final offset = gesture.dx.clamp(-gesture.cancelDistance, 0.0);
    return ExcludeSemantics(
      child: Opacity(
        opacity: gesture.slideProgress,
        child: Transform.translate(
          offset: Offset(rtl ? -offset : offset, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                rtl ? Icons.chevron_right : Icons.chevron_left,
                size: NotionSize.iconSm,
                color: colors.textSecondary,
              ),
              Flexible(
                child: Text(
                  'Slide to cancel',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NotionType.footnote.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Record circle under the finger and the lock pill above it. While held
  /// they follow the finger; once locked the circle is the send button and
  /// the pill pauses or resumes.
  List<Widget> _actionLayer(BuildContext context, Offset center) {
    final state = _controller.state;
    final colors = Theme.of(context).colorScheme;
    final gesture = widget.gesture;
    final holding = _holding;
    final finalizing =
        state == RoundCaptureState.preparing && _controller.isFinalizing;
    if (state == RoundCaptureState.failed ||
        state == RoundCaptureState.canceled) {
      return const [];
    }
    const held = NotionSize.touchTarget * VoiceRecordLayout.heldScale;
    Widget at(double size, Widget child, {double dx = 0, double dy = 0}) =>
        Positioned(
          left: center.dx - size / 2 + dx,
          top: center.dy - size / 2 + dy,
          width: size,
          height: size,
          child: child,
        );
    final pillBottom = center.dy - held / 2 - VoiceRecordLayout.lockGap;
    if (holding) {
      final rtl = Directionality.of(context) == TextDirection.rtl;
      final offset = gesture!.dx.clamp(-gesture.cancelDistance, 0.0);
      return [
        at(
          held,
          dx: rtl ? -offset : offset,
          IgnorePointer(
            child: ExcludeSemantics(
              child: Transform.scale(
                scale: 0.7 + 0.3 * gesture.slideProgress,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.onSurface,
                  ),
                  child: Icon(
                    Icons.videocam_outlined,
                    size: NotionSize.iconLg,
                    color: colors.surface,
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: center.dx - VoiceRecordLayout.lockPillWidth / 2,
          top:
              pillBottom -
              VoiceRecordLayout.lockPillHeight -
              gesture.lockProgress * VoiceRecordLayout.lockTravel,
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: _LockHint(progress: gesture.lockProgress),
            ),
          ),
        ),
      ];
    }
    if (state == RoundCaptureState.review) {
      return [
        at(
          NotionSize.touchTarget,
          NotionSendButton(
            tooltip: 'Send round video',
            onPressed: _controller.controlsBusy ? null : _sendReview,
          ),
        ),
      ];
    }
    // Without a composer gesture (attach menu, record again) a tap starts.
    if (state == RoundCaptureState.ready &&
        (widget.gesture == null || _externalDetached)) {
      final canStart = !_controller.controlsBusy;
      return [
        at(
          held,
          Semantics(
            button: true,
            enabled: canStart,
            label: 'Start recording a round video',
            excludeSemantics: true,
            onTap: canStart ? () => _controller.start(lock: true) : null,
            child: GestureDetector(
              key: const Key('round_record_start'),
              onTap: canStart ? () => _controller.start(lock: true) : null,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: canStart
                      ? colors.onSurface
                      : colors.surfaceContainerHighest,
                ),
                child: Icon(
                  Icons.videocam_outlined,
                  size: NotionSize.iconLg,
                  color: canStart ? colors.surface : colors.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ];
    }
    final active = _controller.active;
    final paused = state == RoundCaptureState.paused;
    return [
      at(
        held,
        Center(
          child: Transform.scale(
            scale: VoiceRecordLayout.heldScale,
            child: NotionSendButton(
              tooltip: 'Send round video',
              busy: finalizing,
              onPressed: active && !_controller.controlsBusy
                  ? () => unawaited(_finishAndSend())
                  : null,
            ),
          ),
        ),
      ),
      if (active && (paused || _controller.canPause))
        Positioned(
          left: center.dx - NotionSize.touchTarget / 2,
          top: pillBottom - NotionSize.touchTarget,
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: context.notion.colors.surface,
              shape: StadiumBorder(
                side: BorderSide(color: context.notion.colors.border),
              ),
            ),
            child: IconButton(
              tooltip: paused ? 'Resume recording' : 'Pause recording',
              onPressed: _controller.controlsBusy
                  ? null
                  : paused
                  ? () => unawaited(_controller.resume())
                  : _pause,
              icon: Icon(
                paused ? Icons.fiber_manual_record : Icons.pause,
                color: paused ? context.notion.colors.danger : null,
              ),
            ),
          ),
        ),
    ];
  }
}

/// Dims and blurs the conversation behind the round recorder (Telegram keeps
/// the chat visible behind its camera circle; ours is calmer). One backdrop
/// read covers the whole screen, behind every recorder layer, inside its own
/// repaint boundary, so recorder ticks never re-record it.
///
/// The blur is never animated and never sits inside the route's fade: while
/// the route opens or closes this is a flat scrim of the same darkness (the
/// fade animates only that), and the glass appears once the route has
/// settled. Without glass support (Skia, reduced motion, high contrast) it is
/// a plain, darker scrim throughout. Listens to route status, never to ticks.
class RoundRecorderBackdrop extends StatefulWidget {
  const RoundRecorderBackdrop({super.key});

  @override
  State<RoundRecorderBackdrop> createState() => _RoundRecorderBackdropState();
}

class _RoundRecorderBackdropState extends State<RoundRecorderBackdrop> {
  Animation<double>? _route;
  bool _settled = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context)?.animation;
    if (identical(route, _route)) return;
    _route?.removeStatusListener(_status);
    _route = route?..addStatusListener(_status);
    _settled = route == null || route.isCompleted;
  }

  void _status(AnimationStatus status) {
    final settled = status == AnimationStatus.completed;
    if (settled != _settled && mounted) setState(() => _settled = settled);
  }

  @override
  void dispose() {
    _route?.removeStatusListener(_status);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget fill;
    if (!notionGlassEnabled(context)) {
      fill = const ColoredBox(
        key: Key('round_recorder_scrim'),
        color: NotionMediaColors.stageScrim,
        child: SizedBox.expand(),
      );
    } else if (_settled) {
      fill = const NotionGlassSurface(
        key: Key('round_recorder_glass'),
        tint: NotionMediaColors.scrim,
        repaintBoundary: false,
        child: SizedBox.expand(),
      );
    } else {
      fill = const ColoredBox(
        key: Key('round_recorder_dim'),
        color: NotionMediaColors.scrim,
        child: SizedBox.expand(),
      );
    }
    return IgnorePointer(child: RepaintBoundary(child: fill));
  }
}

/// Lock hint above the held record circle: a lock over a chevron. The lock
/// closes past half the distance (same look as the voice lock pill).
class _LockHint extends StatelessWidget {
  final double progress;
  const _LockHint({required this.progress});

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    final locking = progress >= 0.5;
    return Container(
      key: const Key('round_lock_pill'),
      width: VoiceRecordLayout.lockPillWidth,
      height: VoiceRecordLayout.lockPillHeight,
      decoration: ShapeDecoration(
        color: colors.surface,
        shape: StadiumBorder(side: BorderSide(color: colors.border)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Icon(
            locking ? Icons.lock_outline : Icons.lock_open_outlined,
            size: NotionSize.icon,
            color: locking ? colors.text : colors.textSecondary,
          ),
          Opacity(
            opacity: 1 - progress,
            child: Icon(
              Icons.keyboard_arrow_up,
              size: NotionSize.icon,
              color: colors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Telegram's recording ring: white, 3 dp, round cap, from 12 o'clock
/// clockwise, one turn per maximum duration.
class _ProgressRing extends CustomPainter {
  final double Function() progress;
  _ProgressRing({required this.progress, super.repaint});

  @override
  void paint(Canvas canvas, Size size) {
    final progress = this.progress();
    if (progress <= 0) return;
    // The stroke is centred ringGap outside the circle.
    final rect = (Offset.zero & size).deflate(RoundRecorderLayout.ringWidth);
    canvas.drawArc(
      rect,
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      Paint()
        ..color = NotionMediaColors.onScrim
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = RoundRecorderLayout.ringWidth,
    );
  }

  @override
  bool shouldRepaint(_ProgressRing oldDelegate) =>
      oldDelegate.progress() != progress();
}

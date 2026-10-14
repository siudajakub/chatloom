// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import '../../personal/media/media_access.dart';
import '../../personal/round_video/round_capture_backend.dart';
import '../../personal/round_video/round_capture_controller.dart';
import '../../personal/round_video/round_media_preparer.dart';

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
  return showDialog<PreparedRoundMedia>(
    context: context,
    barrierDismissible: false,
    builder: (_) => RoundVideoRecorder(
      mediaAccess: mediaAccess,
      profile: profile,
      targetLabel: targetLabel,
      gesture: gesture,
    ),
  );
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
    with WidgetsBindingObserver {
  late RoundCaptureController _controller;
  VideoPlayerController? _player;
  Future<void> _playerDisposal = Future<void>.value();
  PreparedRoundMedia? _playerMedia;
  RangeValues? _trimRange;
  Future<void>? _holdStart;
  bool _holdLocked = false;
  bool _holdCanceled = false;
  bool _localHoldActive = false;
  bool _closing = false;
  bool _externalStarted = false;
  bool _externalFinishing = false;
  bool _externalDetached = false;
  double? _zoomDraft;
  int? _zoomDraftRevision;
  double? _pinchStartZoom;
  int? _pinchRevision;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.gesture?.addListener(_externalGestureChanged);
    _setup();
  }

  void _setup() {
    _controller = RoundCaptureController(
      backend: AndroidRoundCaptureBackend(widget.mediaAccess),
      profile: widget.profile,
    )..addListener(_changed);
    unawaited(_controller.initialize());
    _externalGestureChanged();
  }

  void _changed() {
    if (!mounted || _closing) return;
    _externalGestureChanged();
    if (_controller.state == RoundCaptureState.review &&
        _controller.prepared != _playerMedia) {
      unawaited(_loadReview(_controller.prepared!));
    }
    setState(() {});
  }

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
        _externalFinishing = true;
        unawaited(_finishExternalHold());
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

  Future<void> _finishExternalHold() async {
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
      player.addListener(_refreshPlayer);
      setState(() {});
    } catch (_) {
      // Keep the validated draft available even if native preview fails.
      if (mounted && !_closing) setState(() {});
    }
  }

  void _refreshPlayer() {
    if (mounted && !_closing) setState(() {});
  }

  /// Join every previous player cleanup too: a late review initialization or
  /// replacement must not keep a codec open after this route returns its lease.
  Future<void> _disposeReviewPlayer() {
    final player = _player;
    _player = null;
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
    _controller.removeListener(_changed);
    _controller.dispose();
    if (!mounted) return;
    _holdStart = null;
    _localHoldActive = false;
    _zoomDraft = null;
    _pinchStartZoom = null;
    _closing = false;
    _setup();
    setState(() {});
  }

  void _beginHold(LongPressStartDetails details) {
    if (_closing ||
        _controller.controlsBusy ||
        _controller.state != RoundCaptureState.ready) {
      return;
    }
    _localHoldActive = true;
    _holdLocked = false;
    _holdCanceled = false;
    _holdStart = _controller.start();
  }

  void _moveHold(LongPressMoveUpdateDetails details) {
    if (!_localHoldActive || _holdCanceled || _holdLocked) return;
    if (details.offsetFromOrigin.dx < -90) {
      _holdCanceled = true;
      unawaited(_discard());
    } else if (details.offsetFromOrigin.dy < -70) {
      _holdLocked = true;
      _controller.lock();
    }
  }

  Future<void> _endHold(LongPressEndDetails details) async {
    if (!_localHoldActive) return;
    _localHoldActive = false;
    final controller = _controller;
    await _holdStart;
    if (!identical(controller, _controller) ||
        _holdCanceled ||
        _closing ||
        controller.wasInterrupted) {
      return;
    }
    if (_holdLocked) {
      _controller.lock();
      return;
    }
    if (_controller.state == RoundCaptureState.recording &&
        !_controller.locked) {
      if (_controller.duration.inMilliseconds <
          RoundCaptureController.minimumDurationMs) {
        await _discard();
        return;
      }
      await controller.finish();
      // A limit/interruption always opens review. Only this active hold release
      // is permitted to accept without the separate review send button.
      if (!_closing &&
          mounted &&
          identical(controller, _controller) &&
          !controller.wasInterrupted) {
        await _accept();
      }
    }
  }

  Future<void> _applyTrim() async {
    final range = _trimRange;
    if (range == null) return;
    await _disposeReviewPlayer();
    _playerMedia = null;
    await _controller.trim(range.start.round(), range.end.round());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.gesture?.removeListener(_externalGestureChanged);
    _controller.removeListener(_changed);
    _controller.dispose();
    unawaited(_disposeReviewPlayer());
    super.dispose();
  }

  String get _status => switch (_controller.state) {
    RoundCaptureState.initializing => 'Opening camera…',
    RoundCaptureState.ready =>
      _controller.controlsBusy ? 'Updating camera controls…' : 'Hold to record',
    RoundCaptureState.recording =>
      _controller.locked ? 'Recording locked' : 'Up to lock · Left to cancel',
    RoundCaptureState.paused => 'Recording paused',
    RoundCaptureState.preparing => 'Preparing round video…',
    RoundCaptureState.review => 'Review before sending',
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = _controller.state;
    final review = state == RoundCaptureState.review;
    final ready = state == RoundCaptureState.ready;
    final canStart = ready && !_controller.controlsBusy;
    final duration = _controller.duration;
    final elapsed =
        '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
    final preview = _controller.preview;
    final captureControls = ready || _controller.active;
    final zoom = preview == null
        ? 1.0
        : (_zoomDraftRevision == preview.cameraRevision ? _zoomDraft : null) ??
              preview.zoom;
    final player = _player;
    return PopScope(
      // System back cannot escape while asynchronous cleanup is still pending.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_discard());
      },
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Telegram round video',
                    style: theme.textTheme.titleLarge,
                  ),
                  if (widget.targetLabel != null) ...[
                    const SizedBox(height: 8),
                    Text(widget.targetLabel!, style: theme.textTheme.bodySmall),
                  ],
                  const SizedBox(height: 20),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: GestureDetector(
                        onScaleStart: _controller.canZoom
                            ? (_) {
                                _pinchStartZoom = zoom;
                                _pinchRevision = preview?.cameraRevision;
                              }
                            : null,
                        onScaleUpdate: _controller.canZoom
                            ? (details) {
                                if (details.pointerCount < 2 ||
                                    _pinchStartZoom == null ||
                                    _pinchRevision !=
                                        _controller.preview?.cameraRevision) {
                                  return;
                                }
                                _setZoom(_pinchStartZoom! * details.scale);
                              }
                            : null,
                        onScaleEnd: (_) => _pinchStartZoom = null,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ClipOval(
                              child: ColoredBox(
                                color: Colors.black,
                                child:
                                    review &&
                                        player?.value.isInitialized == true
                                    ? VideoPlayer(player!)
                                    : !review && preview != null
                                    ? FittedBox(
                                        fit: BoxFit.cover,
                                        child: Transform.flip(
                                          flipX: preview.mirrored,
                                          child: RotatedBox(
                                            quarterTurns:
                                                preview.rotation ~/ 90,
                                            child: SizedBox(
                                              width: preview.width.toDouble(),
                                              height: preview.height.toDouble(),
                                              child: Texture(
                                                textureId: preview.textureId,
                                              ),
                                            ),
                                          ),
                                        ),
                                      )
                                    : const Center(
                                        child: Icon(
                                          Icons.videocam_outlined,
                                          color: Colors.white,
                                          size: 48,
                                        ),
                                      ),
                              ),
                            ),
                            if (state == RoundCaptureState.preparing ||
                                state == RoundCaptureState.initializing)
                              const Center(child: CircularProgressIndicator()),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Text(_status, textAlign: TextAlign.center),
                  ),
                  const SizedBox(height: 8),
                  Text('$elapsed / 1:00', style: theme.textTheme.titleMedium),
                  if (captureControls && preview != null) ...[
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 12,
                      children: [
                        IconButton(
                          tooltip: !preview.canSwitchCamera
                              ? 'Only one camera available'
                              : _controller.active &&
                                    !preview.canSwitchDuringRecording
                              ? 'Camera switching is unavailable while recording'
                              : 'Switch camera',
                          onPressed: _controller.canSwitchCamera
                              ? _controller.switchCamera
                              : null,
                          icon: const Icon(Icons.cameraswitch_outlined),
                        ),
                        Semantics(
                          toggled: preview.torchEnabled,
                          child: IconButton(
                            tooltip: !preview.torchAvailable
                                ? 'Light unavailable on this camera'
                                : preview.torchEnabled
                                ? 'Turn light off'
                                : 'Turn light on',
                            onPressed: _controller.canSetTorch
                                ? () => _controller.setTorch(
                                    !preview.torchEnabled,
                                  )
                                : null,
                            icon: Icon(
                              preview.torchEnabled
                                  ? Icons.flash_on
                                  : Icons.flash_off,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (preview.canZoom)
                      Row(
                        children: [
                          Text(
                            '${zoom.toStringAsFixed(1)}×',
                            style: theme.textTheme.bodyMedium,
                          ),
                          Expanded(
                            child: Semantics(
                              label: 'Camera zoom',
                              child: Slider(
                                value: zoom.clamp(
                                  preview.minZoom,
                                  preview.maxZoom,
                                ),
                                min: preview.minZoom,
                                max: preview.maxZoom,
                                onChanged: _controller.canZoom
                                    ? _setZoom
                                    : null,
                                semanticFormatterCallback: (value) =>
                                    '${value.toStringAsFixed(1)} times zoom',
                              ),
                            ),
                          ),
                        ],
                      )
                    else
                      Text(
                        'Zoom unavailable on this camera',
                        style: theme.textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                  ],
                  if (_controlError != null)
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _controlError!,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  if (review && player?.value.isInitialized == true) ...[
                    Row(
                      children: [
                        IconButton(
                          tooltip: player!.value.isPlaying
                              ? 'Pause preview'
                              : 'Play with sound',
                          onPressed: () => player.value.isPlaying
                              ? player.pause()
                              : player.play(),
                          icon: Icon(
                            player.value.isPlaying
                                ? Icons.pause
                                : Icons.play_arrow,
                          ),
                        ),
                        Expanded(
                          child: Slider(
                            value: player.value.position.inMilliseconds
                                .toDouble()
                                .clamp(
                                  0,
                                  player.value.duration.inMilliseconds
                                      .toDouble(),
                                ),
                            max: player.value.duration.inMilliseconds
                                .toDouble(),
                            onChanged: (value) => player.seekTo(
                              Duration(milliseconds: value.round()),
                            ),
                            semanticFormatterCallback: (value) =>
                                '${(value / 1000).round()} seconds',
                          ),
                        ),
                      ],
                    ),
                    if (_controller.prepared!.durationMs >=
                        2 * RoundCaptureController.minimumDurationMs) ...[
                      RangeSlider(
                        values: _trimRange!,
                        max: _controller.prepared!.durationMs.toDouble(),
                        labels: RangeLabels(
                          '${(_trimRange!.start / 1000).toStringAsFixed(1)} s',
                          '${(_trimRange!.end / 1000).toStringAsFixed(1)} s',
                        ),
                        onChanged: (value) {
                          if (value.end - value.start >=
                              RoundCaptureController.minimumDurationMs) {
                            setState(() => _trimRange = value);
                          }
                        },
                      ),
                      TextButton(
                        onPressed: _applyTrim,
                        child: const Text('Trim recording'),
                      ),
                    ],
                  ],
                  const SizedBox(height: 12),
                  if (ready ||
                      (_holdStart != null &&
                          !review &&
                          state != RoundCaptureState.failed))
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Semantics(
                          button: true,
                          enabled: canStart,
                          label:
                              'Record a round video. Tap for hands-free recording, or hold.',
                          onTap: canStart
                              ? () => _controller.start(lock: true)
                              : null,
                          child: GestureDetector(
                            onTap: canStart
                                ? () => _controller.start(lock: true)
                                : null,
                            onLongPressStart: canStart ? _beginHold : null,
                            onLongPressMoveUpdate: _moveHold,
                            onLongPressEnd: _endHold,
                            child: CircleAvatar(
                              radius: 32,
                              backgroundColor: ready && !canStart
                                  ? theme.colorScheme.surfaceContainerHighest
                                  : theme.colorScheme.primary,
                              foregroundColor: ready && !canStart
                                  ? theme.colorScheme.onSurfaceVariant
                                  : theme.colorScheme.onPrimary,
                              child: const Icon(Icons.videocam, size: 32),
                            ),
                          ),
                        ),
                      ],
                    ),
                  if (_controller.active)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (!_controller.locked)
                          IconButton(
                            tooltip: 'Lock recording',
                            onPressed: _controller.lock,
                            icon: const Icon(Icons.lock_outline),
                          ),
                        IconButton(
                          tooltip: state == RoundCaptureState.paused
                              ? 'Resume recording'
                              : 'Pause recording',
                          onPressed: _controller.controlsBusy
                              ? null
                              : state == RoundCaptureState.paused
                              ? _controller.resume
                              : _controller.pause,
                          icon: Icon(
                            state == RoundCaptureState.paused
                                ? Icons.play_arrow
                                : Icons.pause,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Finish and review',
                          onPressed: _controller.finish,
                          icon: const Icon(Icons.stop),
                        ),
                      ],
                    ),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: _discard,
                        child: const Text('Cancel'),
                      ),
                      if (review || state == RoundCaptureState.failed)
                        TextButton(
                          onPressed: _recordAgain,
                          child: const Text('Record again'),
                        ),
                      if (review)
                        FilledButton(
                          onPressed: _accept,
                          child: const Text('Send'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

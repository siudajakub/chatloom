// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:chatloom/personal/media/editor/media_edit_plan.dart';
import 'package:chatloom/personal/media/editor/media_editor_skin.dart';
import 'package:chatloom/personal/media/media_access.dart';
import 'package:chatloom/personal/storage/storage_failure.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_image_editor/pro_image_editor.dart';
import 'package:pro_video_editor/pro_video_editor.dart' hide ColorFilter;
import 'package:video_player/video_player.dart';

/// An edited video: an MP4 in a private, locked lease ([ManagedMediaFile]).
/// The owner closes [lease] once the bytes were read for sending, or when
/// the edit is dropped; a crash leaves it to the next start's sweep.
class EditedVideo {
  final ManagedMediaFile lease;

  /// The size shown after the crop, rotation and scale, when known.
  final Size? size;

  EditedVideo(this.lease, {this.size});

  String get path => lease.file.path;
}

/// Plaintext renders of edited videos (one lease each), swept at startup.
const editedVideoFolder = 'personal_media_edits';

/// The plugin's own log level. Its Android side has no BuildConfig to tell
/// a release build, so it logs at debug level, source paths included
/// ("Processing clip 0: /data/…"); warnings and errors are enough.
const _nativeLog = NativeLogLevel.warning;

Future<MediaAccess>? _editsAccess;

Future<ManagedMediaFile> _createEditLease() async {
  final create = VideoEditorPage.debugCreateLease;
  if (create != null) return create();
  final access = _editsAccess ??= getTemporaryDirectory().then(
    (temporary) => MediaAccess.open(
      directory: Directory('${temporary.path}/$editedVideoFolder'),
    ),
  );
  try {
    return await (await access).createWriter(extension: '.mp4');
  } catch (_) {
    _editsAccess = null;
    rethrow;
  }
}

/// Whether videos can be edited here: the native trim/crop/export of
/// `pro_video_editor` runs on Android, iOS and macOS only, the same
/// platforms that compress videos before sending.
bool get canEditVideos => PlatformInfos.supportsVideoTranscode;

/// Opens the video editor over the send preview: the kept span is chosen on
/// a trim bar of frames (the preview loops it), the frame is cropped and
/// rotated in Crop, the sound can be removed. Returns the edited video, or
/// null when the user closed the editor or changed nothing. [keepQuality]:
/// the video goes out as a file, so a re-encoded edit keeps the source's
/// size, frame rate and bitrate instead of the HD send profile's.
Future<EditedVideo?> showVideoEditor(
  BuildContext context, {
  required String path,
  required String heroTag,
  bool keepQuality = false,
}) => Navigator.of(context).push<EditedVideo>(
  NotionMediaRoute(
    builder: (_) =>
        VideoEditorPage(path: path, heroTag: heroTag, keepQuality: keepQuality),
  ),
);

/// What a failure was, for the log: its type, the native code, cause and
/// source formats, never a path (see [redactMediaPaths]).
@visibleForTesting
String describeVideoEditFailure(Object error) {
  final text = StringBuffer(error.runtimeType);
  switch (error) {
    case PlatformException(:final code, :final message):
      text.write(' $code');
      final details = NativeFailureDetails.of(error);
      if (details != null) text.write(' $details');
      if (message != null) text.write(': $message');
    case RenderEncoderException(:final isTransient, :final details):
      text.write(isTransient ? ' (transient)' : ' (unsupported)');
      if (details != null) text.write(' $details');
      if (error.message case final message?) text.write(': $message');
    case StorageFailure(:final code):
      text.write(' ${code.name}');
  }
  final safe = redactMediaPaths(text.toString());
  return safe.length > 600 ? '${safe.substring(0, 600)}…' : safe;
}

/// Runs a player call in the background. A call on the player the render
/// just released fails (a seek in flight, a late pause); its error is
/// logged here, redacted, instead of reaching the zone's error reporter
/// with whatever path its message quotes.
void _quietly(Future<void>? call, String what) {
  if (call == null) return;
  unawaited(
    call.catchError((Object error) {
      Logs().w('video_editor_${what}_failed', describeVideoEditFailure(error));
    }),
  );
}

/// What the person is told when Done could not render the edit.
String _failureMessage(Object error) => switch (error) {
  RenderEncoderException(isTransient: true) =>
    'The phone\'s video encoder is busy. Close other video apps and try again.',
  RenderEncoderException() =>
    'This phone can\'t encode the edited video. You can still send it as it is.',
  PlatformException()
      when NativeFailureDetails.of(error)?.isOutOfStorage ?? false =>
    'There isn\'t enough free space to save the edited video.',
  StorageFailure() => 'The edited video couldn\'t be saved on this phone.',
  _ => 'This video couldn\'t be edited. Try again, or send it as it is.',
};

class VideoEditorPage extends StatefulWidget {
  final String path;
  final String heroTag;
  final bool keepQuality;

  const VideoEditorPage({
    super.key,
    required this.path,
    required this.heroTag,
    this.keepQuality = false,
  });

  /// Tests: where Done writes its render (instead of the app's temp dir).
  @visibleForTesting
  static Future<ManagedMediaFile> Function()? debugCreateLease;

  @override
  State<VideoEditorPage> createState() => _VideoEditorPageState();
}

class _VideoEditorPageState extends State<VideoEditorPage> {
  static const int _thumbnailCount = 10;
  static const double _trimBarHeight = 56;
  static const _crop = NotionEditorTool(
    id: 'crop',
    icon: Icons.crop_rounded,
    label: 'Crop',
  );

  /// A native loop to 0 is caught this far before a trimmed start.
  static const _loopSlack = Duration(milliseconds: 300);

  late final EditorVideo _source = EditorVideo.file(widget.path);
  final _editor = GlobalKey<ProImageEditorState>();

  /// The preview; null while its decoder is lent to the render (a paused
  /// player still holds one, and phones allow few at once).
  final _player = ValueNotifier<VideoPlayerController?>(null);
  ProVideoController? _video;
  late final VideoEditorCallbacks _videoCallbacks = VideoEditorCallbacks(
    onPlay: () => _quietly(_player.value?.play(), 'play'),
    onPause: () => _quietly(_player.value?.pause(), 'pause'),
    onMuteToggle: (muted) =>
        _quietly(_player.value?.setVolume(muted ? 0 : 1), 'volume'),
    onTrimSpanUpdate: _onTrimUpdate,
    onTrimSpanEnd: _onTrimEnd,
  );
  Duration _duration = Duration.zero;
  Size _resolution = Size.zero;
  int _bitrate = 0;

  /// Source pixels per stage pixel ([videoStageSize]).
  double _stageScale = 1;
  TrimEdgeTracker? _edges;
  List<ImageProvider>? _thumbnails;
  bool _failed = false;

  /// The kept span, exact: the package's trim bar reports whole seconds
  /// while a handle moves and only its drag's end exactly.
  TrimDurationSpan? _span;
  bool _seeking = false;
  (TrimDurationSpan, bool)? _pendingSeek;

  /// The trim bar's first update is it setting itself up (the whole clip
  /// in whole seconds, a frame after it mounts), never a drag, even with a
  /// finger already on the screen.
  bool _trimBarSetUp = false;

  /// The render in flight: a fresh task id per attempt, for its progress.
  final _task = ValueNotifier<String?>(null);
  bool _rendering = false;
  bool _cancelled = false;
  EditedVideo? _result;

  /// The render was cancelled or failed: Done's close keeps the editor open.
  bool _stay = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _quietly(_load(), 'open');
    _quietly(_loadThumbnails(), 'frames');
  }

  @override
  void dispose() {
    if (_rendering) _cancelRender();
    // Not handed over (system back mid-render, the preview closing): the
    // render is dropped here.
    if (!_closed) _quietly(_result?.lease.close(), 'lease_close');
    final player = _player.value;
    player?.removeListener(_onPosition);
    _quietly(player?.dispose(), 'dispose');
    _player.dispose();
    _task.dispose();
    _video?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final player = VideoPlayerController.file(File(widget.path));
    try {
      final metadata = ProVideoEditor.instance.getMetadata(
        _source,
        nativeLogLevel: _nativeLog,
      );
      await Future.wait<void>([metadata, player.initialize()]);
      final info = await metadata;
      if (!mounted) {
        _quietly(player.dispose(), 'dispose');
        return;
      }
      // The player knows both too when the container does not say.
      final duration = info.duration > Duration.zero
          ? info.duration
          : player.value.duration;
      final resolution = info.resolution.isEmpty
          ? player.value.size
          : info.resolution;
      if (duration <= Duration.zero || resolution.isEmpty) {
        throw const FormatException('no video frames');
      }
      final stage = videoStageSize(resolution);
      final full = TrimDurationSpan(start: Duration.zero, end: duration);
      _duration = duration;
      _resolution = resolution;
      _bitrate = info.bitrate;
      _stageScale = resolution.longestSide / stage.longestSide;
      _span = full;
      _edges = TrimEdgeTracker(duration: duration, step: trimBarStep)
        ..reset(full.start, full.end);
      final video = _video = ProVideoController(
        videoPlayer: _StagePlayer(
          player: _player,
          aspectRatio: resolution.aspectRatio,
        ),
        initialResolution: stage,
        videoDuration: duration,
        fileSize: info.fileSize,
        bitrate: info.bitrate,
        thumbnails: _thumbnails,
        initialTrimSpan: full,
      );
      // Usable before the editor mounts (its notifiers read the configs);
      // the editor sets its own functions when it does.
      video.initialize(
        configsFunction: () => const VideoEditorConfigs(initialPlay: true),
        callbacksAudioFunction: () => const AudioEditorCallbacks(),
        callbacksFunction: () => _videoCallbacks,
      );
      if (!await _attach(player)) {
        _quietly(player.dispose(), 'dispose');
        return;
      }
      // Plays from the start, as `initialPlay` shows.
      _quietly(player.play(), 'play');
      setState(() {});
    } catch (error) {
      Logs().w('video_editor_open_failed', describeVideoEditFailure(error));
      if (_player.value == player) _player.value = null;
      player.removeListener(_onPosition);
      _quietly(player.dispose(), 'dispose');
      if (mounted) setState(() => _failed = true);
    }
  }

  /// Shows [player] on the stage, looping (a full span loops natively,
  /// without a seek) at the editor's volume. False when the page closed
  /// meanwhile: the caller disposes [player].
  Future<bool> _attach(VideoPlayerController player) async {
    final muted = _video?.isMutedNotifier.value ?? false;
    await player.setLooping(true);
    await player.setVolume(muted ? 0 : 1);
    if (!mounted) return false;
    player.addListener(_onPosition);
    _player.value = player;
    return true;
  }

  /// One frame per trim bar cell, at the cell's size in pixels, decoded
  /// while the player and the metadata load.
  Future<void> _loadThumbnails() async {
    final view = PlatformDispatcher.instance.implicitView;
    final ratio = view?.devicePixelRatio ?? 3;
    final width = view == null ? 400.0 : view.physicalSize.width / ratio;
    final cell = Size(
      ((width - 2 * NotionSpace.md) / _thumbnailCount * ratio).roundToDouble(),
      (_trimBarHeight * ratio).roundToDouble(),
    );
    List<ImageProvider> images;
    try {
      final frames = await ProVideoEditor.instance.getKeyFrames(
        KeyFramesConfigs(
          video: _source,
          outputSize: cell,
          boxFit: ThumbnailBoxFit.cover,
          maxOutputFrames: _thumbnailCount,
          outputFormat: ThumbnailFormat.jpeg,
        ),
        nativeLogLevel: _nativeLog,
      );
      if (!mounted) return;
      images = [for (final frame in frames) MemoryImage(frame)];
      await Future.wait([
        for (final image in images) precacheImage(image, context),
      ]);
    } catch (error) {
      // The trim bar keeps its background; trimming still works.
      Logs().w('video_editor_frames_failed', describeVideoEditFailure(error));
      images = const [];
    }
    if (!mounted) return;
    _thumbnails = images;
    _video?.thumbnails = images;
  }

  /// Trimmed as Done sees it ([VideoEditPlan.trimmed], with its slack for
  /// a handle stopped a frame short of an end).
  bool _trimmed(TrimDurationSpan span) => VideoEditPlan(
    duration: _duration,
    start: span.start,
    end: span.end,
  ).trimmed;

  /// Follows playback on the trim bar and loops a trimmed span (about ten
  /// times a second, the player's position updates).
  void _onPosition() {
    final player = _player.value, video = _video, span = _span;
    if (player == null || video == null || span == null) return;
    final position = player.value.position;
    video.setPlayTime(position);
    if (_seeking || !video.isPlayingNotifier.value || !_trimmed(span)) return;
    if (position >= span.end || position < span.start - _loopSlack) {
      _quietly(_seekTo(span, player, resume: true), 'seek');
    }
  }

  /// Seeks [player] to the span's start, unless the render took it off the
  /// stage meanwhile.
  Future<void> _seekTo(
    TrimDurationSpan span,
    VideoPlayerController? player, {
    bool resume = false,
  }) async {
    if (player == null || _player.value != player) return;
    if (_seeking) {
      _pendingSeek = (span, resume);
      return;
    }
    _seeking = true;
    try {
      await player.seekTo(span.start);
      if (!mounted || _player.value != player) return;
      _video?.setPlayTime(span.start);
      // Through the editor, so its play indicator follows.
      if (resume) _video?.play();
    } finally {
      _seeking = false;
    }
    final next = _pendingSeek;
    if (next != null) {
      _pendingSeek = null;
      await _seekTo(next.$1, _player.value, resume: next.$2);
    }
  }

  void _onTrimUpdate(TrimDurationSpan span) {
    final video = _video;
    if (video == null) return;
    if (!_trimBarSetUp) {
      _trimBarSetUp = true;
      // The trim bar setting itself up: it resets to the whole clip in
      // whole seconds. Keep the exact span it means.
      final full = TrimDurationSpan(start: Duration.zero, end: _duration);
      _span = full;
      _edges?.reset(full.start, full.end);
      video.trimDurationSpanNotifier.value = full;
      return;
    }
    if (video.isPlayingNotifier.value) video.pause();
    if (_edges?.update(span.start, span.end) ?? false) {
      NotionHaptics.selection();
    }
  }

  void _onTrimEnd(TrimDurationSpan span) {
    final start = span.start < Duration.zero ? Duration.zero : span.start;
    final end = span.end > _duration ? _duration : span.end;
    final exact = TrimDurationSpan(start: start, end: end);
    _span = exact;
    _edges?.reset(start, end);
    // The badge and the play time show the exact span, not whole seconds.
    _video?.trimDurationSpanNotifier.value = exact;
    _quietly(_seekTo(exact, _player.value, resume: true), 'seek');
  }

  bool get _hasLocalEdits {
    final span = _span, video = _video;
    if (span == null || video == null) return false;
    return _trimmed(span) || video.isMutedNotifier.value;
  }

  Future<void> _render(CompleteParameters parameters) async {
    final video = _video, span = _span;
    if (video == null || span == null) return;
    video.pause();
    final crop = parameters.isTransformed
        ? VideoCrop(
            x: parameters.cropX ?? 0,
            y: parameters.cropY ?? 0,
            width:
                parameters.cropWidth ?? video.initialResolution.width.round(),
            height:
                parameters.cropHeight ?? video.initialResolution.height.round(),
            quarterTurns: (4 - parameters.rotateTurns) % 4,
            flipX: parameters.flipX,
            flipY: parameters.flipY,
          ).toSource(_stageScale, _resolution)
        : null;
    final plan = VideoEditPlan(
      duration: _duration,
      start: span.start,
      end: span.end,
      muted: !video.isAudioEnabled,
      crop: crop,
    );
    if (plan.isUnchanged) return;
    var target = VideoRenderTarget.of(
      plan,
      source: _resolution,
      sourceBitrate: _bitrate,
      keepQuality: widget.keepQuality,
    );
    final fallback = VideoRenderTarget.hd(
      plan,
      source: _resolution,
      sourceBitrate: _bitrate,
    );
    var transientRetried = false;
    _rendering = true;
    _cancelled = false;
    ManagedMediaFile? lease;
    Object? failure;
    try {
      await _releasePreview();
      lease = await _createEditLease();
      for (var attempt = 1; ; attempt++) {
        if (_cancelled || !mounted) throw const RenderCanceledException();
        final id = 'edit-${DateTime.now().microsecondsSinceEpoch}';
        _task.value = id;
        try {
          await ProVideoEditor.instance.renderVideoToFile(
            lease.file.path,
            _renderData(id, plan, target),
            nativeLogLevel: _nativeLog,
          );
          break;
        } on RenderEncoderException catch (error) {
          if (_cancelled || attempt > 2) rethrow;
          if (error.isTransient) {
            // Codec sessions another app (or a closing player) held free
            // up in a moment; once more, then the person decides.
            if (transientRetried) rethrow;
            transientRetried = true;
            Logs().w(
              'video_editor_render_retry',
              describeVideoEditFailure(error),
            );
            await Future<void>.delayed(const Duration(milliseconds: 600));
          } else {
            // The encoder refused a full-quality (sent as a file) render:
            // the HD ceiling every phone encodes.
            if (target == fallback) rethrow;
            target = fallback;
            Logs().w(
              'video_editor_render_fallback',
              describeVideoEditFailure(error),
            );
          }
        }
      }
      if (_cancelled || !mounted) throw const RenderCanceledException();
      _result = EditedVideo(lease, size: target.outputSize);
      lease = null;
    } catch (error) {
      failure = error;
    } finally {
      _rendering = false;
      if (mounted) _task.value = null;
    }
    if (failure == null) return;
    await lease?.close();
    _stay = true;
    if (!mounted) return;
    _quietly(_restorePreview(), 'reopen');
    if (failure is RenderCanceledException) return;
    Logs().w('video_editor_render_failed', describeVideoEditFailure(failure));
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(_failureMessage(failure))));
  }

  VideoRenderData _renderData(
    String id,
    VideoEditPlan plan,
    VideoRenderTarget target,
  ) {
    final crop = plan.crop;
    final scale = target.scale;
    return VideoRenderData(
      id: id,
      videoSegments: [VideoSegment(video: _source)],
      startTime: plan.renderStart,
      endTime: plan.renderEnd,
      enableAudio: !plan.muted,
      transform: crop == null && scale == null
          ? null
          : ExportTransform(
              x: crop?.x,
              y: crop?.y,
              width: crop?.width,
              height: crop?.height,
              rotateTurns: crop?.quarterTurns ?? 0,
              flipX: crop?.flipX ?? false,
              flipY: crop?.flipY ?? false,
              scaleX: scale,
              scaleY: scale,
            ),
      outputFormat: VideoOutputFormat.mp4,
      bitrate: target.bitrate,
      maxFrameRate: target.maxFrameRate,
      shouldOptimizeForNetworkUse: true,
    );
  }

  /// Takes the player off the stage and frees its decoder for the render.
  Future<void> _releasePreview() async {
    final player = _player.value;
    if (player == null) return;
    player.removeListener(_onPosition);
    _player.value = null;
    _pendingSeek = null;
    // The stage drops its VideoPlayer first: building one for a disposed
    // player throws (a grey box in release). In the background no frame is
    // drawn (nor scheduled); the next build drops it before anything else.
    final binding = WidgetsBinding.instance;
    if (binding.hasScheduledFrame) {
      await binding.endOfFrame.timeout(
        const Duration(milliseconds: 250),
        onTimeout: () {},
      );
    }
    try {
      await player.dispose();
    } catch (error) {
      // The render goes on; the decoder is released either way.
      Logs().w('video_editor_dispose_failed', describeVideoEditFailure(error));
    }
  }

  /// After a cancelled or failed render: the preview again, paused at the
  /// kept span's start.
  Future<void> _restorePreview() async {
    if (_player.value != null || !mounted) return;
    final player = VideoPlayerController.file(File(widget.path));
    try {
      await player.initialize();
      final span = _span;
      if (span != null && span.start > Duration.zero) {
        await player.seekTo(span.start);
      }
      // Done again while this loaded: the render has the decoder.
      if (!mounted || _player.value != null || _rendering) {
        _quietly(player.dispose(), 'dispose');
        return;
      }
      if (!await _attach(player)) {
        _quietly(player.dispose(), 'dispose');
        return;
      }
      _video?.setPlayTime(player.value.position);
    } catch (error) {
      Logs().w('video_editor_reopen_failed', describeVideoEditFailure(error));
      _quietly(player.dispose(), 'dispose');
      if (mounted) setState(() => _failed = true);
    }
  }

  void _cancelRender() {
    _cancelled = true;
    final id = _task.value;
    if (id == null) return;
    // A task that already ended is unknown to the plugin: nothing to stop.
    unawaited(ProVideoEditor.instance.cancel(id).catchError((Object _) {}));
  }

  void _close(EditorMode mode) {
    if (_closed || !mounted) return;
    if (mode != EditorMode.main) {
      // A sub-editor's Back (Crop) reports here instead of closing its own
      // page once `onCloseEditor` is set: close it, the editor stays.
      Navigator.of(context).pop();
      return;
    }
    if (_stay) {
      _stay = false;
      return;
    }
    _closed = true;
    _video?.pause();
    Navigator.of(context).pop(_result);
  }

  /// Close (or back) without Done. Crop changes have the editor's own
  /// warning; a trim or mute alone would otherwise vanish without one.
  Future<void> _requestClose() async {
    final editor = _editor.currentState;
    if (editor != null && editor.canUndo) return editor.closeEditor();
    if (_hasLocalEdits && !await _confirmDiscard()) return;
    if (!mounted || _closed) return;
    _closed = true;
    _video?.pause();
    Navigator.of(context).pop();
  }

  Future<bool> _confirmDiscard() => showNotionConfirmDialog(
    context: context,
    title: 'Discard changes?',
    message: 'Your edits to this video will be lost.',
    confirmLabel: 'Discard',
    cancelLabel: 'Keep editing',
    destructive: true,
  );

  void _onBack(bool didPop, Object? _) {
    if (didPop) return;
    if (_rendering) return _cancelRender();
    // The editor asks itself when Crop changed something.
    if (_editor.currentState?.canUndo ?? false) return;
    _quietly(_requestClose(), 'close');
  }

  void _toggleMute() {
    final video = _video;
    if (video == null) return;
    NotionHaptics.selection();
    video.setMuteState(video.isAudioEnabled);
  }

  @override
  Widget build(BuildContext context) {
    final video = _video;
    final Widget body;
    if (_failed) {
      body = _Unavailable(onClose: () => Navigator.of(context).pop());
    } else if (video == null) {
      body = const Center(child: NotionDelayedSpinner());
    } else {
      body = ProImageEditor.video(
        video,
        key: _editor,
        configs: _configs(context, video),
        callbacks: ProImageEditorCallbacks(
          onCompleteWithParameters: _render,
          onCloseEditor: _close,
          videoEditorCallbacks: _videoCallbacks,
        ),
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: _onBack,
      child: ColoredBox(
        color: NotionMediaColors.viewer,
        child: NotionFadeThrough(
          child: KeyedSubtree(
            key: ValueKey(
              _failed
                  ? 'failed'
                  : video == null
                  ? 'load'
                  : 'edit',
            ),
            child: body,
          ),
        ),
      ),
    );
  }

  ProImageEditorConfigs _configs(
    BuildContext context,
    ProVideoController video,
  ) {
    final tokens = context.notion;
    return MediaEditorSkin.configs(
      context,
      heroTag: widget.heroTag,
      loading: (_) => _Exporting(task: _task, onCancel: _cancelRender),
      imageGeneration: const ImageGenerationConfigs(
        // Done with only a trim or mute has no history entry.
        allowEmptyEditingCompletion: true,
      ),
      mainEditor: MainEditorConfigs(
        tools: const [SubEditorMode.cropRotate],
        captureImageOnDone: false,
        widgets: MainEditorWidgets(
          closeWarningDialog: (_) => _confirmDiscard(),
          appBar: (editor, stream) => MediaEditorSkin.topBar(
            stream: stream,
            builder: () => NotionEditorTopBar(
              title: 'Edit video',
              onClose: () => _quietly(_requestClose(), 'close'),
              onDone: editor.doneEditing,
            ),
          ),
          bottomBar: (editor, stream, key) => ReactiveWidget(
            stream: stream,
            builder: (_) => Padding(
              key: key,
              padding: const EdgeInsets.only(
                top: NotionSpace.xs,
                bottom: NotionSpace.sm,
              ),
              child: ValueListenableBuilder<bool>(
                valueListenable: video.isMutedNotifier,
                builder: (context, muted, _) => NotionEditorDock(
                  tools: [
                    _crop,
                    NotionEditorTool(
                      id: 'sound',
                      icon: muted
                          ? Icons.volume_off_rounded
                          : Icons.volume_up_rounded,
                      label: muted ? 'Muted' : 'Sound',
                    ),
                  ],
                  selected: muted ? 'sound' : null,
                  onSelected: (tool) => tool.id == 'crop'
                      ? editor.openCropRotateEditor()
                      : _toggleMute(),
                ),
              ),
            ),
          ),
        ),
      ),
      videoEditor: VideoEditorConfigs(
        initialPlay: true,
        controlsPosition: VideoEditorControlPosition.bottom,
        minTrimDuration: minTrimLength,
        // The bar cannot hold a span shorter than its minimum: a clip that
        // short is sent whole.
        enableTrimBar: _duration > minTrimLength,
        playTimeSmoothingDuration: NotionMotion.of(context, NotionMotion.long),
        animatedIndicatorDuration: NotionMotion.of(context, NotionMotion.short),
        animatedIndicatorSwitchInCurve: NotionMotion.emphasized,
        animatedIndicatorSwitchOutCurve: NotionMotion.exitFast,
        style: VideoEditorStyle(
          toolbarPadding: const EdgeInsets.fromLTRB(
            NotionSpace.md,
            0,
            NotionSpace.md,
            NotionSpace.sm,
          ),
          playIndicatorColor: NotionMediaColors.onScrim,
          playIndicatorBackground: NotionMediaColors.scrim,
          trimBarColor: tokens.palette.accentFill,
          trimBarBackground: tokens.palette.accentFill,
          trimBarHandlerRadius: NotionRadius.sm,
          trimBarHeight: _trimBarHeight,
          trimBarBorderWidth: 2,
          trimBarOutsideAreaBackground: NotionMediaColors.stageScrim,
          trimBarPlayTimeIndicatorColor: NotionMediaColors.onScrim,
          trimBarPlayTimeIndicatorWidth: 2,
          trimBarTextColor: NotionMediaColors.onScrim,
          trimBarTextBackground: NotionMediaColors.scrim,
          trimBarSkeletonColors: [
            tokens.colors.surface,
            tokens.colors.selected,
          ],
        ),
        widgets: VideoEditorWidgets(
          muteButton: (_) => const SizedBox.shrink(),
          infoBanner: (_) => const SizedBox.shrink(),
          trimDurationInfo: (span) => NotionEditorBadge(
            icon: Icons.content_cut_rounded,
            text: formatClipLength(span.duration),
          ),
        ),
      ),
    );
  }
}

/// The video on the editor's stage, sized to the shown (rotated) frame; the
/// stage's background while the render holds the decoder.
class _StagePlayer extends StatelessWidget {
  final ValueListenable<VideoPlayerController?> player;
  final double aspectRatio;

  const _StagePlayer({required this.player, required this.aspectRatio});

  @override
  Widget build(BuildContext context) => Center(
    child: AspectRatio(
      aspectRatio: aspectRatio,
      child: ValueListenableBuilder<VideoPlayerController?>(
        valueListenable: player,
        builder: (context, player, _) =>
            player == null ? const SizedBox.expand() : VideoPlayer(player),
      ),
    ),
  );
}

/// The render's progress over the stage, with Cancel. It blocks the editor
/// at once but shows only when the render is not over in a blink (a copy
/// of an end-trimmed clip is).
class _Exporting extends StatelessWidget {
  final ValueListenable<String?> task;
  final VoidCallback onCancel;

  const _Exporting({required this.task, required this.onCancel});

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.opaque,
    child: NotionDelayedReveal(
      placeholder: const SizedBox.expand(),
      child: ColoredBox(
        color: NotionMediaColors.stageScrim,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(NotionSpace.lg),
            child: ValueListenableBuilder<String?>(
              valueListenable: task,
              builder: (context, id, _) =>
                  _Progress(key: ValueKey(id), taskId: id, onCancel: onCancel),
            ),
          ),
        ),
      ),
    ),
  );
}

class _Progress extends StatefulWidget {
  final String? taskId;
  final VoidCallback onCancel;

  const _Progress({super.key, required this.taskId, required this.onCancel});

  @override
  State<_Progress> createState() => _ProgressState();
}

/// One subscription per task, kept across rebuilds of the overlay.
class _ProgressState extends State<_Progress> {
  late final Stream<ProgressModel>? _progress = widget.taskId == null
      ? null
      : ProVideoEditor.instance.progressStreamById(widget.taskId!);

  @override
  Widget build(BuildContext context) => StreamBuilder<ProgressModel>(
    stream: _progress,
    builder: (context, snapshot) => NotionEditorProgress(
      label: 'Preparing video…',
      progress: snapshot.data?.progress,
      onCancel: widget.onCancel,
    ),
  );
}

class _Unavailable extends StatelessWidget {
  final VoidCallback onClose;

  const _Unavailable({required this.onClose});

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Center(
      child: NotionEmptyState(
        icon: Icons.videocam_off_outlined,
        title: 'This video can\'t be edited',
        message: 'You can still send it as it is.',
        action: NotionButton(label: 'Back', onPressed: onClose),
      ),
    ),
  );
}

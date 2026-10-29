// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:chatloom/personal/media/editor/media_edit_plan.dart';
import 'package:chatloom/personal/media/editor/media_editor_skin.dart';
import 'package:chatloom/personal/media/media_access.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/platform_infos.dart';
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

  /// The size shown after the crop and rotation, when cropped.
  final Size? size;

  EditedVideo(this.lease, {this.size});

  String get path => lease.file.path;
}

/// Plaintext renders of edited videos (one lease each), swept at startup.
const editedVideoFolder = 'personal_media_edits';

Future<MediaAccess>? _editsAccess;

Future<ManagedMediaFile> _createEditLease() async {
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
/// null when the user closed the editor or changed nothing.
Future<EditedVideo?> showVideoEditor(
  BuildContext context, {
  required String path,
  required String heroTag,
}) => Navigator.of(context).push<EditedVideo>(
  NotionMediaRoute(
    builder: (_) => VideoEditorPage(path: path, heroTag: heroTag),
  ),
);

class VideoEditorPage extends StatefulWidget {
  final String path;
  final String heroTag;

  const VideoEditorPage({super.key, required this.path, required this.heroTag});

  @override
  State<VideoEditorPage> createState() => _VideoEditorPageState();
}

class _VideoEditorPageState extends State<VideoEditorPage> {
  static const int _thumbnailCount = 10;
  static const _crop = NotionEditorTool(
    id: 'crop',
    icon: Icons.crop_rounded,
    label: 'Crop',
  );

  final _taskId = 'edit-${DateTime.now().microsecondsSinceEpoch}';
  VideoPlayerController? _player;
  ProVideoController? _video;
  VideoMetadata? _metadata;
  TrimEdgeTracker? _edges;
  bool _failed = false;

  /// The trim span being previewed; playback loops inside it.
  TrimDurationSpan? _span;
  bool _seeking = false;
  TrimDurationSpan? _pendingSeek;

  EditedVideo? _result;

  /// The render was cancelled or failed: Done's close keeps the editor open.
  bool _stay = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    if (!_closed) {
      // Closed mid-render (system back): stop it and drop what it wrote.
      unawaited(ProVideoEditor.instance.cancel(_taskId).catchError((_) {}));
      unawaited(_result?.lease.close());
    }
    _player?.removeListener(_onPosition);
    _player?.dispose();
    _video?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final source = EditorVideo.file(widget.path);
    final player = VideoPlayerController.file(File(widget.path));
    try {
      final (metadata, _) = await (
        ProVideoEditor.instance.getMetadata(source),
        player.initialize(),
      ).wait;
      if (!mounted) {
        await player.dispose();
        return;
      }
      _player = player;
      _metadata = metadata;
      _edges = TrimEdgeTracker(duration: metadata.duration);
      _span = TrimDurationSpan(start: Duration.zero, end: metadata.duration);
      _video = ProVideoController(
        videoPlayer: Center(
          child: AspectRatio(
            aspectRatio: player.value.aspectRatio,
            child: VideoPlayer(player),
          ),
        ),
        initialResolution: metadata.resolution,
        videoDuration: metadata.duration,
        fileSize: metadata.fileSize,
        bitrate: metadata.bitrate,
      );
      player.addListener(_onPosition);
      setState(() {});
      unawaited(_loadThumbnails(source));
    } catch (error, stack) {
      Logs().w('video_editor_open_failed', error.runtimeType.toString(), stack);
      unawaited(player.dispose());
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _loadThumbnails(EditorVideo source) async {
    final view = View.of(context);
    final width =
        view.physicalSize.width / view.devicePixelRatio / _thumbnailCount;
    try {
      final frames = await ProVideoEditor.instance.getKeyFrames(
        KeyFramesConfigs(
          video: source,
          outputSize: Size.square(width * view.devicePixelRatio),
          boxFit: ThumbnailBoxFit.cover,
          maxOutputFrames: _thumbnailCount,
          outputFormat: ThumbnailFormat.jpeg,
        ),
      );
      if (!mounted) return;
      final images = [for (final frame in frames) MemoryImage(frame)];
      await Future.wait([
        for (final image in images) precacheImage(image, context),
      ]);
      if (mounted) _video?.thumbnails = images;
    } catch (error) {
      // The trim bar keeps its skeleton; trimming still works.
      Logs().w('video_editor_frames_failed', error.runtimeType.toString());
      if (mounted) _video?.thumbnails = const [];
    }
  }

  /// Follows playback on the trim bar and loops the kept span.
  void _onPosition() {
    final player = _player, video = _video, span = _span;
    if (player == null || video == null || span == null) return;
    final position = player.value.position;
    video.setPlayTime(position);
    // The editor's play state is the intent: the player itself stops at
    // the file's end, which is also the span's end when it is not trimmed.
    final wantsPlay = video.isPlayingNotifier.value;
    if (!_seeking && wantsPlay && position >= span.end) {
      unawaited(_seekTo(span, resume: true));
    }
  }

  Future<void> _seekTo(TrimDurationSpan span, {bool resume = false}) async {
    _span = span;
    final player = _player;
    if (player == null) return;
    if (_seeking) {
      _pendingSeek = span;
      return;
    }
    _seeking = true;
    try {
      await player.seekTo(span.start);
      if (!mounted) return;
      _video?.setPlayTime(span.start);
      // Through the editor, so its play indicator follows.
      if (resume && mounted) _video?.play();
    } finally {
      _seeking = false;
    }
    final next = _pendingSeek;
    if (next != null) {
      _pendingSeek = null;
      await _seekTo(next, resume: resume);
    }
  }

  void _onTrimUpdate(TrimDurationSpan span) {
    if (_player?.value.isPlaying ?? false) _video?.pause();
    if (_edges?.update(span.start, span.end) ?? false) {
      NotionHaptics.selection();
    }
  }

  void _onTrimEnd(TrimDurationSpan span) {
    _edges?.reset(span.start, span.end);
    unawaited(_seekTo(span, resume: true));
  }

  Future<void> _render(CompleteParameters parameters) async {
    final metadata = _metadata, video = _video;
    if (metadata == null || video == null) return;
    video.pause();
    final plan = VideoEditPlan(
      duration: metadata.duration,
      start: parameters.startTime,
      end: parameters.endTime,
      muted: !video.isAudioEnabled,
      crop: parameters.isTransformed
          ? VideoCrop(
              x: parameters.cropX ?? 0,
              y: parameters.cropY ?? 0,
              width: parameters.cropWidth ?? metadata.resolution.width.round(),
              height:
                  parameters.cropHeight ?? metadata.resolution.height.round(),
              quarterTurns: (4 - parameters.rotateTurns) % 4,
              flipX: parameters.flipX,
              flipY: parameters.flipY,
            )
          : null,
    );
    if (plan.isUnchanged) return;
    ManagedMediaFile? lease;
    try {
      lease = await _createEditLease();
      final crop = plan.crop;
      await ProVideoEditor.instance.renderVideoToFile(
        lease.file.path,
        VideoRenderData(
          id: _taskId,
          videoSegments: [VideoSegment(video: EditorVideo.file(widget.path))],
          startTime: plan.renderStart,
          endTime: plan.renderEnd,
          enableAudio: !plan.muted,
          transform: crop == null
              ? null
              : ExportTransform(
                  x: crop.x,
                  y: crop.y,
                  width: crop.width,
                  height: crop.height,
                  rotateTurns: crop.quarterTurns,
                  flipX: crop.flipX,
                  flipY: crop.flipY,
                ),
          outputFormat: VideoOutputFormat.mp4,
          // The send pipeline compresses by the chosen profile afterwards;
          // the edit itself keeps the source's quality.
          bitrate: metadata.bitrate > 0 ? metadata.bitrate : null,
          shouldOptimizeForNetworkUse: true,
        ),
      );
      _result = EditedVideo(lease, size: crop?.outputSize);
    } catch (error) {
      await lease?.close();
      _stay = true;
      final cancelled = error is RenderCanceledException;
      if (!cancelled) {
        Logs().w('video_editor_render_failed', error.runtimeType.toString());
      }
      if (mounted && !cancelled) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text('This video could not be edited. Try again.'),
          ),
        );
      }
    }
  }

  void _close(EditorMode mode) {
    if (mode != EditorMode.main || _closed || !mounted) return;
    if (_stay) {
      _stay = false;
      return;
    }
    _closed = true;
    _video?.pause();
    Navigator.of(context).pop(_result);
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
        configs: _configs(context, video),
        callbacks: ProImageEditorCallbacks(
          onCompleteWithParameters: _render,
          onCloseEditor: _close,
          videoEditorCallbacks: VideoEditorCallbacks(
            onPlay: () => _player?.play(),
            onPause: () => _player?.pause(),
            onMuteToggle: (muted) => _player?.setVolume(muted ? 0 : 1),
            onTrimSpanUpdate: _onTrimUpdate,
            onTrimSpanEnd: _onTrimEnd,
          ),
        ),
      );
    }
    return ColoredBox(
      color: NotionMediaColors.viewer,
      child: NotionFadeThrough(
        child: KeyedSubtree(
          key: ValueKey(_failed ? 'failed' : video == null ? 'load' : 'edit'),
          child: body,
        ),
      ),
    );
  }

  ProImageEditorConfigs _configs(BuildContext context, ProVideoController video) {
    final tokens = context.notion;
    return MediaEditorSkin.configs(
      context,
      heroTag: widget.heroTag,
      loading: (_) => _Exporting(taskId: _taskId),
      imageGeneration: const ImageGenerationConfigs(
        // Done with only a trim or mute has no history entry.
        allowEmptyEditingCompletion: true,
      ),
      mainEditor: MainEditorConfigs(
        tools: const [SubEditorMode.cropRotate],
        captureImageOnDone: false,
        widgets: MainEditorWidgets(
          closeWarningDialog: (_) => showNotionConfirmDialog(
            context: context,
            title: 'Discard changes?',
            message: 'Your edits to this video will be lost.',
            confirmLabel: 'Discard',
            cancelLabel: 'Keep editing',
            destructive: true,
          ),
          appBar: (editor, stream) => MediaEditorSkin.topBar(
            stream: stream,
            builder: () => NotionEditorTopBar(
              title: 'Edit video',
              onClose: editor.closeEditor,
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
        playTimeSmoothingDuration: NotionMotion.of(
          context,
          NotionMotion.long,
        ),
        animatedIndicatorDuration: NotionMotion.of(
          context,
          NotionMotion.short,
        ),
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
          trimBarHeight: 56,
          trimBarBorderWidth: 2,
          trimBarOutsideAreaBackground: NotionMediaColors.stageScrim,
          trimBarPlayTimeIndicatorColor: NotionMediaColors.onScrim,
          trimBarPlayTimeIndicatorWidth: 2,
          trimBarTextColor: NotionMediaColors.onScrim,
          trimBarTextBackground: NotionMediaColors.scrim,
          trimBarSkeletonColors: [tokens.colors.surface, tokens.colors.selected],
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

/// The render's progress over the stage, with Cancel.
class _Exporting extends StatelessWidget {
  final String taskId;

  const _Exporting({required this.taskId});

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: NotionMediaColors.stageScrim,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(NotionSpace.lg),
        child: StreamBuilder<ProgressModel>(
          stream: ProVideoEditor.instance.progressStreamById(taskId),
          builder: (context, snapshot) => NotionEditorProgress(
            label: 'Preparing video…',
            progress: snapshot.data?.progress,
            onCancel: () => unawaited(ProVideoEditor.instance.cancel(taskId)),
          ),
        ),
      ),
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

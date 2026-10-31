// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:chatloom/pages/chat/events/inline_loop_video.dart';
import 'package:chatloom/pages/chat/events/round_video_view.dart';
import 'package:chatloom/personal/media/cancellable_download.dart';
import 'package:chatloom/personal/media/media_access.dart';
import 'package:chatloom/personal/media_transcript.dart';
import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/utils/size_string.dart';
import 'package:chatloom/widgets/blur_hash.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../widgets/mxc_image.dart';

class EventVideoPlayer extends StatefulWidget {
  final Event event;

  /// Hero tag of the thumbnail this video flies from (default: event id).
  final Object? heroTag;
  final BorderRadius sourceRadius;

  /// Event id of the viewer page on screen. The player starts (and keeps
  /// playing) only while it is this page; null: always (a single video).
  final ValueListenable<String?>? currentPage;

  /// Notifies when the viewer asks to play or pause (Space on a keyboard);
  /// only the player of the current page reacts.
  final Listenable? playPauseRequests;

  const EventVideoPlayer(
    this.event, {
    this.heroTag,
    this.sourceRadius = NotionRadius.mdAll,
    this.currentPage,
    this.playPauseRequests,
    super.key,
  });

  @override
  EventVideoPlayerState createState() => EventVideoPlayerState();
}

class EventVideoPlayerState extends State<EventVideoPlayer> {
  late final _playback = RoundPlaybackCoordinator.shared.register(
    pause: () async {
      await _videoPlayerController?.pause();
    },
    // Background without a lock: pause and keep the position (the frame
    // stays, play resumes it).
    retain: () async {
      await _videoPlayerController?.pause();
    },
    // Lock, account switch, another page: the player is gone; a play
    // button (not a spinner) starts it again.
    stop: () async {
      await _disposeControllers();
      if (mounted) setState(() => _stopped = true);
    },
  );

  /// Stopped from outside (or never started on a page swiped past): the
  /// thumbnail shows a play button.
  bool _stopped = false;

  bool get _isCurrentPage {
    final page = widget.currentPage;
    return page == null || page.value == widget.event.eventId;
  }

  void _onPageChanged() {
    if (!mounted) return;
    if (_isCurrentPage) {
      if (_videoPlayerController == null && !_downloading && !_loadFailed) {
        unawaited(_downloadAction());
      }
    } else {
      // Swiped past while downloading: stop the transfer (Telegram); the
      // page shows a play button when it comes back.
      _download?.cancel();
      final video = _videoPlayerController;
      if (video != null && video.value.isPlaying) {
        unawaited(video.pause().catchError((Object _) {}));
      }
      _playback.releaseAudible();
    }
  }

  void _onPlayPauseRequest() {
    if (!mounted || !_isCurrentPage) return;
    if (_videoPlayerController?.value.isInitialized == true) {
      unawaited(_toggle());
    } else if (_stopped && !_downloading) {
      unawaited(_retry());
    }
  }

  /// Stops the running download (the "×" on the ring).
  void _cancelDownload() {
    _download?.cancel();
    if (mounted) setState(() => _stopped = true);
  }

  bool _coordinating = false;
  void _checkAudible() {
    final player = _videoPlayerController;
    if (player == null ||
        !player.value.isPlaying ||
        _playback.isCurrent ||
        _coordinating) {
      return;
    }
    _coordinating = true;
    unawaited(
      () async {
        try {
          await player.pause();
          if (await _playback.acquireAudible() &&
              _playback.isCurrent &&
              mounted &&
              identical(player, _videoPlayerController)) {
            await player.play();
          }
        } finally {
          _coordinating = false;
        }
      }().catchError((Object _) {}),
    );
  }

  VideoPlayerController? _videoPlayerController;

  /// Position of [_videoPlayerController] for the live transcript; one per
  /// controller, so the transcript keeps its listener across rebuilds.
  MediaPositionListenable? _position;

  MediaPositionListenable _positionOf(VideoPlayerController video) {
    final current = _position;
    if (current != null && identical(current.source, video)) return current;
    return _position = MediaPositionListenable(
      video,
      () => video.value.position,
    );
  }

  double? _downloadProgress;
  int _downloadedBytes = 0;
  ManagedMediaFile? _lease;
  bool _downloading = false;

  /// The transfer in flight; cancelled on close, swipe-away and "×".
  MediaDownloadToken? _download;
  bool _loadFailed = false;

  final _supportsVideoPlayer = PlatformInfos.supportsVideoPlayer;

  Future<void> _downloadAction() async {
    if (!_supportsVideoPlayer) {
      widget.event.saveFile(context);
      return;
    }

    if (_downloading) return;
    _downloading = true;
    if (mounted) {
      setState(() {
        _loadFailed = false;
        _stopped = false;
      });
    }
    try {
      if (!await _playback.acquireAudible() ||
          !_playback.isCurrent ||
          !mounted) {
        if (mounted) setState(() => _stopped = true);
        return;
      }
      final fileSize = _fileSize;
      final token = _download = MediaDownloadToken();
      final MatrixFile videoFile;
      try {
        videoFile = await downloadAttachmentCancellable(
          widget.event,
          token: token,
          onDownloadProgress: fileSize == null
              ? null
              : (bytes) {
                  if (!mounted) return;
                  final fraction = bytes / fileSize;
                  final shown = fraction < 1 ? fraction : null;
                  // One rebuild per percent, not per network chunk.
                  final previous = _downloadProgress;
                  if (shown != null &&
                      previous != null &&
                      (shown - previous).abs() < .01) {
                    return;
                  }
                  setState(() {
                    _downloadProgress = shown;
                    _downloadedBytes = bytes;
                  });
                },
        );
      } on MediaDownloadCancelled {
        if (mounted) {
          setState(() {
            _stopped = true;
            _downloadProgress = null;
            _downloadedBytes = 0;
          });
        }
        return;
      } finally {
        if (identical(_download, token)) _download = null;
      }

      // Dispose the controllers if we already have them.
      await _disposeControllers();
      if (!mounted || !_playback.isCurrent) {
        if (mounted) setState(() => _stopped = true);
        return;
      }
      late VideoPlayerController videoPlayerController;

      // Create the VideoPlayerController from the contents of videoFile.
      if (kIsWeb) {
        videoPlayerController = VideoPlayerController.networkUrl(
          Uri.dataFromBytes(videoFile.bytes, mimeType: videoFile.mimeType),
        );
      } else {
        final tempDir = await getTemporaryDirectory();
        final access = await MediaAccess.open(
          directory: Directory('${tempDir.path}/personal_video'),
        );
        _lease = await access.create(videoFile.bytes, extension: '.mp4');
        videoPlayerController = VideoPlayerController.file(_lease!.file);
      }
      _videoPlayerController = videoPlayerController;
      videoPlayerController.addListener(_checkAudible);

      await videoPlayerController.initialize();
      if (!mounted || !_playback.isCurrent) {
        await _disposeControllers();
        if (mounted) setState(() => _stopped = true);
        return;
      }
      // A GIF loops in the viewer too (Telegram).
      if (InlineLoopVideo.applies(widget.event)) {
        await videoPlayerController.setLooping(true);
      }

      // The viewer uses the same quiet transport as voice notes and rounds.
      // Keep the native controller and encrypted-media lease owned here.
      setState(() {});
      if (await _playback.acquireAudible() &&
          _playback.isCurrent &&
          mounted &&
          identical(_videoPlayerController, videoPlayerController)) {
        await videoPlayerController.play();
      }
    } catch (_) {
      await _disposeControllers();
      if (mounted) setState(() => _loadFailed = true);
    } finally {
      _downloading = false;
    }
  }

  Future<void> _disposeControllers() async {
    final video = _videoPlayerController;
    final lease = _lease;
    _videoPlayerController = null;
    _lease = null;
    try {
      await video?.dispose();
    } finally {
      await lease?.close();
    }
  }

  int? get _fileSize => widget.event.content
      .tryGetMap<String, Object?>('info')
      ?.tryGet<int>('size');

  @override
  void dispose() {
    // Closing the viewer stops the transfer; nothing keeps downloading.
    _download?.cancel();
    widget.currentPage?.removeListener(_onPageChanged);
    widget.playPauseRequests?.removeListener(_onPlayPauseRequest);
    _playback.dispose();
    unawaited(_disposeControllers().catchError((Object _) {}));
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    widget.currentPage?.addListener(_onPageChanged);
    widget.playPauseRequests?.addListener(_onPlayPauseRequest);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_isCurrentPage) {
        _downloadAction();
      } else {
        setState(() => _stopped = true);
      }
    });
  }

  @override
  void didUpdateWidget(EventVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentPage != widget.currentPage) {
      oldWidget.currentPage?.removeListener(_onPageChanged);
      widget.currentPage?.addListener(_onPageChanged);
    }
    if (oldWidget.playPauseRequests != widget.playPauseRequests) {
      oldWidget.playPauseRequests?.removeListener(_onPlayPauseRequest);
      widget.playPauseRequests?.addListener(_onPlayPauseRequest);
    }
  }

  Future<void> _retry() async {
    if (_downloading) return;
    await _disposeControllers();
    if (!mounted) return;
    setState(() {
      _loadFailed = false;
      _stopped = false;
    });
    await _downloadAction();
  }

  Widget _playButton() => Semantics(
    button: true,
    label: 'Play video',
    child: GestureDetector(
      key: const ValueKey('viewer-video-play'),
      onTap: _retry,
      child: const DecoratedBox(
        decoration: ShapeDecoration(
          color: NotionMediaColors.scrim,
          shape: CircleBorder(),
        ),
        child: Padding(
          padding: EdgeInsets.all(NotionSpace.sm),
          child: Icon(
            Icons.play_arrow,
            color: NotionMediaColors.onScrim,
            size: NotionSize.touchTarget,
          ),
        ),
      ),
    ),
  );

  Widget _failure() => Padding(
    padding: const EdgeInsets.all(NotionSpace.sm),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline, color: NotionMediaColors.onScrim),
        const SizedBox(height: NotionSpace.xs),
        Text(
          'Unable to play video',
          textAlign: TextAlign.center,
          style: NotionType.callout.copyWith(color: NotionMediaColors.onScrim),
        ),
        const SizedBox(height: NotionSpace.sm),
        NotionButton.primary(label: 'Try again', onPressed: _retry),
      ],
    ),
  );

  bool _owns(VideoPlayerController video) =>
      mounted && identical(video, _videoPlayerController);

  Future<void> _perform(
    Future<void> Function(VideoPlayerController video) action,
  ) async {
    final video = _videoPlayerController;
    if (video == null || !video.value.isInitialized) return;
    try {
      await action(video);
    } catch (_) {
      if (!mounted || !_owns(video)) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Playback failed. Try again.')),
      );
    }
  }

  Future<void> _toggle() => _perform((video) async {
    if (video.value.isPlaying) {
      await video.pause();
      if (_owns(video)) _playback.releaseAudible();
      return;
    }
    if (!await _playback.acquireAudible() ||
        !_playback.isCurrent ||
        !_owns(video)) {
      return;
    }
    if (video.value.position >= video.value.duration) {
      await video.seekTo(Duration.zero);
    }
    // Seeking may yield to a lock, account change or another player.
    if (!_playback.isCurrent || !_owns(video)) return;
    await video.play();
  });

  Future<void> _seek(Duration position) =>
      _perform((video) => video.seekTo(position));

  Future<void> _setSpeed(double speed) =>
      _perform((video) => video.setPlaybackSpeed(speed));

  static const String fallbackBlurHash = 'L5H2EC=PM+yV0g-mq.wG9c010J}I';

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => MediaTranscriptBuilder(
      event: widget.event,
      builder: (context, transcript) => ValueListenableBuilder<bool>(
        valueListenable: MediaTranscriptPreference.visible,
        builder: (context, visible, _) => _layout(
          context,
          constraints,
          transcript,
          visible ? transcript : null,
        ),
      ),
    ),
  );

  /// The video over its transport; with a [shown] transcript the video gets
  /// smaller, the transcript follows playback between them (Apple Music
  /// lyrics) and video and transport glide to their places.
  Widget _layout(
    BuildContext context,
    BoxConstraints constraints,
    MediaTranscript? transcript,
    MediaTranscript? shown,
  ) {
    final info = widget.event.content.tryGetMap<String, Object?>('info');
    final video = _videoPlayerController;
    final initialized = video?.value.isInitialized == true;
    final showing = shown != null && initialized;
    final intrinsic = initialized
        ? video!.value.size
        : Size(
            (info?.tryGet<int>('w') ?? 400).toDouble(),
            (info?.tryGet<int>('h') ?? 300).toDouble(),
          );
    final bottom = MediaQuery.paddingOf(context).bottom;
    // Leave the transport its own space, including short landscape screens.
    final room =
        constraints.maxHeight -
        bottom -
        NotionSize.touchTarget * 2 -
        NotionSpace.xl;
    final bounds = Size(
      constraints.maxWidth - 2 * NotionSpace.inset,
      // The transcript takes the larger part of the height.
      (showing ? room * .42 : room).clamp(1.0, double.infinity),
    );
    final fitted =
        notionFitMedia(intrinsic.width, intrinsic.height, bounds) ?? bounds;
    final blurHash =
        (widget.event.infoMap as Map<String, dynamic>).tryGet<String>(
          'xyz.amorgan.blurhash',
        ) ??
        fallbackBlurHash;
    final media = NotionMediaHero(
      tag: widget.heroTag ?? widget.event.eventId,
      sourceRadius: widget.sourceRadius,
      child: SizedBox.fromSize(
        size: fitted,
        child: initialized
            ? GestureDetector(
                onTap: _toggle,
                child: ClipRRect(
                  borderRadius: NotionRadius.mdAll,
                  child: ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: video!,
                    child: VideoPlayer(video),
                    builder: (context, value, player) => value.hasError
                        ? _failure()
                        : Stack(
                            fit: StackFit.expand,
                            alignment: Alignment.center,
                            children: [
                              player!,
                              if (value.isBuffering)
                                const Center(child: NotionDelayedSpinner()),
                              if (!value.isPlaying && !value.isBuffering)
                                const Center(
                                  child: DecoratedBox(
                                    decoration: ShapeDecoration(
                                      color: NotionMediaColors.scrim,
                                      shape: CircleBorder(),
                                    ),
                                    child: Padding(
                                      padding: EdgeInsets.all(NotionSpace.sm),
                                      child: Icon(
                                        Icons.play_arrow,
                                        color: NotionMediaColors.onScrim,
                                        size: NotionSize.touchTarget,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                  ),
                ),
              )
            : Stack(
                fit: StackFit.expand,
                children: [
                  if (widget.event.hasThumbnail)
                    MxcImage(
                      event: widget.event,
                      isThumbnail: true,
                      fit: BoxFit.cover,
                      placeholder: (_) => BlurHash(
                        blurhash: blurHash,
                        width: fitted.width,
                        height: fitted.height,
                        fit: BoxFit.cover,
                      ),
                    )
                  else
                    BlurHash(
                      blurhash: blurHash,
                      width: fitted.width,
                      height: fitted.height,
                    ),
                  if (_loadFailed)
                    Center(child: _failure())
                  else if (_stopped && !_downloading)
                    Center(child: _playButton())
                  else
                    Center(
                      child: NotionDelayedReveal(
                        child: _DownloadRing(
                          progress: _downloadProgress,
                          received: _downloadedBytes,
                          total: _fileSize,
                          onCancel: _downloading ? _cancelDownload : null,
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Center(
            key: const ValueKey('viewer-video-media'),
            child: NotionLayoutFlip(trigger: showing, child: media),
          ),
          if (showing)
            Expanded(
              key: const ValueKey('viewer-video-transcript'),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  NotionSpace.inset,
                  NotionSpace.md,
                  NotionSpace.inset,
                  0,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: NotionSize.dialogMaxWidth,
                    ),
                    child: NotionEntrance(
                      child: MediaSyncedTranscript(
                        transcript: shown,
                        position: _positionOf(video!),
                        duration: video.value.duration,
                        declaredDuration: declaredMediaDuration(widget.event),
                        onSeek: (position) => unawaited(_seek(position)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (initialized)
            Padding(
              key: const ValueKey('viewer-video-controls'),
              padding: const EdgeInsets.fromLTRB(
                NotionSpace.inset,
                NotionSpace.sm,
                NotionSpace.inset,
                0,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: NotionSize.dialogMaxWidth,
                ),
                child: NotionLayoutFlip(
                  trigger: showing,
                  child: ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: video!,
                    builder: (context, value, _) => NotionMediaPlaybackControls(
                      playing: value.isPlaying,
                      position: value.position,
                      duration: value.duration,
                      speed: value.playbackSpeed,
                      onToggle: value.hasError ? null : _toggle,
                      onSeek: value.hasError ? null : _seek,
                      onSpeedCycle: value.hasError
                          ? null
                          : () => _setSpeed(
                              RoundVideoView.nextSpeed(value.playbackSpeed),
                            ),
                      onSpeedPicker: value.hasError
                          ? null
                          : () => showRoundSpeedPicker(
                              context,
                              speed: value.playbackSpeed,
                              onChanged: _setSpeed,
                            ),
                      trailing: transcript == null
                          ? null
                          : const MediaTranscriptToggle(),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Download progress of the viewer's video (Telegram): a ring with an "×"
/// that stops the transfer, and "12.4 MB / 48 MB" under it once the size is
/// known.
class _DownloadRing extends StatelessWidget {
  const _DownloadRing({
    required this.progress,
    required this.received,
    required this.total,
    required this.onCancel,
  });

  final double? progress;
  final int received;
  final int? total;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final total = this.total;
    final cancel = onCancel;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: cancel != null,
          label: cancel != null ? 'Cancel download' : null,
          child: GestureDetector(
            key: const ValueKey('viewer-video-cancel'),
            behavior: HitTestBehavior.opaque,
            onTap: cancel,
            child: DecoratedBox(
              decoration: const ShapeDecoration(
                color: NotionMediaColors.scrim,
                shape: CircleBorder(),
              ),
              child: SizedBox.square(
                dimension: NotionSize.touchTarget + NotionSpace.md,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(NotionSpace.xxs),
                      child: SizedBox.expand(
                        child: CircularProgressIndicator(
                          value: progress,
                          strokeWidth: 2.5,
                          color: NotionMediaColors.onScrim,
                        ),
                      ),
                    ),
                    if (cancel != null)
                      const Icon(
                        Icons.close,
                        color: NotionMediaColors.onScrim,
                        size: NotionSize.iconSm,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (total != null && total > 0 && received > 0) ...[
          const SizedBox(height: NotionSpace.xs),
          Text(
            '${received.sizeString} / ${total.sizeString}',
            style: NotionType.caption.copyWith(
              color: NotionMediaColors.onScrim,
            ),
          ),
        ],
      ],
    );
  }
}

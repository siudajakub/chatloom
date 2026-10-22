// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:chatloom/pages/chat/events/inline_loop_video.dart';
import 'package:chatloom/pages/chat/events/round_video_view.dart';
import 'package:chatloom/personal/media/media_access.dart';
import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:chatloom/utils/platform_infos.dart';
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

  const EventVideoPlayer(
    this.event, {
    this.heroTag,
    this.sourceRadius = NotionRadius.mdAll,
    this.currentPage,
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
      final video = _videoPlayerController;
      if (video != null && video.value.isPlaying) {
        unawaited(video.pause().catchError((Object _) {}));
      }
      _playback.releaseAudible();
    }
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

  double? _downloadProgress;
  ManagedMediaFile? _lease;
  bool _downloading = false;
  bool _loadFailed = false;

  // The video_player package only doesn't support Windows and Linux.
  final _supportsVideoPlayer =
      !PlatformInfos.isWindows && !PlatformInfos.isLinux;

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
      final fileSize = widget.event.content
          .tryGetMap<String, Object?>('info')
          ?.tryGet<int>('size');
      final videoFile = await widget.event.downloadAndDecryptAttachment(
        onDownloadProgress: fileSize == null
            ? null
            : (progress) {
                if (!mounted) return;
                final progressPercentage = progress / fileSize;
                setState(() {
                  _downloadProgress = progressPercentage < 1
                      ? progressPercentage
                      : null;
                });
              },
      );

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

  @override
  void dispose() {
    widget.currentPage?.removeListener(_onPageChanged);
    _playback.dispose();
    unawaited(_disposeControllers().catchError((Object _) {}));
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    widget.currentPage?.addListener(_onPageChanged);
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
    builder: (context, constraints) {
      final info = widget.event.content.tryGetMap<String, Object?>('info');
      final video = _videoPlayerController;
      final initialized = video?.value.isInitialized == true;
      final intrinsic = initialized
          ? video!.value.size
          : Size(
              (info?.tryGet<int>('w') ?? 400).toDouble(),
              (info?.tryGet<int>('h') ?? 300).toDouble(),
            );
      final bottom = MediaQuery.paddingOf(context).bottom;
      // Leave the transport its own space, including short landscape screens.
      final bounds = Size(
        constraints.maxWidth - 2 * NotionSpace.inset,
        (constraints.maxHeight -
                bottom -
                NotionSize.touchTarget * 2 -
                NotionSpace.xl)
            .clamp(1.0, double.infinity),
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
                          child: CircularProgressIndicator.adaptive(
                            value: _downloadProgress,
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
            Center(child: media),
            if (initialized)
              Padding(
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
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

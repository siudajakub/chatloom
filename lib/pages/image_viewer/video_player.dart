// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:chatloom/personal/media/media_access.dart';
import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/localized_exception_extension.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/blur_hash.dart';
import 'package:chewie/chewie.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../../utils/error_reporter.dart';
import '../../widgets/mxc_image.dart';

class EventVideoPlayer extends StatefulWidget {
  final Event event;

  /// Hero tag of the thumbnail this video flies from (default: event id).
  final Object? heroTag;
  final BorderRadius sourceRadius;

  const EventVideoPlayer(
    this.event, {
    this.heroTag,
    this.sourceRadius = NotionRadius.mdAll,
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
    stop: () async {
      await _disposeControllers();
      if (mounted) setState(() {});
    },
  );
  bool _coordinating = false;
  void _checkAudible() {
    final player = _videoPlayerController;
    if (player == null ||
        !player.value.isPlaying ||
        _playback.isCurrent ||
        _coordinating)
      return;
    _coordinating = true;
    unawaited(
      () async {
        try {
          await player.pause();
          if (await _playback.acquireAudible() &&
              _playback.isCurrent &&
              mounted &&
              identical(player, _videoPlayerController))
            await player.play();
        } finally {
          _coordinating = false;
        }
      }().catchError((Object _) {}),
    );
  }

  ChewieController? _chewieController;
  VideoPlayerController? _videoPlayerController;

  double? _downloadProgress;
  ManagedMediaFile? _lease;
  bool _downloading = false;

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
    try {
      if(!await _playback.acquireAudible() || !_playback.isCurrent || !mounted) return;
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
      if (!mounted || !_playback.isCurrent) return;
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
        return;
      }

      // Create a ChewieController on top.
      setState(() {
        _chewieController = ChewieController(
          videoPlayerController: videoPlayerController,
          showControlsOnInitialize: false,
          autoPlay: false,
          autoInitialize: true,
          looping: true,
          aspectRatio: _videoPlayerController?.value.aspectRatio,
        );
      });
      if (await _playback.acquireAudible() &&
          _playback.isCurrent &&
          mounted &&
          identical(_videoPlayerController, videoPlayerController)) {
        await videoPlayerController.play();
      }
    } on IOException catch (e) {
      await _disposeControllers();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
    } catch (e, s) {
      await _disposeControllers();
      if (!mounted) return;
      ErrorReporter(context, 'Unable to play video').onErrorCallback(e, s);
    } finally {
      _downloading = false;
    }
  }

  Future<void> _disposeControllers() async {
    final chewie = _chewieController;
    final video = _videoPlayerController;
    final lease = _lease;
    _chewieController = null;
    _videoPlayerController = null;
    _lease = null;
    try {
      chewie?.dispose();
      await video?.dispose();
    } finally {
      await lease?.close();
    }
  }

  @override
  void dispose() {
    _playback.dispose();
    unawaited(_disposeControllers().catchError((Object _) {}));
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _downloadAction();
    });
  }

  static const String fallbackBlurHash = 'L5H2EC=PM+yV0g-mq.wG9c010J}I';

  @override
  Widget build(BuildContext context) {
    final hasThumbnail = widget.event.hasThumbnail;
    final blurHash =
        (widget.event.infoMap as Map<String, dynamic>).tryGet<String>(
          'xyz.amorgan.blurhash',
        ) ??
        fallbackBlurHash;
    final infoMap = widget.event.content.tryGetMap<String, Object?>('info');
    final videoWidth = infoMap?.tryGet<int>('w') ?? 400;
    final videoHeight = infoMap?.tryGet<int>('h') ?? 300;
    // Contained in the stage (below the 52 px top bar), never wider than
    // the screen; the hero lands on exactly this rectangle.
    final stage = MediaQuery.sizeOf(context);
    final fitted =
        notionFitMedia(
          videoWidth,
          videoHeight,
          Size(stage.width, stage.height - 52),
        ) ??
        Size(stage.width, stage.height - 52);
    final width = fitted.width;
    final height = fitted.height;

    final chewieController = _chewieController;
    // One hero for the thumbnail and the playing video, so closing flies
    // back into the bubble from either state.
    final media = NotionMediaHero(
      tag: widget.heroTag ?? widget.event.eventId,
      sourceRadius: widget.sourceRadius,
      child: SizedBox(
        width: width,
        height: height,
        child: chewieController != null
            ? Chewie(controller: chewieController)
            : hasThumbnail
            ? MxcImage(
                event: widget.event,
                isThumbnail: true,
                width: width,
                height: height,
                fit: BoxFit.cover,
                placeholder: (context) => BlurHash(
                  blurhash: blurHash,
                  width: width,
                  height: height,
                  fit: BoxFit.cover,
                ),
              )
            : BlurHash(blurhash: blurHash, width: width, height: height),
      ),
    );
    return Stack(
      children: [
        Center(child: media),
        if (chewieController == null)
          Center(
            // A cached video starts before a spinner would be noticed.
            child: NotionDelayedReveal(
              child: CircularProgressIndicator.adaptive(
                value: _downloadProgress,
              ),
            ),
          ),
      ],
    );
  }
}

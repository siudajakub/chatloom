// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart'
    show ConversationMedia;
import 'package:chatloom/pages/image_viewer/image_viewer.dart';
import 'package:chatloom/personal/media/media_access.dart';
import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/blur_hash.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:personal_core/personal_core.dart';
import 'package:video_player/video_player.dart';

import 'inline_loop_slots.dart';
import 'outgoing_upload_progress.dart';
import 'sticker_event.dart';

/// Bridged GIFs and Telegram video stickers as Telegram shows them: a muted
/// loop that plays inline while it is on screen, not a tap-to-play tile.
///
/// The bridges send a GIF as `m.video` with `info["fi.mau.gif"]` (or
/// `fi.mau.autoplay` + `fi.mau.loop`); a Telegram video sticker (`video/webm`)
/// carries the same flags plus `fi.mau.telegram.animated_sticker`.
///
/// Playback rules (battery and smoothness):
/// - only while at least half of it is in the viewport, its route is the
///   current one, tickers are on (`TickerMode`, so hidden tabs, offstage
///   routes and unfocused macOS windows stop it) and the app is resumed;
/// - at most [maxPlayers] native players exist; the oldest gives way;
/// - always muted, never takes the audible permit; lock, account switch and
///   other app-wide stops ([RoundPlaybackCoordinator.stopAll]) stop it too;
/// - reduced motion, "autoplay" off, an unsupported platform or format (WebM
///   on macOS) show the first frame (thumbnail) with a play mark instead;
///   a tap always opens the full-screen viewer.
class InlineLoopVideo extends StatefulWidget {
  const InlineLoopVideo(
    this.event, {
    super.key,
    required this.width,
    required this.height,
    this.borderRadius = NotionRadius.mdAll,
    this.timeline,
  });

  final Event event;
  final double width;
  final double height;
  final BorderRadius borderRadius;
  final Timeline? timeline;

  /// Native players alive at once across the app.
  static const maxPlayers = InlineLoopSlots.max;

  /// Share of the frame that must be visible to play.
  static const visibleFraction = NotionContentLoop.visibleFraction;

  /// Tests: creates the player instead of downloading the attachment.
  @visibleForTesting
  static Future<VideoPlayerController> Function(Event event)? debugCreatePlayer;

  /// Tests: overrides [PlatformInfos.supportsVideoPlayer].
  @visibleForTesting
  static bool? debugSupportsPlayback;

  /// Tests: the players alive now.
  @visibleForTesting
  static int get debugLivePlayers => InlineLoopSlots.live;

  static Map<String, Object?>? _info(Event event) =>
      event.content.tryGetMap<String, Object?>('info');

  /// A Telegram video sticker (or an `m.sticker` that is a video).
  static bool isVideoSticker(Event event) {
    final info = _info(event);
    if (info?['fi.mau.telegram.animated_sticker'] != null &&
        event.messageType == MessageTypes.Video) {
      return true;
    }
    if (StickerEvents.isVideoStickerHint(event)) return true;
    return event.messageType == MessageTypes.Sticker &&
        event.attachmentMimetype.startsWith('video/');
  }

  /// Whether [event] is a looping GIF or video sticker this widget renders.
  static bool applies(Event event) {
    if (event.redacted) return false;
    if (isVideoSticker(event)) return true;
    if (event.messageType != MessageTypes.Video) return false;
    if (RoundVideoDescriptor.fromContent(event.content) != null) return false;
    final info = _info(event);
    if (info == null) return false;
    return info['fi.mau.gif'] == true ||
        (info['fi.mau.autoplay'] == true && info['fi.mau.loop'] == true);
  }

  /// The box of a video sticker: [side] (see
  /// [ConversationMedia.stickerSide]) on the long side, as image stickers.
  static Size stickerBox(Event event, double side) {
    final info = _info(event);
    return ConversationMedia.stickerFrame(
      side,
      width: info?.tryGet<num>('w'),
      height: info?.tryGet<num>('h'),
    );
  }

  /// WebM does not decode on macOS (AVFoundation); elsewhere it is tried.
  static bool playableFormat(Event event) {
    final mime = event.attachmentMimetype;
    if (mime.contains('webm') && PlatformInfos.isMacOS) return false;
    return true;
  }

  @override
  State<InlineLoopVideo> createState() => _InlineLoopVideoState();
}

class _InlineLoopVideoState extends State<InlineLoopVideo>
    with WidgetsBindingObserver {
  late final RoundPlaybackHandle _handle;

  VideoPlayerController? _player;
  ManagedMediaFile? _lease;
  int _generation = 0;
  bool _starting = false;
  bool _failed = false;

  /// Gave way to newer players: waits until it leaves and re-enters the
  /// viewport, so players never take turns evicting each other.
  bool _evicted = false;
  bool _visible = false;
  bool _viewportScheduled = false;
  ScrollPosition? _scrollPosition;
  bool _tickers = true;
  bool _routeCurrent = true;
  bool _reduced = false;

  bool get _sticker => InlineLoopVideo.isVideoSticker(widget.event);

  bool get _supported =>
      (InlineLoopVideo.debugSupportsPlayback ??
          PlatformInfos.supportsVideoPlayer) &&
      InlineLoopVideo.playableFormat(widget.event);

  /// The loop may play at all (not where, not when).
  bool get _autoplayAllowed =>
      _supported &&
      !_reduced &&
      !_failed &&
      !isOutgoingUpload(widget.event) &&
      AppSettings.autoplayImages.value &&
      AppSettings.showThumbnailsInTimeline.value &&
      RoundMediaPolicy.fromContent(widget.event.content).canPlay;

  bool get _appActive {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  bool get _shouldPlay =>
      _autoplayAllowed &&
      _visible &&
      !_evicted &&
      _tickers &&
      _routeCurrent &&
      _appActive &&
      !RoundPlaybackCoordinator.shared.suspended;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _handle = RoundPlaybackCoordinator.shared.register(
      pause: _pause,
      stop: _release,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickers = TickerMode.valuesOf(context).enabled;
    _routeCurrent = ModalRoute.isCurrentOf(context) ?? true;
    _reduced = NotionMotion.reduced(context);
    final position = Scrollable.maybeOf(context)?.position;
    if (_scrollPosition != position) {
      _scrollPosition?.removeListener(_scheduleViewport);
      _scrollPosition = position;
      position?.addListener(_scheduleViewport);
    }
    _scheduleViewport();
  }

  @override
  void didUpdateWidget(InlineLoopVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event.eventId != widget.event.eventId ||
        !identical(oldWidget.event.room.client, widget.event.room.client)) {
      _failed = false;
      _evicted = false;
      unawaited(_release());
    }
    _scheduleViewport();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _sync();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_release());
    } else {
      unawaited(_pause());
    }
  }

  void _scheduleViewport() {
    if (_viewportScheduled || !mounted) return;
    _viewportScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportScheduled = false;
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.hasSize || !box.attached) return;
      // The shared content-loop rule (DESIGN.md motion rule 4).
      final visible = NotionContentLoop.isVisible(
        box,
        MediaQuery.sizeOf(context),
        fraction: InlineLoopVideo.visibleFraction,
      );
      if (!visible) _evicted = false;
      _visible = visible;
      _sync();
    });
  }

  /// Starts, resumes, pauses or releases the player to match [_shouldPlay].
  void _sync() {
    if (!mounted) return;
    final player = _player;
    if (_shouldPlay) {
      if (player == null) {
        unawaited(_start());
      } else if (player.value.isInitialized && !player.value.isPlaying) {
        unawaited(player.play().catchError((Object _) {}));
      }
      return;
    }
    // Out of view (or not allowed at all): free the native player. Covered
    // or inactive but still in view: only pause, the frame stays.
    if (!_visible || !_autoplayAllowed) {
      unawaited(_release());
    } else {
      unawaited(_pause());
    }
  }

  Future<VideoPlayerController> _createPlayer(int generation) async {
    final custom = InlineLoopVideo.debugCreatePlayer;
    if (custom != null) return custom(widget.event);
    final file = await widget.event.downloadAndDecryptAttachment();
    if (generation != _generation) throw StateError('superseded');
    final options = VideoPlayerOptions(mixWithOthers: true);
    if (kIsWeb) {
      return VideoPlayerController.networkUrl(
        Uri.dataFromBytes(file.bytes, mimeType: file.mimeType),
        videoPlayerOptions: options,
      );
    }
    final tempDir = await getTemporaryDirectory();
    final access = await MediaAccess.open(
      directory: Directory('${tempDir.path}/personal_video'),
    );
    final lease = await access.create(
      file.bytes,
      extension: widget.event.attachmentMimetype.contains('webm')
          ? '.webm'
          : '.mp4',
    );
    if (generation != _generation || !mounted) {
      await lease.close();
      throw StateError('superseded');
    }
    _lease = lease;
    return VideoPlayerController.file(lease.file, videoPlayerOptions: options);
  }

  Future<void> _start() async {
    if (_starting || _player != null) return;
    _starting = true;
    final generation = ++_generation;
    // Make room: the oldest live player gives way. Synchronous, so rows
    // starting in the same frame never exceed the limit together.
    // ChatLoom wave 5b: the budget is shared with the GIF search grid.
    InlineLoopSlots.acquire(this, () {
      _evicted = true;
      unawaited(_release());
    });
    VideoPlayerController? player;
    try {
      player = await _createPlayer(generation);
      if (generation != _generation || !mounted) {
        await player.dispose();
        await _lease?.close();
        _lease = null;
        return;
      }
      _player = player;
      await player.initialize();
      await player.setVolume(0);
      await player.setLooping(true);
      if (generation != _generation || !mounted) return;
      if (_shouldPlay) await player.play();
      if (mounted && !_disposed && generation == _generation) {
        setState(() {});
      }
    } catch (_) {
      if (generation == _generation) {
        await _release();
        // Not playable here (codec, download): the poster stays, a tap
        // still opens the viewer.
        if (mounted && !_disposed) setState(() => _failed = true);
      } else if (!identical(player, _player)) {
        try {
          await player?.dispose();
        } catch (_) {
          // Released meanwhile.
        }
      }
    } finally {
      if (generation == _generation) _starting = false;
    }
  }

  Future<void> _pause() async {
    final player = _player;
    if (player == null || !player.value.isPlaying) return;
    try {
      await player.pause();
    } catch (_) {
      // A failed pause leaves the muted loop; release on the next check.
    }
  }

  Future<void> _release() async {
    ++_generation;
    _starting = false;
    final player = _player;
    final lease = _lease;
    _player = null;
    _lease = null;
    InlineLoopSlots.release(this);
    if (player != null && mounted && !_disposed) setState(() {});
    try {
      await player?.dispose();
    } catch (_) {
      // Already gone.
    } finally {
      await lease?.close();
    }
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _scrollPosition?.removeListener(_scheduleViewport);
    _handle.dispose();
    unawaited(_release());
    super.dispose();
  }

  void _open() {
    if (isOutgoingUpload(widget.event)) return;
    if (!(InlineLoopVideo.debugSupportsPlayback ??
        PlatformInfos.supportsVideoPlayer)) {
      return;
    }
    unawaited(
      showImageViewer(context, widget.event, timeline: widget.timeline),
    );
  }

  Widget _poster(BuildContext context) {
    final event = widget.event;
    final blurHash = event.infoMap.tryGet<String>('xyz.amorgan.blurhash');
    final fit = _sticker ? BoxFit.contain : BoxFit.cover;
    Widget fallback(BuildContext context) => blurHash != null
        ? BlurHash(
            blurhash: blurHash,
            width: widget.width,
            height: widget.height,
            fit: fit,
          )
        : _sticker
        // A video sticker's body is its emoji (Telegram).
        ? Center(
            child: Text(
              event.body.characters.take(2).toString(),
              style: NotionType.title,
            ),
          )
        : ColoredBox(color: context.notion.colors.surface);
    if (!event.hasThumbnail || !AppSettings.showThumbnailsInTimeline.value) {
      return fallback(context);
    }
    return MxcImage(
      event: event,
      cacheKey: event.transactionId ?? event.eventId,
      cacheName: event.room.id,
      isThumbnail: true,
      width: widget.width,
      height: widget.height,
      fit: fit,
      placeholder: fallback,
      usePlaceholderOnError: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    final playing = player != null && player.value.isInitialized;
    final still = !_autoplayAllowed;
    final fit = _sticker ? BoxFit.contain : BoxFit.cover;
    final uploading = isOutgoingUpload(widget.event);
    return Semantics(
      label: _sticker ? 'Sticker' : 'GIF',
      button: true,
      child: NotionTapTarget(
        onTap: _open,
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: ClipRRect(
            borderRadius: widget.borderRadius,
            child: Hero(
              tag: widget.event.eventId,
              createRectTween: NotionMediaHero.rectTween,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _poster(context),
                  if (playing)
                    FittedBox(
                      fit: fit,
                      clipBehavior: Clip.hardEdge,
                      child: SizedBox.fromSize(
                        size: player.value.size.isEmpty
                            ? Size(widget.width, widget.height)
                            : player.value.size,
                        child: VideoPlayer(player),
                      ),
                    ),
                  if (uploading)
                    Center(
                      child: OutgoingUploadOverlay(
                        progress: uploadProgressOf(widget.event),
                      ),
                    )
                  else if (still && !_sticker)
                    const _LoopStillMarks(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A GIF that does not play by itself: a play mark and a "GIF" pill, both
/// static.
class _LoopStillMarks extends StatelessWidget {
  const _LoopStillMarks();

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      const Center(
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: NotionMediaColors.scrim,
            shape: CircleBorder(),
          ),
          child: Padding(
            padding: EdgeInsets.all(NotionSpace.sm),
            child: Icon(
              Icons.play_arrow_outlined,
              color: NotionMediaColors.onScrim,
              size: NotionSize.iconLg,
            ),
          ),
        ),
      ),
      Positioned(
        bottom: NotionSpace.xs,
        left: NotionSpace.xs,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: NotionMediaColors.scrim,
            borderRadius: NotionRadius.pillAll,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: NotionSpace.xs,
              vertical: NotionSpace.xxs,
            ),
            child: Text(
              'GIF',
              style: NotionType.caption.copyWith(
                color: NotionMediaColors.onScrim,
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

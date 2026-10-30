// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/events/inline_loop_slots.dart';
import 'package:chatloom/personal/media/media_access.dart';
import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/client_download_content_extension.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import 'gif_search.dart';
import 'sticker_media_cache.dart';
import 'sticker_tile.dart' show stickerCacheName;

/// One GIF search result in the grid, as Telegram shows them: the blurred
/// inline preview at once, the static thumbnail once the bridge has it, and
/// a muted loop while the cell is on screen.
///
/// The loop follows the timeline's inline-loop rules: at least half
/// visible, tickers on (a hidden panel tab or route stops it), app resumed,
/// not suspended by the lock, "autoplay" on, no reduced motion; and it
/// shares the app-wide budget of native players ([InlineLoopSlots]). The
/// mp4 is only requested for a cell that gets a player.
class GifResultTile extends StatefulWidget {
  const GifResultTile({
    super.key,
    required this.result,
    required this.source,
    required this.room,
    required this.size,
    required this.onTap,
    required this.onLongPress,
    this.busy = false,
  });

  final GifSearchResult result;
  final GifSearchSource source;
  final Room room;
  final double size;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// Being prepared for sending (an inline spinner).
  final bool busy;

  /// Share of the cell that must be visible to play.
  static const visibleFraction = .5;

  /// Tests: creates the player from the downloaded media.
  @visibleForTesting
  static Future<VideoPlayerController> Function(GifMedia media)?
  debugCreatePlayer;

  /// Tests: overrides [PlatformInfos.supportsVideoPlayer].
  @visibleForTesting
  static bool? debugSupportsPlayback;

  @override
  State<GifResultTile> createState() => _GifResultTileState();
}

class _GifResultTileState extends State<GifResultTile>
    with WidgetsBindingObserver {
  late final RoundPlaybackHandle _handle;
  Uri? _thumbnail;
  VideoPlayerController? _player;
  ManagedMediaFile? _lease;
  int _generation = 0;
  bool _starting = false;
  bool _failed = false;
  bool _evicted = false;
  bool _visible = false;
  bool _viewportScheduled = false;
  ScrollPosition? _scrollPosition;
  bool _tickers = true;
  bool _routeCurrent = true;
  bool _reduced = false;
  bool _disposed = false;

  bool get _autoplayAllowed =>
      (GifResultTile.debugSupportsPlayback ??
          PlatformInfos.supportsVideoPlayer) &&
      widget.result.mimetype == 'video/mp4' &&
      !_reduced &&
      !_failed &&
      AppSettings.autoplayImages.value;

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
    _loadThumbnail();
  }

  void _loadThumbnail() {
    final result = widget.result;
    widget.source
        .media(widget.room, result)
        .then(
          (media) {
            if (!mounted || _disposed || widget.result != result) return;
            if (media.thumbnail != null && media.thumbnail != _thumbnail) {
              setState(() => _thumbnail = media.thumbnail);
            }
          },
          onError: (Object _) {
            // The inline preview stays; a tap still sends.
          },
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
  void didUpdateWidget(GifResultTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.result != widget.result) {
      _failed = false;
      _evicted = false;
      _thumbnail = null;
      unawaited(_release());
      _loadThumbnail();
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

  /// Post-frame viewport check (no layout work per scroll frame).
  void _scheduleViewport() {
    if (_viewportScheduled || !mounted) return;
    _viewportScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportScheduled = false;
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.hasSize || !box.attached) return;
      final bounds = box.localToGlobal(Offset.zero) & box.size;
      var viewportBounds = Offset.zero & MediaQuery.sizeOf(context);
      final viewport = RenderAbstractViewport.maybeOf(box);
      if (viewport is RenderBox) {
        final viewportBox = viewport as RenderBox;
        if (viewportBox.hasSize) {
          viewportBounds = viewportBounds.intersect(
            viewportBox.localToGlobal(Offset.zero) & viewportBox.size,
          );
        }
      }
      final overlap = bounds.intersect(viewportBounds);
      final visible =
          bounds.width > 0 &&
          bounds.height > 0 &&
          !overlap.isEmpty &&
          overlap.width * overlap.height / (bounds.width * bounds.height) >=
              GifResultTile.visibleFraction;
      if (!visible) _evicted = false;
      _visible = visible;
      _sync();
    });
  }

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
    if (!_visible || !_autoplayAllowed) {
      unawaited(_release());
    } else {
      unawaited(_pause());
    }
  }

  Future<VideoPlayerController> _createPlayer(int generation) async {
    final media = await widget.source.media(
      widget.room,
      widget.result,
      video: true,
    );
    if (generation != _generation) throw StateError('superseded');
    final custom = GifResultTile.debugCreatePlayer;
    if (custom != null) return custom(media);
    final uri = media.item?.uri;
    if (uri == null) throw StateError('no media');
    final bytes = await widget.room.client.downloadMxcCached(uri);
    if (generation != _generation) throw StateError('superseded');
    final options = VideoPlayerOptions(mixWithOthers: true);
    if (kIsWeb) {
      return VideoPlayerController.networkUrl(
        Uri.dataFromBytes(bytes, mimeType: 'video/mp4'),
        videoPlayerOptions: options,
      );
    }
    final tempDir = await getTemporaryDirectory();
    final access = await MediaAccess.open(
      directory: Directory('${tempDir.path}/personal_video'),
    );
    final lease = await access.create(bytes, extension: '.mp4');
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
        // The thumbnail stays; a tap still sends.
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
      // Released on the next check.
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

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _scrollPosition?.removeListener(_scheduleViewport);
    _handle.dispose();
    unawaited(_release());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    final preview = widget.result.preview;
    final thumbnail = _thumbnail;
    final player = _player;
    final playing = player != null && player.value.isInitialized;
    Widget blurred(BuildContext context) => preview != null
        ? Image.memory(
            preview,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
            errorBuilder: (context, _, _) => ColoredBox(color: colors.surface),
          )
        : ColoredBox(color: colors.surface);
    return Semantics(
      label: 'GIF',
      button: true,
      child: NotionTapTarget(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: ClipRRect(
          borderRadius: NotionRadius.smAll,
          child: Stack(
            fit: StackFit.expand,
            children: [
              blurred(context),
              if (thumbnail != null)
                MxcImage(
                  uri: thumbnail,
                  client: widget.room.client,
                  width: widget.size,
                  height: widget.size,
                  fit: BoxFit.cover,
                  cacheKey: thumbnail.toString(),
                  cacheName: stickerCacheName,
                  loadBytes: StickerMediaCache.loadMxc,
                  placeholder: blurred,
                  usePlaceholderOnError: true,
                  animationDuration: Duration.zero,
                ),
              if (playing)
                FittedBox(
                  fit: BoxFit.cover,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox.fromSize(
                    size: player.value.size.isEmpty
                        ? Size.square(widget.size)
                        : player.value.size,
                    child: VideoPlayer(player),
                  ),
                ),
              if (widget.busy)
                const ColoredBox(
                  color: NotionMediaColors.scrim,
                  child: Center(
                    child: NotionDelayedSpinner(
                      color: NotionMediaColors.onScrim,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

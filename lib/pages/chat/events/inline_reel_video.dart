// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/personal/hidden_messages.dart';
import 'package:chatloom/personal/media/cancellable_download.dart';
import 'package:chatloom/personal/media/media_access.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

/// Explicit-play reels. Shares the existing download, private-file and audible
/// coordination infrastructure; full screen borrows the same decoder/position.
class InlineReelVideo extends StatefulWidget {
  final Event event;
  final Event? original;
  final Widget? poster;
  final bool playOnMount;
  const InlineReelVideo({
    super.key,
    required this.event,
    this.original,
    this.poster,
    this.playOnMount = false,
  });

  @visibleForTesting
  static Future<VideoPlayerController> Function(Event)? debugCreatePlayer;

  @override
  State<InlineReelVideo> createState() => _InlineReelVideoState();
}

class _InlineReelVideoState extends State<InlineReelVideo>
    with WidgetsBindingObserver {
  VideoPlayerController? _player;
  ManagedMediaFile? _lease;
  MediaDownloadToken? _download;
  late final String? _owner = widget.event.room.client.userID;
  late final RoundPlaybackHandle _handle;
  final _changes = ValueNotifier(0);
  Route<void>? _stageRoute;
  StreamSubscription? _sync;
  ScrollPosition? _scroll;
  int _generation = 0;
  bool _busy = false, _failed = false, _expanded = false, _disposed = false;
  bool _viewportScheduled = false;
  bool _currentRoute = true, _tickers = true;
  Duration _position = Duration.zero;
  Event get _source => widget.original ?? widget.event;
  bool get _allowed =>
      _owner != null &&
      _source.room.client.userID == _owner &&
      !_source.redacted &&
      !HiddenMessages.hides(_source) &&
      PersonalPrivacy.surfaceUnlocked &&
      PersonalPrivacy.surfaceForeground;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _handle = RoundPlaybackCoordinator.shared.register(
      pause: _pause,
      stop: _release,
    );
    _sync = _source.room.client.onSync.stream.listen((_) {
      if (!_allowed) unawaited(_release());
    });
    HiddenMessages.instance.addListener(_visibility);
    if (widget.playOnMount) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_play());
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _currentRoute = ModalRoute.isCurrentOf(context) ?? true;
    _tickers = TickerMode.valuesOf(context).enabled;
    final scroll = Scrollable.maybeOf(context)?.position;
    if (scroll != _scroll) {
      _scroll?.removeListener(_visibility);
      _scroll = scroll;
      scroll?.addListener(_visibility);
    }
    _visibility();
  }

  void _visibility() {
    if (_viewportScheduled || _disposed) return;
    _viewportScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportScheduled = false;
      if (!mounted || _disposed) return;
      final box = context.findRenderObject();
      final visible =
          box is RenderBox &&
          NotionContentLoop.isVisible(box, MediaQuery.sizeOf(context));
      if (!_allowed ||
          (!_expanded && (!visible || !_currentRoute || !_tickers))) {
        unawaited(_release());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_release());
  }

  void _notify() {
    if (_disposed || !mounted) return;
    setState(() {});
    _changes.value++;
  }

  Future<void> _pause() async {
    await _player?.pause();
    _handle.releaseAudible();
  }

  Future<void> _release() async {
    ++_generation;
    _download?.cancel();
    _download = null;
    final player = _player;
    final lease = _lease;
    if (player != null) _position = player.value.position;
    _player = null;
    _lease = null;
    _busy = false;
    _handle.releaseAudible();
    _notify();
    try {
      // Native texture disposal can be delayed. Stop audio immediately.
      await player?.pause();
      await player?.dispose();
    } catch (_) {
      // A native player may already have been removed by the OS.
    } finally {
      await lease?.close();
    }
  }

  Future<void> _play() async {
    if (_busy || !_allowed || !_tickers || (!_currentRoute && !_expanded)) {
      return;
    }
    final existing = _player;
    if (existing != null) {
      try {
        if (existing.value.isPlaying) {
          await _pause();
        } else if (await _handle.acquireAudible() &&
            _handle.isCurrent &&
            _allowed) {
          if (existing.value.position >= existing.value.duration) {
            await existing.seekTo(Duration.zero);
          }
          if (_handle.isCurrent && identical(existing, _player)) {
            await existing.play();
          }
        }
      } catch (_) {
        await _release();
        _failed = true;
        _notify();
      }
      return;
    }
    final generation = ++_generation;
    _busy = true;
    _failed = false;
    _notify();
    VideoPlayerController? created;
    ManagedMediaFile? lease;
    bool current() =>
        mounted && !_disposed && generation == _generation && _allowed;
    try {
      if (!await _handle.acquireAudible() || !current() || !_handle.isCurrent) {
        return;
      }
      final custom = InlineReelVideo.debugCreatePlayer;
      if (custom != null) {
        created = await custom(widget.event);
      } else {
        final token = _download = MediaDownloadToken();
        final file = await downloadAttachmentCancellable(
          widget.event,
          token: token,
        );
        if (!current() || token.cancelled) return;
        if (kIsWeb) {
          created = VideoPlayerController.networkUrl(
            Uri.dataFromBytes(file.bytes, mimeType: file.mimeType),
          );
        } else {
          final temp = await getTemporaryDirectory();
          final access = await MediaAccess.open(
            directory: Directory('${temp.path}/personal_video'),
          );
          lease = await access.create(file.bytes, extension: '.mp4');
          created = VideoPlayerController.file(lease.file);
        }
      }
      if (!current() || !_handle.isCurrent) return;
      await created.initialize().timeout(const Duration(seconds: 30));
      if (!current() || !_handle.isCurrent) return;
      await created.seekTo(
        _position < created.value.duration ? _position : Duration.zero,
      );
      if (!current() || !_handle.isCurrent) return;
      _player = created;
      _lease = lease;
      created = null;
      lease = null;
      _busy = false;
      _notify();
      await _player!.play();
    } catch (_) {
      if (current()) _failed = true;
    } finally {
      await created?.dispose();
      await lease?.close();
      if (generation == _generation) {
        _busy = false;
        _download = null;
        if (_player == null) _handle.releaseAudible();
        _notify();
      }
    }
  }

  Future<void> _fullScreen() async {
    if (_expanded || _player == null) return;
    _expanded = true;
    try {
      final route = _stageRoute = NotionMediaRoute<void>(
        themes: InheritedTheme.capture(
          from: context,
          to: Navigator.of(context, rootNavigator: true).context,
        ),
        builder: (context) => ListenableBuilder(
          listenable: _changes,
          builder: (context, _) => Scaffold(
            backgroundColor: NotionMediaColors.viewer.withValues(alpha: 1),
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              leading: IconButton(
                tooltip: 'Close video',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            body: SafeArea(child: Center(child: _frame(fullScreen: true))),
          ),
        ),
      );
      await Navigator.of(context, rootNavigator: true).push<void>(route);
    } finally {
      _stageRoute = null;
      _expanded = false;
      _visibility();
      _notify();
      if (_disposed) _changes.dispose();
    }
  }

  Widget _frame({bool fullScreen = false}) {
    if (!_allowed || _disposed) {
      return const Center(child: Text('Media no longer available'));
    }
    final player = _player;
    if (player == null) {
      final poster =
          widget.poster ??
          (widget.event.hasThumbnail &&
                  AppSettings.showThumbnailsInTimeline.value
              ? MxcImage(
                  event: widget.event,
                  isThumbnail: true,
                  fit: BoxFit.cover,
                )
              : null);
      return Stack(
        alignment: Alignment.center,
        children: [
          if (poster != null) Positioned.fill(child: poster),
          Center(
            child: _busy
                ? const NotionDelayedSpinner()
                : IconButton(
                    tooltip: _failed ? 'Retry reel' : 'Play reel',
                    color: NotionMediaColors.onScrim,
                    onPressed: _allowed ? _play : null,
                    iconSize: NotionSize.iconLg,
                    icon: Icon(_failed ? Icons.refresh : Icons.play_arrow),
                  ),
          ),
        ],
      );
    }
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: player,
      builder: (context, value, _) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: value.aspectRatio,
                child: VideoPlayer(player),
              ),
            ),
          ),
          NotionMediaPlaybackControls(
            playing: value.isPlaying,
            position: value.position,
            duration: value.duration,
            speed: value.playbackSpeed,
            onToggle: _play,
            onSeek: (position) async {
              if (identical(player, _player) && _allowed) {
                await player.seekTo(position);
              }
            },
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: value.volume == 0 ? 'Unmute reel' : 'Mute reel',
                  onPressed: () => player.setVolume(value.volume == 0 ? 1 : 0),
                  icon: Icon(
                    value.volume == 0 ? Icons.volume_off : Icons.volume_up,
                  ),
                ),
                if (!fullScreen)
                  IconButton(
                    tooltip: 'Full screen',
                    onPressed: _fullScreen,
                    icon: const Icon(Icons.fullscreen),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final info = widget.event.content['info'];
      final frame = ConversationMedia.frame(
        maxWidth: constraints.maxWidth,
        width: info is Map && info['w'] is num ? info['w'] as num : null,
        height: info is Map && info['h'] is num ? info['h'] as num : null,
        maxHeight: ConversationMedia.maxHeightOf(context, constraints),
      );
      return ClipRRect(
        borderRadius: NotionRadius.mdAll,
        child: ColoredBox(
          color: NotionMediaColors.viewer.withValues(alpha: 1),
          child: SizedBox(
            width: frame.width,
            height: frame.height,
            child: _expanded
                ? const Center(
                    child: Icon(
                      Icons.fullscreen,
                      color: NotionMediaColors.onScrim,
                    ),
                  )
                : _frame(),
          ),
        ),
      );
    },
  );

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    HiddenMessages.instance.removeListener(_visibility);
    _scroll?.removeListener(_visibility);
    unawaited(_sync?.cancel());
    _handle.dispose();
    unawaited(_release());
    final stage = _stageRoute;
    if (stage == null) {
      _changes.dispose();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (stage.isActive && stage.navigator?.mounted == true) {
          stage.navigator!.removeRoute(stage);
        }
      });
    }
    super.dispose();
  }
}

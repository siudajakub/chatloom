// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:typed_data';

import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/personal/round_video/round_media_loader.dart';
import 'package:fluffychat/personal/round_video/round_playback_coordinator.dart';
import 'package:fluffychat/personal/round_video/round_playback_receipts.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:video_player/video_player.dart';

import 'round_mini_player.dart';
import 'round_video_view.dart';

/// A strict round renderer. Download/receipt decisions stay outside the view.
/// Neither dimensions nor filename can turn ordinary video into a round note.
class RoundVideoMessage extends StatefulWidget {
  final Event event;
  final Color? textColor;
  final RoundMediaLoader? loader;
  final RoundPlaybackCoordinator? coordinator;
  final RoundPlaybackReceipts? receipts;
  final bool allowMutedAutoplay, isVisible, mediaUnread, showThumbnail;
  final bool isExpired, sourceStatePending, sourceStateUnavailable;
  final bool Function()? sourceAvailable;
  final List<Event> continuationQueue;
  final Future<void> Function(Event)? onForward, onExport, onTranscribe;
  const RoundVideoMessage(
    this.event, {
    super.key,
    this.textColor,
    this.loader,
    this.coordinator,
    this.receipts,
    this.allowMutedAutoplay = false,
    this.isVisible = true,
    this.mediaUnread = false,
    this.showThumbnail = true,
    this.isExpired = false,
    this.sourceStatePending = false,
    this.sourceStateUnavailable = false,
    this.sourceAvailable,
    this.continuationQueue = const [],
    this.onForward,
    this.onExport,
    this.onTranscribe,
  });

  @override
  State<RoundVideoMessage> createState() => _RoundVideoMessageState();
}

class _RoundVideoMessageState extends State<RoundVideoMessage>
    with WidgetsBindingObserver {
  late RoundPlaybackCoordinator _coordinator;
  late RoundPlaybackHandle _handle;
  late RoundMediaLoader _loader;
  RoundLoadedMedia? _media;
  RoundMediaCancellation? _request;
  RoundMediaCancellation? _thumbnailRequest;
  Uint8List? _thumbnail;
  VideoPlayerController? _player;
  int _generation = 0;
  bool _loading = false, _userStarted = false, _locallyPlayed = false;
  bool _receiptAttempted = false, _reporting = false;
  double? _downloadProgress;
  String? _error;
  double _speed = 1;
  RoundPlaybackIntent _playIntent = RoundPlaybackIntent();
  late List<Event> _queue;
  bool _continuing = false;
  bool _starting = false;
  static _RoundVideoMessageState? _previewOwner;
  bool _viewportVisible = false,
      _viewportScheduled = false,
      _controllerMixes = false;
  ScrollPosition? _scrollPosition;

  bool get _available =>
      mounted &&
      PersonalPrivacy.surfaceUnlocked &&
      !_coordinator.suspended &&
      !widget.isExpired &&
      !widget.sourceStatePending &&
      !widget.sourceStateUnavailable &&
      (widget.sourceAvailable?.call() ?? true) &&
      RoundMediaLoader.isRound(widget.event) &&
      RoundMediaLoader.policyFor(widget.event).canPlay;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loader = widget.loader ?? RoundMediaLoader();
    _coordinator = widget.coordinator ?? RoundPlaybackCoordinator.shared;
    _handle = _coordinator.register(pause: _pause, stop: _stop);
    _queue = List.unmodifiable(widget.continuationQueue);
    if (_available) {
      _restoreMini();
    }
    _maybeThumbnail();
    _maybeAutoplay();
  }

  void _maybeThumbnail() {
    if (_player != null ||
        _thumbnail != null ||
        _thumbnailRequest != null ||
        !widget.showThumbnail ||
        !widget.isVisible ||
        !RoundMediaLoader.policyFor(widget.event).canPersist) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!_available ||
          _thumbnail != null ||
          _thumbnailRequest != null ||
          !widget.showThumbnail ||
          !widget.isVisible) {
        return;
      }
      final generation = _generation;
      final event = widget.event;
      final request = _thumbnailRequest = RoundMediaCancellation(
        sourceValid: () =>
            _available &&
            generation == _generation &&
            identical(event, widget.event),
      );
      try {
        final thumbnail = await _loader.thumbnail(event, cancellation: request);
        if (mounted && request.valid) setState(() => _thumbnail = thumbnail);
      } catch (_) {
        /* Thumbnail failure leaves the playable placeholder. */
      } finally {
        if (identical(_thumbnailRequest, request)) _thumbnailRequest = null;
      }
    });
  }

  bool _restoreMini() {
    final session = RoundMiniPlayerController.shared.takeFor(widget.event);
    if (session == null) return false;
    _handle.dispose();
    _handle = session.handle!..rebind(pause: _pause, stop: _stop);
    _player = session.video;
    _media = session.media;
    _playIntent = session.intent;
    _queue = session.queue;
    _locallyPlayed = session.locallyPlayed;
    _receiptAttempted = session.receiptAttempted;
    _speed = session.speed;
    _userStarted = session.userInitiated;
    _player?.addListener(_onPlayerChanged);
    return true;
  }

  void _transferToMini({bool replaceHandle = true}) {
    final player = _player;
    if (player == null || _media == null) return;
    player.removeListener(_onPlayerChanged);
    final session = RoundDetachedPlayback(
      event: widget.event,
      video: player,
      media: _media,
      handle: _handle,
      intent: _playIntent,
      queue: _queue,
      speed: _speed,
      userInitiated: _userStarted,
      locallyPlayed: _locallyPlayed,
      receiptAttempted: _receiptAttempted,
    );
    _player = null;
    _media = null;
    _playIntent = RoundPlaybackIntent();
    RoundMiniPlayerController.shared.adopt(session);
    if (replaceHandle) {
      _handle = _coordinator.register(pause: _pause, stop: _stop);
    }
  }

  Future<void> _continueAfterCompletion() async {
    if (_continuing) return;
    _continuing = true;
    _transferToMini();
    if (mounted) setState(() {});
    try {
      await RoundMiniPlayerController.shared.advance();
    } finally {
      _continuing = false;
    }
  }

  void _maybeAutoplay() {
    if (!widget.allowMutedAutoplay ||
        !widget.isVisible ||
        _player == null ||
        _media == null ||
        !RoundMediaLoader.policyFor(widget.event).canPersist) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || MediaQuery.disableAnimationsOf(context)) return;
      if (_available &&
          widget.allowMutedAutoplay &&
          _viewportVisible &&
          !_handle.isCurrent &&
          (_previewOwner == null || _previewOwner == this)) {
        if (_player?.value.isPlaying == true) return;
        _previewOwner = this;
        unawaited(_start(userInitiated: false));
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (_scrollPosition != position) {
      _scrollPosition?.removeListener(_scheduleViewport);
      _scrollPosition = position;
      position?.addListener(_scheduleViewport);
    }
    _scheduleViewport();
  }

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
      _viewportVisible =
          widget.isVisible &&
          bounds.width > 0 &&
          bounds.height > 0 &&
          !overlap.isEmpty &&
          overlap.width * overlap.height / (bounds.width * bounds.height) >= .6;
      if (MediaQuery.disableAnimationsOf(context) &&
          _previewOwner == this &&
          !_handle.isCurrent) {
        unawaited(_stop());
      } else if (_viewportVisible) {
        _maybeAutoplay();
      } else if (!_handle.isCurrent &&
          (_previewOwner == this || _player?.value.volume == 0)) {
        unawaited(_stop());
      }
    });
  }

  VideoPlayerController _newPlayer(
    RoundLoadedMedia media, {
    required bool muted,
  }) {
    _controllerMixes = muted;
    final options = VideoPlayerOptions(mixWithOthers: muted);
    return media.lease != null
        ? VideoPlayerController.file(
            media.lease!.file,
            videoPlayerOptions: options,
          )
        : VideoPlayerController.networkUrl(
            media.dataUri!,
            videoPlayerOptions: options,
          );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_stop());
  }

  @override
  void didUpdateWidget(RoundVideoMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event.eventId != widget.event.eventId ||
        !identical(oldWidget.event.room.client, widget.event.room.client) ||
        oldWidget.event.room.id != widget.event.room.id ||
        oldWidget.event.attachmentMxcUrl != widget.event.attachmentMxcUrl ||
        !_available) {
      unawaited(
        _stop().then((_) {
          if (mounted) {
            _maybeThumbnail();
            _maybeAutoplay();
          }
        }),
      );
      _locallyPlayed = false;
      _receiptAttempted = false;
    } else if ((oldWidget.sourceStatePending ||
            oldWidget.sourceStateUnavailable) &&
        !widget.sourceStatePending &&
        !widget.sourceStateUnavailable) {
      _restoreMini();
      _maybeThumbnail();
      _maybeAutoplay();
    }
  }

  Future<void> _toggle() async {
    if (!_available) return;
    if (_player?.value.isPlaying == true && _handle.isCurrent) {
      await _pause();
      _handle.releaseAudible();
      return;
    }
    await _start(userInitiated: true);
  }

  Future<void> _start({required bool userInitiated}) async {
    if (!_available || _loading || _starting) return;
    // Scrolling may preview an already opened clip, but must never fetch its
    // full encrypted attachment or initialize a codec just to show the row.
    if (!userInitiated && (!_viewportVisible || _player == null)) return;
    if (userInitiated && _previewOwner == this) _previewOwner = null;
    _starting = true;
    final generation = _generation;
    final event = widget.event;
    try {
      if (userInitiated && !await _handle.acquireAudible()) return;
      if (!_available ||
          generation != _generation ||
          (userInitiated && !_handle.isCurrent)) {
        return;
      }
      var player = _player;
      if (player == null) {
        setState(() {
          _loading = true;
          _error = null;
          _downloadProgress = null;
        });
        final request = _request = RoundMediaCancellation(
          sourceValid: () =>
              _available &&
              (userInitiated || _viewportVisible) &&
              (!userInitiated || _handle.isCurrent) &&
              generation == _generation &&
              identical(event, widget.event),
        );
        final media = await _loader.load(
          event,
          cancellation: request,
          onProgress: (progress) {
            if (!mounted || generation != _generation) return;
            setState(() => _downloadProgress = progress);
          },
        );
        if (!request.valid) {
          await media.close();
          return;
        }
        _media = media;
        player = _newPlayer(media, muted: !userInitiated);
        _player = player;
        player.addListener(_onPlayerChanged);
        await player.initialize();
        if (!request.valid || !identical(player, _player)) {
          if (identical(player, _player)) await _disposePlayer();
          return;
        }
        await player.setLooping(false);
        await player.setPlaybackSpeed(_speed);
      }
      if (userInitiated && _controllerMixes && _media != null) {
        setState(() => _loading = true);
        final position = player.value.position;
        player.removeListener(_onPlayerChanged);
        await player.pause();
        await player.dispose();
        if (!_available || generation != _generation) return;
        player = _player = _newPlayer(_media!, muted: false);
        player.addListener(_onPlayerChanged);
        await player.initialize();
        if (!_available ||
            generation != _generation ||
            !identical(player, _player)) {
          return;
        }
        await player.setPlaybackSpeed(_speed);
        await player.seekTo(position);
      }
      if (!_available || generation != _generation) return;
      if (!_available ||
          generation != _generation ||
          (!userInitiated && !_viewportVisible) ||
          (userInitiated && !_handle.isCurrent)) {
        return;
      }
      if (player.value.position >= player.value.duration) {
        await player.seekTo(Duration.zero);
      }
      await player.setVolume(userInitiated ? 1 : 0);
      if (!_available ||
          generation != _generation ||
          (userInitiated && !_handle.isCurrent)) {
        return;
      }
      _userStarted = userInitiated;
      _playIntent.begin(
        position: player.value.position,
        userInitiated: userInitiated,
      );
      await player.play();
    } catch (_) {
      if (generation != _generation) return;
      await _disposePlayer();
      _handle.releaseAudible();
      if (mounted) {
        setState(() => _error = 'Playback failed. Try again.');
      }
    } finally {
      if (!userInitiated &&
          _player?.value.isPlaying != true &&
          _previewOwner == this) {
        _previewOwner = null;
      }
      if (generation == _generation) {
        _starting = false;
        if (mounted) setState(() => _loading = false);
      }
    }
  }

  void _onPlayerChanged() {
    final player = _player;
    if (!mounted || player == null) return;
    if (!_available) {
      unawaited(_stop());
      return;
    }
    if (player.value.hasError) {
      _error = 'Playback was interrupted. Try again.';
      unawaited(_stop());
      return;
    }
    // Playing state alone can precede decoding the first frame. Position must
    // advance beyond this user-started play; autoplay never creates receipts.
    if (_playIntent.didAdvance(
      position: player.value.position,
      isPlaying: player.value.isPlaying,
      audiblePermit: _handle.isCurrent,
    )) {
      _locallyPlayed = true;
      final receipts = widget.receipts;
      if (!_receiptAttempted && receipts != null && !receipts.incognito) {
        _receiptAttempted = true;
        unawaited(
          receipts.onUserStartedPlaying(widget.event).catchError((Object _) {}),
        );
      }
    }
    if (player.value.isCompleted ||
        (!player.value.isPlaying &&
            player.value.position >= player.value.duration)) {
      if (_queue.isNotEmpty && _handle.isCurrent && !_continuing) {
        unawaited(_continueAfterCompletion());
        return;
      }
      _handle.releaseAudible();
    }
    setState(() {});
  }

  Future<void> _pause() async {
    _userStarted = false;
    _playIntent.pause();
    await _player?.pause();
    if (mounted) setState(() {});
  }

  Future<void> _disposePlayer() async {
    final player = _player;
    final media = _media;
    _player = null;
    _media = null;
    player?.removeListener(_onPlayerChanged);
    try {
      await player?.dispose();
    } finally {
      await media?.close();
    }
  }

  Future<void> _stop() async {
    ++_generation;
    _request?.cancel();
    _request = null;
    _thumbnailRequest?.cancel();
    _thumbnailRequest = null;
    _thumbnail = null;
    _starting = false;
    if (_previewOwner == this) _previewOwner = null;
    _userStarted = false;
    _playIntent.pause();
    _handle.releaseAudible();
    await _disposePlayer();
    if (mounted) {
      setState(() {
        _loading = false;
        _downloadProgress = null;
      });
    }
  }

  Future<void> _seek(Duration position) async {
    if (!_available) return;
    _playIntent.begin(position: position, userInitiated: _userStarted);
    try {
      await _player?.seekTo(position);
    } catch (_) {}
  }

  Future<void> _setSpeed(double value) async {
    if (!_available) return;
    _speed = value.clamp(.2, 3.0);
    try {
      await _player?.setPlaybackSpeed(_speed);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _reportPlayed() async {
    final receipts = widget.receipts;
    if (!_available ||
        !_locallyPlayed ||
        receipts == null ||
        _reporting ||
        !receipts.canExplicitlyReport(widget.event)) {
      return;
    }
    setState(() => _reporting = true);
    try {
      await receipts.explicitlyReportPlayed(widget.event);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Playback receipt was not sent.');
      }
    } finally {
      if (mounted) setState(() => _reporting = false);
    }
  }

  Future<void> _action(Future<void> Function(Event) callback) async {
    if (!_available) return;
    try {
      await callback(widget.event);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'This action could not be completed.');
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollPosition?.removeListener(_scheduleViewport);
    if (_previewOwner == this) _previewOwner = null;
    if (_player?.value.isPlaying == true && _handle.isCurrent && _available) {
      _transferToMini(replaceHandle: false);
    } else {
      _handle.dispose();
    }
    ++_generation;
    _request?.cancel();
    _thumbnailRequest?.cancel();
    _thumbnail = null;
    unawaited(_disposePlayer().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final policy = RoundMediaLoader.policyFor(event);
    final descriptor = RoundVideoDescriptor.fromContent(
      event.content,
      redacted: event.redacted,
    );
    String? blockedReason;
    if (widget.isExpired) {
      blockedReason = 'This message has expired.';
    } else if (widget.sourceStatePending) {
      blockedReason = 'Checking message availability…';
    } else if (widget.sourceStateUnavailable) {
      blockedReason =
          'Message availability could not be verified. Reopen the conversation.';
    } else if (!policy.canPlay) {
      blockedReason = policy.isTimeLimited
          ? 'View-once or timed messages are not supported yet.'
          : policy.protectedContent
          ? 'Protected content is not supported yet.'
          : 'This message cannot be opened safely.';
    } else if (descriptor == null || event.type != EventTypes.Message) {
      blockedReason = 'This round video is unavailable.';
    }
    if (blockedReason != null && (_player != null || _loading)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_stop());
      });
    }
    final player = blockedReason == null ? _player : null;
    final receipts = widget.receipts;
    return RoundVideoView(
      textColor: widget.textColor,
      blockedReason: blockedReason,
      video: player?.value.isInitialized == true
          ? FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: player!.value.size.width,
                height: player.value.size.height,
                child: VideoPlayer(player),
              ),
            )
          : blockedReason == null && _thumbnail != null
          ? Image.memory(_thumbnail!, fit: BoxFit.cover, gaplessPlayback: false)
          : null,
      playing: player?.value.isPlaying == true && _handle.isCurrent,
      loading: blockedReason == null && _loading,
      downloadProgress: _downloadProgress,
      position: player?.value.position ?? Duration.zero,
      duration:
          player?.value.duration ??
          Duration(milliseconds: descriptor?.durationMs ?? 0),
      speed: _speed,
      mediaUnread: widget.mediaUnread && !_locallyPlayed,
      error: _error,
      onToggle: _toggle,
      onCancel: _stop,
      onSeek: player == null ? null : _seek,
      onSpeedChanged: _setSpeed,
      onReportPlayed:
          _locallyPlayed &&
              receipts != null &&
              receipts.incognito &&
              !_reporting &&
              receipts.canExplicitlyReport(event)
          ? _reportPlayed
          : null,
      actions: [
        if (policy.canForward && widget.onForward != null)
          IconButton(
            tooltip: 'Forward in Telegram',
            onPressed: () => _action(widget.onForward!),
            icon: const Icon(Icons.forward_outlined),
          ),
        if (policy.canExport && widget.onExport != null)
          IconButton(
            tooltip: 'Save round video',
            onPressed: () => _action(widget.onExport!),
            icon: const Icon(Icons.download_outlined),
          ),
        if (policy.canTranscribe && widget.onTranscribe != null)
          IconButton(
            tooltip: 'Transcribe',
            onPressed: () => _action(widget.onTranscribe!),
            icon: const Icon(Icons.transcribe_outlined),
          ),
      ],
    );
  }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:typed_data';

import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/personal/round_video/round_media_loader.dart';
import 'package:fluffychat/personal/round_video/round_playback_coordinator.dart';
import 'package:fluffychat/personal/round_video/round_playback_receipts.dart';
import 'package:fluffychat/utils/bounded_byte_cache.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:video_player/video_player.dart';

import 'round_mini_player.dart';
import 'round_video_stage.dart';
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

  /// Evaluated only when the user starts playback (never per build).
  final List<Event> Function()? continuationQueue;
  final Future<void> Function(Event)? onForward, onExport, onTranscribe;

  /// Side of the conversation; the action column faces the screen centre.
  final bool outgoing;

  /// Time/edited/sending pill drawn on the circle (from `Message`).
  final Widget? statusOverlay;

  /// Content under the circle, e.g. the transcript.
  final Widget? below;

  /// Starting audible playback enlarges the round on [RoundStageController].
  final bool enlargeOnPlay;
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
    this.continuationQueue,
    this.onForward,
    this.onExport,
    this.onTranscribe,
    this.outgoing = false,
    this.statusOverlay,
    this.below,
    this.enlargeOnPlay = true,
  });

  /// Decoded-on-demand thumbnail bytes keyed by account, source and mxc, so
  /// scrolling back to a round never refetches/decrypts its thumbnail.
  static final _thumbnailCache = BoundedByteCache<String>(
    maxBytes: 16 * 1024 * 1024,
    maxEntries: 256,
  );

  static String? _thumbnailKey(Event event) {
    final mxc = event.thumbnailMxcUrl ?? event.attachmentMxcUrl;
    if (mxc == null) return null;
    return '${identityHashCode(event.room.client)}|${event.room.id}|'
        '${event.eventId}|$mxc';
  }

  @visibleForTesting
  static void clearThumbnailCache() => _thumbnailCache.removeWhere((_) => true);

  /// Test seam replacing the platform controller of a row. A controller whose
  /// options mix with others is treated as a muted preview controller.
  @visibleForTesting
  static VideoPlayerController Function(
    RoundLoadedMedia media, {
    required bool muted,
  })?
  debugCreatePlayer;

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
  List<Event> _queue = const [];
  bool _continuing = false;
  bool _starting = false;
  bool _staged = false;
  final _circleKey = GlobalKey();
  static _RoundVideoMessageState? _previewOwner;

  /// Rows holding an initialized controller. Starting a new one stops the
  /// idle others, so at most one row controller (plus the mini player) exists.
  static final _withPlayer = <_RoundVideoMessageState>{};
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

  /// Same attachment of the same message. Rows routinely receive a fresh
  /// [Event] instance for an unchanged source (an edited message's display
  /// event is rebuilt on every timeline build, the SDK replaces events on
  /// sync/decryption updates), so instance identity must not cancel a load.
  static bool _sameSource(Event a, Event b) =>
      identical(a, b) ||
      (identical(a.room.client, b.room.client) &&
          a.room.id == b.room.id &&
          a.eventId == b.eventId &&
          a.attachmentMxcUrl == b.attachmentMxcUrl);

  /// A codec that never reports `initialized` must not spin forever.
  static const _initializeTimeout = Duration(seconds: 20);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loader = widget.loader ?? RoundMediaLoader();
    _coordinator = widget.coordinator ?? RoundPlaybackCoordinator.shared;
    _handle = _coordinator.register(pause: _pause, stop: _stop);
    RoundStageController.shared.addListener(_onStageChanged);
    if (_available) {
      _restoreMini();
    }
    _cachedThumbnail();
    _maybeThumbnail();
    _maybeAutoplay();
  }

  bool get _thumbnailAllowed =>
      widget.showThumbnail &&
      !widget.isExpired &&
      !widget.sourceStateUnavailable &&
      RoundMediaLoader.policyFor(widget.event).canPersist;

  /// Memory hit only: no download, decrypt or media-state wait.
  void _cachedThumbnail() {
    if (_thumbnail != null || !_thumbnailAllowed) return;
    final key = RoundVideoMessage._thumbnailKey(widget.event);
    if (key != null) _thumbnail = RoundVideoMessage._thumbnailCache.get(key);
  }

  void _onStageChanged() {
    final staged = RoundStageController.shared.isStaged(_player);
    if (staged != _staged && mounted) setState(() => _staged = staged);
  }

  /// Queried by the stage while it builds; a row mid-relayout (e.g. a new
  /// message shifting the list) must degrade to the centred flight, never
  /// throw into the stage build.
  Rect? _circleRect() {
    if (!mounted) return null;
    try {
      final box = _circleKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) return null;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      return rect.isFinite && !rect.isEmpty ? rect : null;
    } catch (_) {
      return null;
    }
  }

  bool get _canReportPlayed {
    final receipts = widget.receipts;
    return _available &&
        _locallyPlayed &&
        receipts != null &&
        receipts.incognito &&
        !_reporting &&
        receipts.canExplicitlyReport(widget.event);
  }

  RoundStageActions _stageActions() {
    final policy = RoundMediaLoader.policyFor(widget.event);
    final export = widget.onExport;
    final forward = widget.onForward;
    return RoundStageActions(
      toggle: _toggle,
      seek: _seek,
      setSpeed: _setSpeed,
      stop: _stop,
      save: policy.canExport && export != null ? () => _action(export) : null,
      forward: policy.canForward && forward != null
          ? () => _action(forward)
          : null,
      reportPlayed: _reportPlayed,
      canReportPlayed: () => _canReportPlayed,
      sourceRect: _circleRect,
      thumbnail: () => _thumbnail,
    );
  }

  void _present() {
    final player = _player;
    if (!mounted || player == null || !widget.enlargeOnPlay) return;
    RoundStageController.shared.present(
      context,
      video: player,
      actions: _stageActions(),
    );
  }

  void _stopOtherPlayers() {
    for (final other in _withPlayer.toList()) {
      if (identical(other, this) ||
          other._player == null ||
          other._handle.isCurrent ||
          RoundStageController.shared.isStaged(other._player)) {
        continue;
      }
      unawaited(other._stop());
    }
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
            _sameSource(event, widget.event),
      );
      try {
        final thumbnail = await _loader.thumbnail(event, cancellation: request);
        final key = RoundVideoMessage._thumbnailKey(event);
        if (thumbnail != null && key != null && request.valid) {
          RoundVideoMessage._thumbnailCache.put(key, thumbnail);
        }
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
    _withPlayer.add(this);
    final video = _player;
    if (video != null) {
      RoundStageController.shared.rebind(video, _stageActions());
      _staged = RoundStageController.shared.isStaged(video);
    }
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
    _withPlayer.remove(this);
    _playIntent = RoundPlaybackIntent();
    // The mini player rebinds a staged controller to its own callbacks.
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
    _syncViewportListener();
  }

  /// Muted previews are the only consumer of viewport tracking; without
  /// them no per-row scroll listener or post-frame geometry work exists.
  void _syncViewportListener() {
    final position = widget.allowMutedAutoplay
        ? Scrollable.maybeOf(context)?.position
        : null;
    if (_scrollPosition != position) {
      _scrollPosition?.removeListener(_scheduleViewport);
      _scrollPosition = position;
      position?.addListener(_scheduleViewport);
    }
    if (widget.allowMutedAutoplay) _scheduleViewport();
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
    final custom = RoundVideoMessage.debugCreatePlayer;
    if (custom != null) {
      final player = custom(media, muted: muted);
      _controllerMixes = player.videoPlayerOptions?.mixWithOthers ?? muted;
      return player;
    }
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
    if (state != AppLifecycleState.resumed) {
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.detached) {
        RoundVideoMessage.clearThumbnailCache();
      }
      unawaited(_stop());
    }
  }

  @override
  void didHaveMemoryPressure() => RoundVideoMessage.clearThumbnailCache();

  bool get _busy =>
      _player != null ||
      _loading ||
      _starting ||
      _request != null ||
      _thumbnailRequest != null;

  @override
  void didUpdateWidget(RoundVideoMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.allowMutedAutoplay != widget.allowMutedAutoplay) {
      _syncViewportListener();
    }
    final sourceChanged =
        oldWidget.event.eventId != widget.event.eventId ||
        !identical(oldWidget.event.room.client, widget.event.room.client) ||
        oldWidget.event.room.id != widget.event.room.id ||
        oldWidget.event.attachmentMxcUrl != widget.event.attachmentMxcUrl;
    if (sourceChanged || !_available) {
      if (sourceChanged) _thumbnail = null;
      // Pending/unavailable rows rebuild often; only stop real work.
      if (sourceChanged || _busy) {
        unawaited(
          _stop().then((_) {
            if (mounted) {
              _cachedThumbnail();
              _maybeThumbnail();
              _maybeAutoplay();
            }
          }),
        );
      }
      _locallyPlayed = false;
      _receiptAttempted = false;
    } else if ((oldWidget.sourceStatePending ||
            oldWidget.sourceStateUnavailable) &&
        !widget.sourceStatePending &&
        !widget.sourceStateUnavailable) {
      _restoreMini();
      _cachedThumbnail();
      _maybeThumbnail();
      _maybeAutoplay();
    } else if (_staged) {
      final video = _player;
      if (video != null) {
        RoundStageController.shared.rebind(video, _stageActions());
      }
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
    if (userInitiated) {
      _queue = List.unmodifiable(
        widget.continuationQueue?.call() ?? const <Event>[],
      );
    }
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
        if (userInitiated) _stopOtherPlayers();
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
              _sameSource(event, widget.event),
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
        _withPlayer.add(this);
        player.addListener(_onPlayerChanged);
        await player.initialize().timeout(_initializeTimeout);
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
        final mixing = player;
        mixing.removeListener(_onPlayerChanged);
        RoundStageController.shared.release(mixing);
        // Detach before awaiting: no frame, stage or stop may reach a
        // controller that is being disposed. The lease stays in [_media].
        _player = null;
        _staged = false;
        try {
          await mixing.pause();
        } catch (_) {
          /* Disposing releases it either way. */
        } finally {
          await mixing.dispose();
        }
        // A stop in between bumped the generation and released the lease.
        if (generation != _generation) return;
        final media = _media;
        if (!_available || media == null) {
          await _disposePlayer();
          return;
        }
        final audible = _newPlayer(media, muted: false);
        player = _player = audible;
        audible.addListener(_onPlayerChanged);
        await audible.initialize().timeout(_initializeTimeout);
        if (!identical(audible, _player)) return;
        if (!_available || generation != _generation) {
          if (generation == _generation) await _disposePlayer();
          return;
        }
        await audible.setPlaybackSpeed(_speed);
        await audible.seekTo(position);
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
      if (userInitiated &&
          mounted &&
          identical(player, _player) &&
          _handle.isCurrent &&
          generation == _generation) {
        _present();
      }
    } catch (_) {
      if (generation != _generation) return;
      // Show the retry state now; a native dispose may take a while.
      unawaited(_disposePlayer().catchError((Object _) {}));
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
      setState(() => _error = 'Playback was interrupted. Try again.');
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
    _withPlayer.remove(this);
    _staged = false;
    if (player != null) {
      // Before dispose: no stage widget may touch a disposed controller.
      RoundStageController.shared.release(player);
      player.removeListener(_onPlayerChanged);
    }
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
    // The thumbnail stays: stopping must not flash the placeholder.
    _starting = false;
    if (_previewOwner == this) _previewOwner = null;
    _userStarted = false;
    _playIntent.pause();
    _handle.releaseAudible();
    // [_disposePlayer] detaches synchronously; the row leaves its loading
    // state at once instead of after the native player has been released.
    final disposing = _disposePlayer();
    if (mounted) {
      setState(() {
        _loading = false;
        _downloadProgress = null;
      });
    }
    await disposing;
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
    RoundStageController.shared.removeListener(_onStageChanged);
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
    _withPlayer.remove(this);
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
    // Pending keeps the normal frame (stable row height) with play disabled.
    final pending = blockedReason == null && widget.sourceStatePending;
    if ((blockedReason != null || pending) && (_player != null || _loading)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_stop());
      });
    }
    final player = blockedReason == null && !pending ? _player : null;
    // While enlarged the stage renders the only texture for this controller.
    final staged = player != null && _staged;
    final value = player?.value;
    return RoundVideoView(
      circleKey: _circleKey,
      textColor: widget.textColor,
      outgoing: widget.outgoing,
      blockedReason: blockedReason,
      pending: pending,
      statusOverlay: widget.statusOverlay,
      below: widget.below,
      video: value?.isInitialized == true && !staged
          ? FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: value!.size.width,
                height: value.size.height,
                child: VideoPlayer(player!),
              ),
            )
          : null,
      thumbnail: blockedReason == null ? _thumbnail : null,
      playing: value?.isPlaying == true && _handle.isCurrent,
      muted: value?.isPlaying == true && value!.volume == 0,
      loading: blockedReason == null && !pending && _loading,
      downloadProgress: _downloadProgress,
      position: value?.position ?? Duration.zero,
      duration:
          value?.duration ??
          Duration(milliseconds: descriptor?.durationMs ?? 0),
      speed: _speed,
      mediaUnread: widget.mediaUnread && !_locallyPlayed,
      error: _error,
      onToggle: _toggle,
      onCancel: _stop,
      onReportPlayed: _canReportPlayed ? _reportPlayed : null,
      actions: [
        if (policy.canExport && widget.onExport != null)
          RoundSideAction(
            tooltip: 'Save round video',
            onPressed: () => _action(widget.onExport!),
            icon: Icons.download_outlined,
          ),
        if (policy.canForward && widget.onForward != null)
          RoundSideAction(
            tooltip: 'Forward in Telegram',
            onPressed: () => _action(widget.onForward!),
            icon: Icons.forward_outlined,
          ),
        if (policy.canTranscribe && widget.onTranscribe != null)
          RoundSideAction(
            tooltip: 'Transcribe',
            onPressed: () => _action(widget.onTranscribe!),
            icon: Icons.transcribe_outlined,
          ),
      ],
    );
  }
}

// SPDX-License-Identifier: AGPL-3.0-or-later

/// Native players can acknowledge play before rendering a frame, and a seek
/// can leave a positive position while paused. Played intent needs new progress
/// after this explicit audible start, not only a positive position or autoplay.
class RoundPlaybackIntent {
  Duration _start = Duration.zero;
  bool _userInitiated = false;
  void begin({required Duration position, required bool userInitiated}) {
    _start = position;
    _userInitiated = userInitiated;
  }

  void pause() => _userInitiated = false;
  bool didAdvance({
    required Duration position,
    required bool isPlaying,
    required bool audiblePermit,
  }) => _userInitiated && isPlaying && audiblePermit && position > _start;
}

/// Serializes audible playback across round, voice and ordinary video players.
/// A permit must be checked after asynchronous preparation and before play().
class RoundPlaybackCoordinator {
  static final shared = RoundPlaybackCoordinator();
  final Set<RoundPlaybackHandle> _players = {};
  Future<void> _queue = Future<void>.value();
  RoundPlaybackHandle? _audible;
  int _generation = 0;
  bool _suspended = false;
  bool _stopFailed = false;

  bool get suspended => _suspended;

  RoundPlaybackHandle register({
    required Future<void> Function() pause,
    required Future<void> Function() stop,
  }) {
    final handle = RoundPlaybackHandle._(this, pause, stop);
    _players.add(handle);
    return handle;
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<bool> _activate(RoundPlaybackHandle handle) {
    final generation = ++_generation;
    return _serial(() async {
      if (_suspended || handle._closed || generation != _generation) {
        return false;
      }
      final previous = _audible;
      // A failed pause cannot grant another audible player.
      if (previous != null && previous != handle && !previous._closed) {
        await previous._pause();
      }
      _audible = null;
      if (_suspended || handle._closed || generation != _generation) {
        return false;
      }
      _audible = handle;
      handle._permit = generation;
      return true;
    });
  }

  /// Call on app lock, background, audio interruption or account switch.
  /// Invalidates pending downloads immediately, before awaiting codec cleanup.
  Future<void> stopAll({bool suspend = true}) {
    ++_generation;
    _suspended = suspend;
    _audible = null;
    return _serial(() async {
      Object? firstError;
      StackTrace? firstStack;
      for (final player in List<RoundPlaybackHandle>.from(_players)) {
        if (player._closed) continue;
        try {
          await player._stop();
        } catch (error, stack) {
          firstError ??= error;
          firstStack ??= stack;
        }
      }
      if (firstError != null) {
        _stopFailed = true;
        _suspended = true;
        Error.throwWithStackTrace(firstError, firstStack!);
      }
      _stopFailed = false;
    });
  }

  /// Returning to foreground/unlocking permits a new explicit play action.
  /// This method never resumes a player or flushes a played receipt.
  void resume() => _suspended = _stopFailed;

  void _unregister(RoundPlaybackHandle player) {
    _players.remove(player);
    if (_audible == player) {
      _audible = null;
      if (player._permit == _generation) ++_generation;
    }
  }
}

class RoundPlaybackHandle {
  final RoundPlaybackCoordinator _coordinator;
  Future<void> Function() _pause, _stop;
  int _permit = -1;
  bool _closed = false;
  RoundPlaybackHandle._(this._coordinator, this._pause, this._stop);

  Future<bool> acquireAudible() => _coordinator._activate(this);

  /// Transfer a live player between its timeline row and the mini-player.
  /// Its audible permit remains the same, so no second native player starts.
  void rebind({
    required Future<void> Function() pause,
    required Future<void> Function() stop,
  }) {
    if (_closed) return;
    _pause = pause;
    _stop = stop;
  }

  bool get isCurrent =>
      !_closed &&
      !_coordinator.suspended &&
      _coordinator._audible == this &&
      _permit == _coordinator._generation;

  void releaseAudible() {
    if (_coordinator._audible == this) {
      _coordinator._audible = null;
      if (_permit == _coordinator._generation) ++_coordinator._generation;
    }
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _coordinator._unregister(this);
  }
}

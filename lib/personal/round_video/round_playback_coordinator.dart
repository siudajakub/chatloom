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

/// Permission for an autoplay continuation (the next round or voice message
/// after one finished) to become audible. Any explicit play, app lock,
/// background or account switch cancels it, so a slow download of the next
/// item never steals audio from what the user chose meanwhile.
class RoundContinuationToken {
  final RoundPlaybackCoordinator _coordinator;
  bool _cancelled = false;
  int _claims = 0;
  RoundContinuationToken._(this._coordinator);

  bool get active => !_cancelled && identical(_coordinator._continuation, this);

  /// A driver walking the queue claims the token. A newer claim (a row
  /// disposed while preparing hands its item to the detached player) takes
  /// over, and only the current claimant ends the token.
  int claim() => ++_claims;
  bool isClaimedBy(int claim) => _claims == claim;

  /// Ends the continuation (started, exhausted or abandoned).
  void end() {
    _cancelled = true;
    if (identical(_coordinator._continuation, this)) {
      _coordinator._continuation = null;
    }
  }

  @override
  String toString() => 'RoundContinuationToken(${active ? 'active' : 'ended'})';
}

/// Serializes audible playback across round, voice and ordinary video players.
/// A permit must be checked after asynchronous preparation and before play().
class RoundPlaybackCoordinator {
  static final shared = RoundPlaybackCoordinator();
  final Set<RoundPlaybackHandle> _players = {};
  Future<void> _queue = Future<void>.value();
  RoundPlaybackHandle? _audible;
  RoundContinuationToken? _continuation;
  int _generation = 0;
  bool _suspended = false;
  bool _stopFailed = false;

  bool get suspended => _suspended;

  /// Whether an autoplay continuation is reserved (for tests and diagnostics).
  bool get continuing => _continuation != null;

  /// Starts a continuation and cancels any previous one. Call it while the
  /// finished item still holds the audible permit, before releasing it.
  RoundContinuationToken beginContinuation() {
    _cancelContinuation();
    final token = RoundContinuationToken._(this);
    if (_suspended) {
      token._cancelled = true;
    } else {
      _continuation = token;
    }
    return token;
  }

  void _cancelContinuation() {
    _continuation?._cancelled = true;
    _continuation = null;
  }

  /// Tests share [shared] with the mini player. A completed serial future
  /// created in an earlier test's fake-async zone never runs callbacks in the
  /// next one, so each test starts from a fresh chain.
  void debugReset() {
    ++_generation;
    _queue = Future<void>.value();
    _audible = null;
    _cancelContinuation();
    _suspended = false;
    _stopFailed = false;
  }

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

  Future<bool> _activate(
    RoundPlaybackHandle handle, {
    RoundContinuationToken? continuation,
  }) {
    // Only the continuation itself may proceed; anything else is a user
    // choice that ends it.
    if (continuation == null) {
      _cancelContinuation();
    } else if (!continuation.active) {
      return Future.value(false);
    }
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
      if (_suspended ||
          handle._closed ||
          generation != _generation ||
          (continuation != null && !continuation.active)) {
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
    _cancelContinuation();
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

  /// Pass [continuation] only for autoplay of a following item.
  Future<bool> acquireAudible({RoundContinuationToken? continuation}) =>
      _coordinator._activate(this, continuation: continuation);

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

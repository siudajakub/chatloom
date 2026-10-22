// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleListener, AppLifecycleState, WidgetsBinding;

import 'round_capture_backend.dart';
import 'round_media_preparer.dart';

enum RoundCaptureState {
  initializing,
  ready,
  recording,
  paused,
  preparing,
  review,
  canceled,
  failed,
}

enum RoundCaptureGesturePhase { idle, holding, locked, released, canceled }

/// Carries the original composer's pointer across preflight, permission dialogs
/// and the recorder route. The destination is frozen separately by the caller.
///
/// Thresholds follow Telegram Android's record button (ChatActivityEnterView):
/// slide toward the start edge by [cancelDistance] to cancel, release with
/// less than [releaseCancelProgress] slide progress left to cancel, swipe up
/// [lockDistance] to lock (ignored once slid past [lockMinSlideProgress]).
class RoundCaptureGestureController extends ChangeNotifier {
  /// A press held this long records; a quicker release is a tap that only
  /// shows the hold hint.
  static const holdDelay = Duration(milliseconds: 150);

  /// Upward travel that locks the recording (hands-free).
  static const double lockDistance = 57;

  /// Slide-to-cancel travel: 35 % of the layout width, at most 140 dp.
  static const double maxCancelDistance = 140;
  static const double cancelWidthFraction = 0.35;

  /// Releasing with less slide progress left than this cancels.
  static const double releaseCancelProgress = 0.45;

  /// Locking is ignored while the slide progress is below this.
  static const double lockMinSlideProgress = 0.7;

  static double cancelDistanceFor(double width) {
    final fraction = width * cancelWidthFraction;
    return fraction > 0 && fraction < maxCancelDistance
        ? fraction
        : maxCancelDistance;
  }

  RoundCaptureGesturePhase phase;

  /// Travel toward the start edge that cancels (see [cancelDistanceFor]).
  final double cancelDistance;

  /// Global rect of the composer button that owns the pointer; the recorder
  /// draws the held record circle and the lock pill over it.
  final Rect? anchor;
  double _dx = 0;
  double _dy = 0;

  RoundCaptureGestureController({
    bool held = false,
    this.cancelDistance = maxCancelDistance,
    this.anchor,
  }) : phase = held
           ? RoundCaptureGesturePhase.holding
           : RoundCaptureGesturePhase.idle;

  /// Reading-direction offset of the finger (negative toward the start edge).
  double get dx => _dx;
  double get dy => _dy;

  /// 1 at rest, 0 at the cancel distance (Telegram's slideToCancelProgress).
  double get slideProgress => (1 + _dx / cancelDistance).clamp(0.0, 1.0);

  /// 0 at rest, 1 at the lock distance.
  double get lockProgress => (-_dy / lockDistance).clamp(0.0, 1.0);

  void begin() {
    if (phase != RoundCaptureGesturePhase.idle) return;
    phase = RoundCaptureGesturePhase.holding;
    notifyListeners();
  }

  /// [dx] is in reading direction: negative moves toward the start edge.
  void move({required double dx, required double dy}) {
    if (phase != RoundCaptureGesturePhase.holding) return;
    _dx = dx > 0 ? 0 : dx;
    _dy = dy > 0 ? 0 : dy;
    if (-dx >= cancelDistance) {
      cancel();
    } else if (-dy >= lockDistance && slideProgress >= lockMinSlideProgress) {
      lock();
    } else {
      notifyListeners();
    }
  }

  /// The finger left the screen: send, unless it was slid most of the way to
  /// cancel.
  void release() {
    if (phase != RoundCaptureGesturePhase.holding) return;
    if (slideProgress < releaseCancelProgress) {
      cancel();
      return;
    }
    phase = RoundCaptureGesturePhase.released;
    notifyListeners();
  }

  /// The system took the pointer (call, notification shade): keep the
  /// recording hands-free unless it was being slid away.
  void interrupt() {
    if (phase != RoundCaptureGesturePhase.holding) return;
    slideProgress >= lockMinSlideProgress ? lock() : cancel();
  }

  void lock() {
    if (phase != RoundCaptureGesturePhase.holding) return;
    phase = RoundCaptureGesturePhase.locked;
    _dx = _dy = 0;
    notifyListeners();
  }

  void cancel() {
    if (phase == RoundCaptureGesturePhase.canceled) return;
    phase = RoundCaptureGesturePhase.canceled;
    notifyListeners();
  }
}

class RoundCaptureController extends ChangeNotifier {
  /// Android reference rejects video-note clips below 800ms (local UX limit).
  static const minimumDurationMs = 800;

  /// Telegram stops into review half a second before the limit (59.5 s of
  /// 60 s) and hides pause from one second before it.
  static const limitMarginMs = 500;
  static const pauseCutoffMs = 1000;
  static final Set<RoundCaptureController> _open = {};
  final RoundCaptureBackend backend;
  final RoundCaptureProfile profile;
  RoundCaptureState state = RoundCaptureState.initializing;
  RoundCapturePreview? preview;
  PreparedRoundMedia? prepared;
  String? errorCode;
  String? controlErrorCode;
  bool locked = false;
  bool wasInterrupted = false;

  /// The recording reached the duration limit and stopped into review.
  bool stoppedAtLimit = false;

  /// Lens facing. Native opens the front camera first; a camera switch flips
  /// it and native `controls` events carrying `isFrontCamera` correct it.
  bool frontCamera = true;
  int _facingRevision = 0;
  final Stopwatch _clock = Stopwatch();
  Timer? _ticker;
  StreamSubscription<RoundCaptureNativeEvent>? _subscription;
  Future<void>? _finishing;
  int _generation = 0;
  bool _closed = false;
  bool _transferred = false;
  Future<void>? _initialization;
  Future<void>? _operationTail;
  Future<void>? _canceling;
  Future<void>? _zoomFuture;
  double? _requestedZoom;
  String? _controlOperation;
  bool _transitionPending = false;
  int _nativeEpoch = 0;
  bool _nativePreparing = false;

  RoundCaptureController({required this.backend, required this.profile}) {
    _open.add(this);
  }

  /// App lock and account changes must call this before obscuring the recorder.
  /// Capture stops into review; a held release can never auto-send afterwards.
  static Future<void> interruptActive() async {
    await Future.wait(
      _open.toList().map((controller) => controller.interrupt()),
    );
  }

  Duration get duration => state == RoundCaptureState.review
      ? Duration(milliseconds: prepared!.durationMs)
      : Duration(
          milliseconds: _clock.elapsedMilliseconds.clamp(
            0,
            profile.maxDurationMs,
          ),
        );
  bool get active =>
      state == RoundCaptureState.recording || state == RoundCaptureState.paused;
  bool get isFinalizing => _finishing != null || _nativePreparing;
  bool get controlsBusy => _controlOperation != null || _transitionPending;

  /// A lens switch is in flight (until the new lens shows its first frame).
  bool get switchingCamera => _controlOperation == 'switch';
  bool get _interactive =>
      !_closed && (state == RoundCaptureState.ready || active);
  bool get canSwitchCamera =>
      _interactive &&
      !controlsBusy &&
      preview?.canSwitchCamera == true &&
      (!active || preview?.canSwitchDuringRecording == true);
  bool get canZoom =>
      _interactive &&
      !_transitionPending &&
      (_controlOperation == null || _controlOperation == 'zoom') &&
      preview?.canZoom == true;
  bool get canSetTorch =>
      _interactive && !controlsBusy && preview?.torchAvailable == true;

  /// Recording time at which capture stops into review.
  int get autoStopMs =>
      profile.maxDurationMs - limitMarginMs > minimumDurationMs
      ? profile.maxDurationMs - limitMarginMs
      : profile.maxDurationMs;

  /// Pause is offered while recording, except in the last second.
  bool get canPause =>
      !_closed &&
      !_transitionPending &&
      state == RoundCaptureState.recording &&
      duration.inMilliseconds < profile.maxDurationMs - pauseCutoffMs;

  /// An interruption while the camera is still opening, with the app only
  /// `inactive`: the first camera/microphone permission prompt (Android
  /// shows it over the app). Cancelling would lose the gesture and record
  /// nothing after "Allow". Instead the recording continues hands-free
  /// (locked) once the app is back in the foreground; a background, app
  /// lock or account switch in between still cancels (they interrupt again
  /// with the app not `inactive`, or the settle below sees them).
  bool _deferredInterrupt = false;

  Future<void> interrupt() async {
    if (_closed) return;
    if (state == RoundCaptureState.initializing &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.inactive) {
      _deferredInterrupt = true;
      locked = true;
      _changed();
      return;
    }
    wasInterrupted = true;
    locked = true;
    if (active) {
      await finish();
    } else if (state == RoundCaptureState.initializing ||
        state == RoundCaptureState.ready ||
        (state == RoundCaptureState.preparing &&
            _finishing == null &&
            !_nativePreparing &&
            prepared == null)) {
      await cancel();
    }
    _changed();
  }

  /// Capture commands share one queue. Cancel/dispose invalidate it immediately,
  /// so waiting camera callbacks never delay privacy or resurrect the draft.
  Future<void> _enqueue(Future<void> Function() operation) {
    final previous = _operationTail;
    final completion = Completer<void>();
    final future = completion.future;
    _operationTail = future;
    Future<void> run() async {
      try {
        await operation();
      } finally {
        if (identical(_operationTail, future)) _operationTail = null;
        completion.complete();
      }
    }

    if (previous == null) {
      unawaited(run());
    } else {
      unawaited(previous.then((_) => run()));
    }
    return future;
  }

  bool _current(int generation) => !_closed && generation == _generation;

  void _changed() {
    if (!_closed) notifyListeners();
  }

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    final generation = _generation;
    _subscription ??= backend.events.listen(_nativeEvent);
    try {
      final result = await backend.initialize(profile);
      if (!_current(generation) || state != RoundCaptureState.initializing) {
        return;
      }
      if (_deferredInterrupt && !await _backInForeground()) {
        if (_current(generation) && state == RoundCaptureState.initializing) {
          wasInterrupted = true;
          await cancel();
        }
        return;
      }
      if (!_current(generation) || state != RoundCaptureState.initializing) {
        return;
      }
      preview = result;
      _facingRevision = result.cameraRevision;
      state = RoundCaptureState.ready;
    } catch (error) {
      if (_closed || generation != _generation) return;
      _fail(error);
    }
    _changed();
  }

  /// Waits until a [_deferredInterrupt] resolves: true when the app is
  /// resumed again, false when it went to the background (or closed).
  Future<bool> _backInForeground() async {
    _deferredInterrupt = false;
    var lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == AppLifecycleState.inactive) {
      final settled = _settled = Completer<AppLifecycleState?>();
      final listener = AppLifecycleListener(
        onStateChange: (next) {
          if (next != AppLifecycleState.inactive && !settled.isCompleted) {
            settled.complete(next);
          }
        },
      );
      try {
        lifecycle = await settled.future;
      } finally {
        if (identical(_settled, settled)) _settled = null;
        listener.dispose();
      }
    }
    return !_closed &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed);
  }

  Completer<AppLifecycleState?>? _settled;

  Future<void> start({bool lock = false}) {
    if (_closed || controlsBusy || state != RoundCaptureState.ready) {
      return Future<void>.value();
    }
    final generation = _generation;
    final nativeEpoch = _nativeEpoch;
    state = RoundCaptureState.preparing;
    _changed();
    return _enqueue(() async {
      try {
        if (!_current(generation) || state != RoundCaptureState.preparing) {
          return;
        }
        await backend.start();
        if (!_current(generation) ||
            state != RoundCaptureState.preparing ||
            nativeEpoch != _nativeEpoch) {
          return;
        }
        // A permission prompt during setup already locked it (hands-free).
        locked = locked || lock;
        _clock.reset();
        _clock.start();
        state = RoundCaptureState.recording;
        _subscribeTicker();
      } catch (error) {
        if (_current(generation) &&
            state == RoundCaptureState.preparing &&
            nativeEpoch == _nativeEpoch) {
          _transitionFailed(error);
        }
      }
      _changed();
    });
  }

  void lock() {
    if (!active || locked) return;
    locked = true;
    _changed();
  }

  /// Ticks every 100 ms while recording, for the clock and progress ring
  /// only. Listeners of the controller itself hear state changes, not time:
  /// the recorder page around the camera preview is not rebuilt per tick.
  Listenable get elapsed => _elapsed;
  final _elapsed = _Tick();

  void _subscribeTicker() {
    _ticker?.cancel();
    var couldPause = canPause;
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_closed || state != RoundCaptureState.recording) return;
      if (_clock.elapsedMilliseconds >= autoStopMs) {
        // A held release can never send after the limit stopped capture.
        wasInterrupted = true;
        stoppedAtLimit = true;
        locked = true;
        unawaited(finish());
      }
      _elapsed.tick();
      // Pause disappears in the last second: that is a state change.
      if (canPause != couldPause) {
        couldPause = canPause;
        _changed();
      }
    });
  }

  Future<void> pause() {
    if (_closed || _transitionPending || state != RoundCaptureState.recording) {
      return Future<void>.value();
    }
    final generation = _generation;
    locked = true;
    _transitionPending = true;
    final result = _enqueue(() async {
      try {
        if (!_current(generation) || state != RoundCaptureState.recording) {
          return;
        }
        await backend.pause();
        if (!_current(generation) || state != RoundCaptureState.recording) {
          return;
        }
        _clock.stop();
        _ticker?.cancel();
        locked = true;
        state = RoundCaptureState.paused;
      } catch (error) {
        if (_current(generation) && state == RoundCaptureState.recording) {
          _transitionFailed(error);
        }
      } finally {
        _transitionPending = false;
        _changed();
      }
    });
    _changed();
    return result;
  }

  Future<void> resume() {
    if (_closed || _transitionPending || state != RoundCaptureState.paused) {
      return Future<void>.value();
    }
    final generation = _generation;
    _transitionPending = true;
    final result = _enqueue(() async {
      try {
        if (!_current(generation) || state != RoundCaptureState.paused) return;
        await backend.resume();
        if (!_current(generation) || state != RoundCaptureState.paused) return;
        _clock.start();
        state = RoundCaptureState.recording;
        _subscribeTicker();
      } catch (error) {
        if (_current(generation) && state == RoundCaptureState.paused) {
          _transitionFailed(error);
        }
      } finally {
        _transitionPending = false;
        _changed();
      }
    });
    _changed();
    return result;
  }

  Future<void> finish() {
    final running = _finishing;
    if (running != null) return running;
    if (!active) return Future<void>.value();
    final generation = _generation;
    _clock.stop();
    _ticker?.cancel();
    state = RoundCaptureState.preparing;
    // Lens opening can wait on hardware. Stop preempts it so a lock/account/
    // background boundary never keeps the microphone alive for a late lens.
    final result = _finish(generation);
    _finishing = result;
    _changed();
    return result;
  }

  Future<void> _finish(int generation) async {
    if (!_current(generation) || state != RoundCaptureState.preparing) return;
    try {
      final result = await backend.finish();
      if (!_current(generation) ||
          (state != RoundCaptureState.preparing &&
              state != RoundCaptureState.review)) {
        return;
      }
      prepared = result;
      _nativePreparing = false;
      if (backend is AndroidRoundCaptureBackend &&
          (backend as AndroidRoundCaptureBackend).wasInterrupted) {
        wasInterrupted = true;
        locked = true;
      }
      state = RoundCaptureState.review;
    } catch (error) {
      if (_current(generation) && state == RoundCaptureState.preparing) {
        _fail(error);
      }
    }
    _changed();
  }

  Future<void> trim(int startMs, int endMs) async {
    if (state != RoundCaptureState.review || prepared == null) return;
    if (startMs < 0 ||
        endMs > prepared!.durationMs ||
        endMs - startMs < minimumDurationMs) {
      return;
    }
    final generation = _generation;
    state = RoundCaptureState.preparing;
    controlErrorCode = null;
    _changed();
    try {
      final result = await backend.trim(startMs, endMs);
      if (_closed || generation != _generation) return;
      prepared = result;
      state = RoundCaptureState.review;
    } catch (error) {
      if (_current(generation) && state == RoundCaptureState.preparing) {
        if (error is RoundCaptureException && error.code == 'trim_failed') {
          controlErrorCode = error.code;
          state = RoundCaptureState.review;
        } else {
          _fail(error);
        }
      }
    }
    _changed();
  }

  Future<void> switchCamera() {
    if (!canSwitchCamera) return Future<void>.value();
    return _control(
      'switch',
      () => backend.switchCamera(cameraRevision: preview!.cameraRevision),
    );
  }

  Future<void> setTorch(bool enabled) {
    if (!canSetTorch || preview!.torchEnabled == enabled) {
      return Future<void>.value();
    }
    return _control(
      'torch',
      () => backend.setTorch(enabled, cameraRevision: preview!.cameraRevision),
    );
  }

  Future<void> _control(
    String kind,
    Future<RoundCapturePreview> Function() operation,
  ) {
    final generation = _generation;
    _controlOperation = kind;
    controlErrorCode = null;
    final result = _enqueue(() async {
      try {
        if (!_current(generation) || !_interactive) return;
        final result = await operation();
        if (!_current(generation) || !_interactive) return;
        _applyPreview(result, switched: kind == 'switch');
      } catch (error) {
        if (_current(generation) && _interactive) _controlFailed(error);
      } finally {
        _controlOperation = null;
        _changed();
      }
    });
    _changed();
    return result;
  }

  /// A drag/pinch sends the current target and then only the newest target.
  /// Native commands remain serial, and a camera change cannot reuse old limits.
  Future<void> setZoom(double zoom) {
    if (!canZoom || !zoom.isFinite) return Future<void>.value();
    _requestedZoom = zoom.clamp(preview!.minZoom, preview!.maxZoom);
    final pending = _zoomFuture;
    if (pending != null) return pending;
    final generation = _generation;
    _controlOperation = 'zoom';
    controlErrorCode = null;
    final future = _enqueue(() async {
      try {
        while (_current(generation) && _interactive && _requestedZoom != null) {
          final value = _requestedZoom!;
          _requestedZoom = null;
          final result = await backend.setZoom(
            value,
            cameraRevision: preview!.cameraRevision,
          );
          if (!_current(generation) || !_interactive) return;
          _applyPreview(result);
        }
      } catch (error) {
        if (_current(generation) && _interactive) _controlFailed(error);
      } finally {
        _requestedZoom = null;
        _zoomFuture = null;
        _controlOperation = null;
        _changed();
      }
    });
    _zoomFuture = future;
    _changed();
    return future;
  }

  void _applyPreview(RoundCapturePreview value, {bool switched = false}) {
    if (value.cameraRevision < (preview?.cameraRevision ?? 0)) return;
    if (switched && value.cameraRevision > _facingRevision) {
      frontCamera = !frontCamera;
      _facingRevision = value.cameraRevision;
    }
    preview = value;
  }

  void _controlFailed(Object error) {
    controlErrorCode = error is RoundCaptureException
        ? error.code
        : 'camera_control';
    // Native owns recovery/rollback. Fatal hardware failures emit a capture
    // error or preparing/completed event; a rejected control keeps this draft.
  }

  void _transitionFailed(Object error) {
    if (error is RoundCaptureException && error.code == 'interrupted') {
      // Native is exporting the recorded bytes after a recoverable hardware
      // interruption. Its method reply can precede the preparing event.
      _nativePreparing = true;
      wasInterrupted = true;
      locked = true;
      _clock.stop();
      _ticker?.cancel();
      state = RoundCaptureState.preparing;
      return;
    }
    _fail(error);
  }

  void _nativeEvent(RoundCaptureNativeEvent event) {
    if (_closed ||
        state == RoundCaptureState.canceled ||
        state == RoundCaptureState.failed) {
      return;
    }
    if (event.type == 'controls') {
      if (!_interactive) return;
      try {
        final value = RoundCapturePreview.fromNative(event.data);
        final front = event.data['isFrontCamera'];
        if (front is bool && value.cameraRevision >= _facingRevision) {
          frontCamera = front;
          _facingRevision = value.cameraRevision;
        }
        _applyPreview(value);
      } catch (error) {
        _controlFailed(error);
      }
      _changed();
      return;
    }
    if (event.type == 'completed' &&
        backend is AndroidRoundCaptureBackend &&
        (active || state == RoundCaptureState.preparing)) {
      try {
        if (event.data['wasInterrupted'] == true) {
          wasInterrupted = true;
          locked = true;
        }
        prepared = (backend as AndroidRoundCaptureBackend).preparedFromEvent(
          event.data,
        );
        _clock.stop();
        _nativePreparing = false;
        _ticker?.cancel();
        state = RoundCaptureState.review;
      } catch (error) {
        _fail(error);
      }
    } else if (event.type == 'preparing' &&
        (active || state == RoundCaptureState.preparing)) {
      _nativeEpoch++;
      _nativePreparing = true;
      if (active || _finishing == null) {
        wasInterrupted = true;
        locked = true;
      }
      _clock.stop();
      _ticker?.cancel();
      state = RoundCaptureState.preparing;
    } else if (event.type == 'error' && state != RoundCaptureState.review) {
      _nativeEpoch++;
      _fail(RoundCaptureException(event.data['code'] as String? ?? 'capture'));
    }
    _changed();
  }

  void _fail(Object error) {
    _nativePreparing = false;
    _clock.stop();
    _ticker?.cancel();
    errorCode = error is RoundCaptureException ? error.code : 'capture';
    state = RoundCaptureState.failed;
  }

  Future<void> cancel() async {
    final pending = _canceling;
    if (pending != null) return pending;
    if (_closed || state == RoundCaptureState.canceled) return;
    _generation++;
    _nativePreparing = false;
    _clock.stop();
    _ticker?.cancel();
    state = RoundCaptureState.canceled;
    prepared = null;
    preview = null;
    _requestedZoom = null;
    _changed();
    _canceling = backend.cancel();
    await _canceling;
  }

  /// Transfer the lease to the caller; disposing the recorder no longer deletes
  /// it. Call only after an explicit send, or valid hold release.
  PreparedRoundMedia takePrepared() {
    if (state != RoundCaptureState.review || prepared == null || _transferred) {
      throw const RoundCaptureException('not_ready');
    }
    _transferred = true;
    return prepared!;
  }

  @override
  void dispose() {
    _open.remove(this);
    _closed = true;
    final settled = _settled;
    if (settled != null && !settled.isCompleted) settled.complete(null);
    _generation++;
    _ticker?.cancel();
    _elapsed.dispose();
    unawaited(_subscription?.cancel());
    unawaited(backend.dispose(keepPrepared: _transferred));
    super.dispose();
  }
}

class _Tick extends ChangeNotifier {
  void tick() => notifyListeners();
}

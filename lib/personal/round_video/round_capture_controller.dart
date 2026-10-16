// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/foundation.dart';

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
class RoundCaptureGestureController extends ChangeNotifier {
  RoundCaptureGesturePhase phase;
  RoundCaptureGestureController({bool held = false})
    : phase = held
          ? RoundCaptureGesturePhase.holding
          : RoundCaptureGesturePhase.idle;

  void begin() {
    if (phase != RoundCaptureGesturePhase.idle) return;
    phase = RoundCaptureGesturePhase.holding;
    notifyListeners();
  }

  void move({required double dx, required double dy}) {
    if (phase != RoundCaptureGesturePhase.holding) return;
    if (dx < -80) {
      cancel();
    } else if (dy < -80) {
      lock();
    }
  }

  void release() {
    if (phase != RoundCaptureGesturePhase.holding) return;
    phase = RoundCaptureGesturePhase.released;
    notifyListeners();
  }

  void lock() {
    if (phase != RoundCaptureGesturePhase.holding) return;
    phase = RoundCaptureGesturePhase.locked;
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

  Future<void> interrupt() async {
    if (_closed) return;
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
      preview = result;
      state = RoundCaptureState.ready;
    } catch (error) {
      if (_closed || generation != _generation) return;
      _fail(error);
    }
    _changed();
  }

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
        locked = lock;
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

  void _subscribeTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_closed || state != RoundCaptureState.recording) return;
      if (_clock.elapsedMilliseconds >= profile.maxDurationMs) {
        wasInterrupted = true;
        locked = true;
        unawaited(finish());
      }
      _changed();
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
        _applyPreview(result);
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

  void _applyPreview(RoundCapturePreview value) {
    if (value.cameraRevision < (preview?.cameraRevision ?? 0)) return;
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
        _applyPreview(RoundCapturePreview.fromNative(event.data));
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
    _generation++;
    _ticker?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(backend.dispose(keepPrepared: _transferred));
    super.dispose();
  }
}

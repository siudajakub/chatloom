// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

/// Serializes native service changes and keeps one lease per active operation.
/// A failed start never leaves a lease that can keep a wake lock alive later.
class ForegroundServiceController {
  final Future<void> Function() _start;
  final Future<void> Function() _stop;
  final Future<void> Function(List<String> running)? _update;
  final Future<bool> Function()? _isRunning;
  final Duration operationTimeout;
  final List<String> runningServices = [];
  Future<void> _queue = Future<void>.value();
  bool _started = false;

  /// The lease whose native start is in progress (not yet in
  /// [runningServices]), so the start can describe it.
  String? get starting => _starting;
  String? _starting;

  /// [update] runs in the queue after a lease was added to or removed from a
  /// running service that keeps running (the ongoing notification describes
  /// the current work). Its failures are ignored.
  ///
  /// [isRunning] reports whether the native service still runs. The system
  /// can end it without this controller (a short service's timeout, after
  /// which the plugin stops itself): a new lease then starts it again instead
  /// of joining a service that is gone.
  ForegroundServiceController({
    required Future<void> Function() start,
    required Future<void> Function() stop,
    Future<void> Function(List<String> running)? update,
    Future<bool> Function()? isRunning,
    this.operationTimeout = const Duration(seconds: 10),
  }) : _start = start,
       _stop = stop,
       _update = update,
       _isRunning = isRunning;

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _queue.then((_) => operation());
    _queue = next.catchError((Object _) {});
    return next;
  }

  Future<void> start(String name) => _enqueue(() async {
    if (_started && !await _stillRunning()) _started = false;
    if (!_started) {
      _starting = name;
      try {
        await _ensureStarted();
      } finally {
        _starting = null;
      }
      runningServices.add(name);
      return;
    }
    runningServices.add(name);
    await _changed();
  });

  /// False only when [_isRunning] answered that the service is gone; an
  /// unknown answer keeps the current assumption.
  Future<bool> _stillRunning() async {
    final isRunning = _isRunning;
    if (isRunning == null) return true;
    try {
      return await isRunning().timeout(operationTimeout);
    } catch (_) {
      return true;
    }
  }

  Future<void> _changed() async {
    final update = _update;
    if (update == null || !_started || runningServices.isEmpty) return;
    try {
      await update(
        List.unmodifiable(runningServices),
      ).timeout(operationTimeout);
    } catch (_) {}
  }

  Future<void> _ensureStarted() async {
    final startup = _start();
    try {
      await startup.timeout(operationTimeout);
      _started = true;
    } catch (error) {
      // The native side may have started even if its reply was lost. Attempt
      // release now and again after any late completion, without
      // stopping work that acquired a newer lease in the meantime.
      _started = true;
      if (error is TimeoutException) {
        Future<void> reconcile() => _enqueue(() async {
          _started = true;
          await _stopWhenUnused();
        });
        unawaited(
          startup
              .then((_) => reconcile(), onError: (Object _) => reconcile())
              .catchError((Object _) {}),
        );
      }
      try {
        await _stopWhenUnused();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> stop(String name) => _enqueue(() async {
    final removed = runningServices.remove(name);
    await _stopWhenUnused();
    if (removed) await _changed();
  });

  Future<void> _stopWhenUnused() async {
    if (!_started || runningServices.isNotEmpty) return;
    final stopping = _stop();
    try {
      await stopping.timeout(operationTimeout);
      _started = false;
    } on TimeoutException {
      unawaited(
        stopping
            .then(
              (_) => _enqueue(() async {
                _started = false;
                if (runningServices.isNotEmpty) {
                  await _ensureStarted();
                }
              }),
              onError: (Object _) {},
            )
            .catchError((Object _) {}),
      );
      rethrow;
    }
  }
}

/// Counted holds on one lease of the shared service: the first hold takes
/// the lease, the last release gives it back. With [maxHold] the lease is
/// given back that long after it was taken even while holds remain (the
/// work itself goes on); a later hold takes it again. A lease the service
/// refused is never given back, so it cannot drop a lease of the same name
/// that other work holds.
class ForegroundLease {
  final Future<bool> Function() _start;
  final Future<void> Function() _stop;
  final Duration? maxHold;
  int _holds = 0;
  Future<bool>? _taken;
  Timer? _limit;

  ForegroundLease({
    required Future<bool> Function() start,
    required Future<void> Function() stop,
    this.maxHold,
  }) : _start = start,
       _stop = stop;

  /// Work holding the lease (released holds excluded).
  int get holds => _holds;

  /// Whether this object holds the service's lease right now.
  bool get leased => _taken != null;

  /// Takes the lease unless it is held already; returns the release, which
  /// may be called more than once.
  void Function() hold() {
    _holds++;
    if (_taken == null) {
      _taken = _start().catchError((Object _) => false);
      final limit = maxHold;
      if (limit != null) _limit = Timer(limit, _giveBack);
    }
    var released = false;
    return () {
      if (released) return;
      released = true;
      if (--_holds == 0) _giveBack();
    };
  }

  void _giveBack() {
    _limit?.cancel();
    _limit = null;
    final taken = _taken;
    _taken = null;
    if (taken == null) return;
    unawaited(
      taken
          .then((ok) async {
            if (ok) await _stop();
          })
          .catchError((Object _) {}),
    );
  }
}

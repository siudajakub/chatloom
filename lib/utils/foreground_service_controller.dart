// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

/// Serializes native service changes and keeps one lease per active operation.
/// A failed start never leaves a lease that can keep a wake lock alive later.
class ForegroundServiceController {
  final Future<void> Function() _start;
  final Future<void> Function() _stop;
  final Duration operationTimeout;
  final List<String> runningServices = [];
  Future<void> _queue = Future<void>.value();
  bool _started = false;

  ForegroundServiceController({
    required Future<void> Function() start,
    required Future<void> Function() stop,
    this.operationTimeout = const Duration(seconds: 10),
  }) : _start = start,
       _stop = stop;

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _queue.then((_) => operation());
    _queue = next.catchError((Object _) {});
    return next;
  }

  Future<void> start(String name) => _enqueue(() async {
    if (!_started) await _ensureStarted();
    runningServices.add(name);
  });

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
    runningServices.remove(name);
    await _stopWhenUnused();
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

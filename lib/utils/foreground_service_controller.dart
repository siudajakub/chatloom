// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

/// Serializes native service changes and keeps one lease per active operation.
/// A failed start never leaves a lease that can keep a wake lock alive later.
class ForegroundServiceController {
  final Future<void> Function() _start;
  final Future<void> Function() _stop;
  final List<String> runningServices = [];
  Future<void> _queue = Future<void>.value();
  bool _started = false;

  ForegroundServiceController({
    required Future<void> Function() start,
    required Future<void> Function() stop,
  }) : _start = start,
       _stop = stop;

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _queue.then((_) => operation());
    _queue = next.catchError((Object _) {});
    return next;
  }

  Future<void> start(String name) => _enqueue(() async {
    if (!_started) {
      await _start();
      _started = true;
    }
    runningServices.add(name);
  });

  Future<void> stop(String name) => _enqueue(() async {
    runningServices.remove(name);
    if (!_started || runningServices.isNotEmpty) return;
    await _stop();
    _started = false;
  });
}

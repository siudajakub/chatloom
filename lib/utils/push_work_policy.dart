// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

/// Future.timeout cannot cancel its source. Guard each next operation so a late
/// database/network result cannot publish a notification after the deadline.
class PushWorkBudget {
  final Duration limit;
  final Stopwatch _clock = Stopwatch()..start();
  bool _cancelled = false;

  PushWorkBudget({this.limit = const Duration(seconds: 30)});

  Duration get remaining => limit - _clock.elapsed;
  bool get active => !_cancelled && remaining > Duration.zero;

  void check() {
    if (!active) throw TimeoutException('Push work expired');
  }

  Future<T> wait<T>(Future<T> Function() operation) async {
    check();
    try {
      final result = await operation().timeout(remaining);
      check();
      return result;
    } on TimeoutException {
      _cancelled = true;
      rethrow;
    }
  }
}

/// Pace even immediately completed syncs (e.g. offline) and bound every wait.
Future<void> pollIncomingCall({
  required Duration lifetime,
  required Future<void> Function() sync,
  required Future<bool> Function() finished,
  Duration interval = const Duration(seconds: 2),
  Duration requestTimeout = const Duration(seconds: 8),
  Future<void> Function(Duration)? delay,
}) async {
  if (lifetime <= Duration.zero) return;
  final budget = PushWorkBudget(limit: lifetime);
  final pause = delay ?? Future<void>.delayed;
  while (budget.active) {
    try {
      await budget.wait(() => sync().timeout(requestTimeout));
    } on TimeoutException {
      // Leave the native incoming-call timeout in charge when offline.
      return;
    }
    if (!budget.active) return;
    try {
      if (await budget.wait(finished)) return;
    } on TimeoutException {
      return;
    }
    final remaining = budget.remaining;
    if (remaining <= Duration.zero) return;
    await pause(remaining < interval ? remaining : interval);
  }
}

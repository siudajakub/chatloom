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

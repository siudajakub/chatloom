// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

/// A view-owned wait. Cancellation releases its continuation without cancelling
/// shared account-loading futures or leaving a stream subscription behind.
class OwnedAsyncWait {
  final _cancelled = Completer<bool>();
  StreamIterator<dynamic>? _iterator;

  bool get cancelled => _cancelled.isCompleted;

  Future<bool> until(Future<dynamic>? loading) async {
    if (cancelled) return false;
    if (loading == null) return true;
    final completed = await Future.any<bool>([
      loading.then((_) => true),
      _cancelled.future,
    ]);
    return completed && !cancelled;
  }

  Future<bool> firstWhere<T>(
    Stream<T> stream,
    bool Function(T) predicate,
  ) async {
    if (cancelled) return false;
    if (_iterator != null) {
      throw StateError('An owned stream wait is already active');
    }
    final iterator = StreamIterator<T>(stream);
    _iterator = iterator;
    try {
      while (await iterator.moveNext()) {
        if (cancelled) return false;
        if (predicate(iterator.current)) return true;
      }
      return false;
    } finally {
      if (identical(_iterator, iterator)) _iterator = null;
      await iterator.cancel();
    }
  }

  void cancel() {
    if (cancelled) return;
    _cancelled.complete(false);
    final iterator = _iterator;
    _iterator = null;
    if (iterator != null) unawaited(iterator.cancel());
  }
}

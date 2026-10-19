// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

/// Bounded retries for one registration series. Timers exist only while the UI
/// is foreground; pausing preserves the attempt count and pending work.
class PushRegistrationRetry<T extends Object> {
  static const maxRetries = 5;
  final Future<void> Function(T) retry;
  final bool Function(T) eligible;
  final void Function(T) onExhausted;
  final Map<T, _RegistrationRetryEntry> _entries = {};
  bool _foreground = false;

  PushRegistrationRetry({
    required this.retry,
    required this.eligible,
    required this.onExhausted,
  });

  int get trackedCount => _entries.length;
  int get scheduledCount =>
      _entries.values.where((entry) => entry.timer != null).length;

  void setForeground(bool foreground) {
    _foreground = foreground;
    for (final key in _entries.keys.toList()) {
      final entry = _entries[key]!;
      if (!foreground) {
        entry.timer?.cancel();
        entry.timer = null;
      } else if (!eligible(key)) {
        forget(key);
      } else {
        _schedule(key, entry);
      }
    }
  }

  void failed(T key) {
    if (!eligible(key)) {
      forget(key);
      return;
    }
    final entry = _entries.putIfAbsent(key, _RegistrationRetryEntry.new);
    if (entry.attempts >= maxRetries) {
      entry.timer?.cancel();
      entry.timer = null;
      entry.pending = false;
      onExhausted(key);
      return;
    }
    entry.pending = true;
    _schedule(key, entry);
  }

  void _schedule(T key, _RegistrationRetryEntry entry) {
    if (!_foreground ||
        !entry.pending ||
        entry.timer != null ||
        entry.attempts >= maxRetries)
      return;
    final seconds = (30 * (1 << entry.attempts)).clamp(30, 300);
    entry.timer = Timer(Duration(seconds: seconds), () {
      entry.timer = null;
      if (!_foreground || !identical(_entries[key], entry)) return;
      if (!eligible(key)) {
        forget(key);
        return;
      }
      entry.pending = false;
      entry.attempts++;
      unawaited(
        Future<void>.sync(() => retry(key)).catchError((Object _) {
          if (identical(_entries[key], entry)) failed(key);
        }),
      );
    });
  }

  void forget(T key) => _entries.remove(key)?.timer?.cancel();

  /// Explicit visible setup and token rotation begin a fresh series. Failure
  /// callbacks must use failed(), otherwise they could reset the retry budget.
  void reset() {
    for (final key in _entries.keys.toList()) {
      forget(key);
    }
  }
}

class _RegistrationRetryEntry {
  int attempts = 0;
  bool pending = false;
  Timer? timer;
}

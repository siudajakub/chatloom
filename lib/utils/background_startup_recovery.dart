// SPDX-License-Identifier: AGPL-3.0-or-later

/// The UI can arrive before or after a background startup fails. A fresh
/// foreground owner may open storage only after the abandoned owner closes it.
class BackgroundStartupRecovery {
  final Future<void> Function() startForeground;
  bool _foregroundRequested = false, _failed = false, _claimed = false;
  Future<void> _cleanup = Future<void>.value();

  BackgroundStartupRecovery({required this.startForeground});

  Future<void> requestForeground() {
    _foregroundRequested = true;
    return _startWhenReady();
  }

  void leaveForeground() => _foregroundRequested = false;

  Future<void> fail(Future<void> cleanup) {
    _failed = true;
    _cleanup = cleanup;
    // Observe cleanup errors while detached. A failed cleanup still prevents
    // the foreground path from opening a second client on the same database.
    cleanup.catchError((Object _) {});
    return _startWhenReady();
  }

  Future<void> _startWhenReady() async {
    if (!_foregroundRequested || !_failed || _claimed) return;
    _claimed = true;
    await _cleanup;
    if (!_foregroundRequested) {
      _claimed = false;
      return;
    }
    await startForeground();
  }
}

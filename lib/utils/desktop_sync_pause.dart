// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/utils/client_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:matrix/matrix.dart';

/// Stops the macOS sync loop once the window has been out of sight for
/// [delay] and restarts it the moment the window shows again (BP-02/MAC-12).
///
/// Out of sight: the lifecycle is `hidden`/`paused` (closed with the red
/// button, minimised, fully covered, another Space) or the window reports
/// itself occluded. A window that is visible but not focused (`inactive`)
/// keeps syncing: J can still see it. Telegram and Messenger for Mac keep
/// syncing because they notify; ChatLoom shows no Mac notifications (J's
/// decision), so a hidden window has nobody to sync for.
///
/// While paused, [paused] is true, so network changes do not restart sync
/// (`SyncNetworkRecovery`). Sends, the outbox and one-shot syncs triggered by
/// explicit actions are unaffected.
class DesktopSyncPause {
  DesktopSyncPause({
    required this.clients,
    this.delay = const Duration(minutes: 10),
    @visibleForTesting
    void Function(Client client, {required bool visible})? apply,
  }) : _apply = apply ?? ClientManager.applyDesktopLifecycle;

  /// The app's instance on macOS (the wake handler checks it).
  static DesktopSyncPause? current;

  final Iterable<Client> Function() clients;
  final Duration delay;
  final void Function(Client client, {required bool visible}) _apply;

  AppLifecycleState? _state;
  bool _windowVisible = true;
  Timer? _timer;
  bool _paused = false;

  /// Whether the sync loop is stopped because the window is hidden.
  bool get paused => _paused;

  /// Whether the window is in sight right now.
  bool get visible =>
      _windowVisible &&
      (_state == null ||
          _state == AppLifecycleState.resumed ||
          _state == AppLifecycleState.inactive);

  void onLifecycle(AppLifecycleState state) {
    // Detached: the engine is going away; leave the loop as it is.
    if (state == AppLifecycleState.detached) return;
    _state = state;
    _update();
  }

  /// The native window's own visibility (occlusion, minimise).
  void onWindowVisible(bool visible) {
    _windowVisible = visible;
    _update();
  }

  void _update() {
    if (visible) {
      _timer?.cancel();
      _timer = null;
      if (!_paused) return;
      _paused = false;
      for (final client in clients()) {
        _apply(client, visible: true);
      }
      Logs().v('Desktop sync resumed');
      return;
    }
    if (_paused || _timer != null) return;
    _timer = Timer(delay, () {
      _timer = null;
      if (visible || _paused) return;
      _paused = true;
      for (final client in clients()) {
        _apply(client, visible: false);
      }
      Logs().v('Desktop sync paused while hidden');
    });
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}

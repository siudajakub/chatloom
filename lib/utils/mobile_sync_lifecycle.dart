// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/connection_status.dart';
import 'package:chatloom/utils/client_manager.dart';
import 'package:chatloom/utils/mobile_sync_policy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:matrix/matrix.dart';

/// Applies the phone sync settings to one client; returns the catch-up sync
/// it started, if any (see [ClientManager.applyMobileLifecycle]).
typedef MobileSyncApply =
    Future<void>? Function(
      Client client, {
      required bool foreground,
      bool catchUp,
    });

/// The phone's sync loop across app lifecycle changes (2026-10-31).
///
/// The loop runs while the app is on screen: `resumed`, and `inactive` (the
/// notification shade, a system dialog or the app switcher over the still
/// visible app), so pulling down the shade neither stops nor restarts it.
/// `hidden`, `paused` and `detached` stop it: the current long-poll ends
/// within its 30 s and no retry is scheduled. From then on FCM pushes and
/// their catch-up deliver notifications (`BackgroundPush`, `PushCatchUp`),
/// independent of this loop; nothing polls, syncs on a timer or holds a
/// wakelock behind the user's back.
///
/// Coming back waits for nothing: a long-poll from before (perhaps on a
/// socket the background killed, which would only fail after its 40 s
/// timeout) is dropped, the retry backoff is skipped and a zero-timeout
/// catch-up asks the server for everything new at once; the loop long-polls
/// again after it (`syncNow`). The connection monitor hears about both
/// edges, so errors the background caused (Android cuts a background app's
/// network) never read as "offline", and the catch-up shows only as a small
/// "Updating…" when it takes longer than its grace.
class MobileSyncLifecycle {
  MobileSyncLifecycle({
    required this.clients,
    @visibleForTesting
    ConnectionStatusMonitor Function(Client client)? monitorOf,
    @visibleForTesting MobileSyncApply? apply,
  }) : _monitorOf = monitorOf ?? ConnectionStatusMonitor.of,
       _apply = apply ?? ClientManager.applyMobileLifecycle;

  final Iterable<Client> Function() clients;
  final ConnectionStatusMonitor Function(Client client) _monitorOf;
  final MobileSyncApply _apply;
  bool? _foreground;

  /// Whether the sync loop runs in [state].
  static bool syncsIn(AppLifecycleState? state) => mobileSyncRunsIn(state);

  /// Whether the loop runs now; null before the first state is known.
  bool? get foreground => _foreground;

  /// Clients whose loop [holdWhileAway] keeps off.
  static final _held = Expando<bool>('mobile sync held');

  /// Startup half of the policy (2026-11-26). A client that finishes
  /// restoring while the app is off screen (the user left during start-up,
  /// or the background-fetch engine got an Activity that never came to the
  /// front) has its loop kept off. Its init started the loop, and no GUI
  /// existed to stop it: the GUI is built on a frame, and Flutter draws no
  /// frames in the background, so the loop long-polled every 30 s until the
  /// app was shown again. [seed], or the next change to a state on screen,
  /// starts it with a catch-up. Returns whether the loop is held; an unknown
  /// [state] never holds it.
  static bool holdWhileAway(Client client, AppLifecycleState? state) {
    if (state == null || syncsIn(state)) return false;
    _held[client] = true;
    client.backgroundSync = false;
    return true;
  }

  /// Whether [holdWhileAway] keeps [client]'s loop off.
  static bool isHeld(Client client) => _held[client] ?? false;

  /// Records the state the app starts in. On screen, a running loop is left
  /// as it is (the startup started it) and one [holdWhileAway] kept off
  /// starts with a catch-up. Off screen (the background-fetch engine's
  /// Activity went straight to the background) every loop stops, as on any
  /// later change to the background.
  void seed(AppLifecycleState? state) {
    if (state == null || _foreground != null) return;
    final foreground = _foreground = syncsIn(state);
    for (final client in clients()) {
      if (!foreground) {
        _held[client] = null;
        _monitorOf(client).background();
        _apply(client, foreground: false);
      } else if (isHeld(client)) {
        _held[client] = null;
        _apply(client, foreground: true, catchUp: true);
      }
    }
  }

  void onLifecycle(AppLifecycleState state) {
    final foreground = syncsIn(state);
    final previous = _foreground;
    if (previous == foreground) return;
    _foreground = foreground;
    final back = foreground && previous == false;
    for (final client in clients()) {
      final held = isHeld(client);
      _held[client] = null;
      final monitor = _monitorOf(client);
      if (!foreground) {
        monitor.background();
        _apply(client, foreground: false);
      } else if (!back) {
        _apply(client, foreground: true, catchUp: held);
      } else {
        // Before the catch-up reports anything.
        monitor.resumed(
          catchingUp: client.isLogged() && client.prevBatch != null,
        );
        final before = client.onSyncStatus.value;
        final catchUp = _apply(client, foreground: true, catchUp: true);
        if (catchUp == null) {
          monitor.caughtUp();
        } else {
          unawaited(
            catchUp.catchError((Object _) {}).whenComplete(() {
              // Read here, not from the monitor: the status stream delivers
              // the catch-up's last report after its future completes. A
              // failed catch-up stays "Updating…" until the SDK's retry
              // decides (one failure is no evidence either way).
              final after = client.onSyncStatus.value;
              final failed =
                  !identical(after, before) &&
                  after?.status == SyncStatus.error;
              if (!failed) monitor.caughtUp();
            }),
          );
        }
      }
    }
  }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/connection_status.dart';
import 'package:chatloom/utils/client_manager.dart';
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
  static bool syncsIn(AppLifecycleState? state) =>
      state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;

  /// Whether the loop runs now; null before the first state is known.
  bool? get foreground => _foreground;

  /// Records the state the app starts in without touching the loop (the
  /// startup already started it).
  void seed(AppLifecycleState? state) {
    if (state == null) return;
    _foreground ??= syncsIn(state);
  }

  void onLifecycle(AppLifecycleState state) {
    final foreground = syncsIn(state);
    final previous = _foreground;
    if (previous == foreground) return;
    _foreground = foreground;
    final back = foreground && previous == false;
    for (final client in clients()) {
      final monitor = _monitorOf(client);
      if (!foreground) {
        monitor.background();
        _apply(client, foreground: false);
      } else if (!back) {
        _apply(client, foreground: true);
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

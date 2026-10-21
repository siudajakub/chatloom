// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/push_diagnostics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:matrix/matrix.dart';

/// One bounded catch-up `/sync` after a message notification was shown while
/// the app is in the background (2026-10-21).
///
/// Phones stop the sync loop in the background and rely on FCM to wake the
/// app. The push path only fetches the one event it shows and does not store
/// it, so tapping the notification used to open the chat before the resume
/// catch-up had delivered the message: it appeared a second or more later.
/// Telegram and Messenger fetch on the push instead. This sync runs right
/// after the notification, while the radio is still awake from the event
/// fetch (no extra wake-up), and stores the message, the other chats'
/// backlog, read markers and keys, so the tap shows the chat as it is.
///
/// Bounds: the server answers at once (`timeout=0`); a waiting long-poll of
/// a just-paused loop is dropped rather than joined; at most one catch-up
/// per [minInterval] per account (a burst of pushes is covered by the first
/// one, and the next push's event is then read from the database); the
/// caller waits at most [wait]. Nothing loops or repeats.
class PushCatchUp {
  PushCatchUp({
    this.minInterval = const Duration(seconds: 10),
    this.wait = const Duration(seconds: 15),
    DateTime Function()? clock,
    @visibleForTesting Future<void> Function(Client client)? sync,
  }) : _clock = clock ?? DateTime.now,
       _sync = sync ?? _restartSync;

  final Duration minInterval;
  final Duration wait;
  final DateTime Function() _clock;
  final Future<void> Function(Client client) _sync;
  final _last = Expando<DateTime>('push catch-up');
  final _running = Expando<Future<void>>('push catch-up run');

  static Future<void> _restartSync(Client client) =>
      client.restartSync(timeout: Duration.zero);

  /// Whether a push with [outcome] is followed by a catch-up: a message
  /// notification was shown while the phone app is not in the foreground
  /// (its sync loop is off). Silenced, read or own messages, test pushes
  /// and generic fallbacks after a failed fetch are not.
  static bool wanted(
    PushOutcome outcome, {
    required bool mobile,
    required AppLifecycleState? lifecycle,
  }) =>
      outcome == PushOutcome.shown &&
      mobile &&
      lifecycle != AppLifecycleState.resumed;

  /// Starts (or joins) the catch-up of [client]; null when it is skipped.
  /// The returned future completes within [wait] and never throws.
  Future<void>? run(Client client) {
    if (!client.isLogged()) return null;
    final running = _running[client];
    if (running != null) return running;
    final now = _clock();
    final last = _last[client];
    if (last != null &&
        !now.isBefore(last) &&
        now.difference(last) < minInterval) {
      return null;
    }
    _last[client] = now;
    late final Future<void> started;
    started = () async {
      try {
        // Future.sync: even a synchronous throw completes after `started`
        // was assigned, so `finally` can always compare it.
        await Future<void>.sync(() => _sync(client)).timeout(wait);
      } catch (error) {
        // Offline, timed out or rejected: the resume catch-up still runs.
        Logs().w('[Push] catch_up_sync_failed', error.runtimeType.toString());
      } finally {
        if (identical(_running[client], started)) _running[client] = null;
      }
    }();
    _running[client] = started;
    return started;
  }
}

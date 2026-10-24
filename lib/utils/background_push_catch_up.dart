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

/// The `/sync` a count-only push (read on another device, badge update) runs
/// before it removes notifications of chats that are no longer unread
/// (BP-06a). J reading chats one by one on the Mac used to cost the phone one
/// wake-up sync per chat.
///
/// Same bounds as [PushCatchUp]: a running sync is joined, and within
/// [minInterval] of the last one no new sync starts when the push's unread
/// count already matches the local state (a burst delivered together after
/// Doze, or a repeat). A count that differs still syncs, so a chat read a
/// few seconds after the previous one still loses its notification. The
/// caller waits at most [wait]; failures are swallowed (the next push or the
/// resume catch-up retries).
class PushCountSync {
  PushCountSync({
    this.minInterval = const Duration(seconds: 10),
    this.wait = const Duration(seconds: 8),
    DateTime Function()? clock,
    @visibleForTesting Future<void> Function(Client client)? sync,
    @visibleForTesting int Function(Client client)? localUnread,
  }) : _clock = clock ?? DateTime.now,
       _sync = sync ?? _zeroTimeoutSync,
       _localUnread = localUnread ?? unreadOf;

  /// One per isolate: the push isolate and the app share nothing anyway.
  static final shared = PushCountSync();

  final Duration minInterval;
  final Duration wait;
  final DateTime Function() _clock;
  final Future<void> Function(Client client) _sync;
  final int Function(Client client) _localUnread;
  final _last = Expando<DateTime>('push count sync');
  final _running = Expando<Future<void>>('push count sync run');

  static Future<void> _zeroTimeoutSync(Client client) =>
      client.oneShotSync(timeout: Duration.zero);

  /// The unread total the gateway counts (`counts.unread`): the sum of the
  /// rooms' notification counts.
  static int unreadOf(Client client) =>
      client.rooms.fold<int>(0, (sum, room) => sum + room.notificationCount);

  /// Syncs [client] unless that is not needed (see the class); never throws.
  /// Returns whether a sync ran or was joined.
  Future<bool> run(Client client, {required int? unread}) async {
    final running = _running[client];
    if (running != null) {
      await running;
      return true;
    }
    final now = _clock();
    final last = _last[client];
    final recent =
        last != null &&
        !now.isBefore(last) &&
        now.difference(last) < minInterval;
    if (recent && (unread == null || unread == _localUnread(client))) {
      return false;
    }
    _last[client] = now;
    late final Future<void> started;
    started = () async {
      try {
        await Future<void>.sync(() => _sync(client)).timeout(wait);
      } catch (error) {
        Logs().w('[Push] count_sync_failed', error.runtimeType.toString());
      } finally {
        if (identical(_running[client], started)) _running[client] = null;
      }
    }();
    _running[client] = started;
    await started;
    return true;
  }
}

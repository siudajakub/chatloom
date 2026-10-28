// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:chatloom/personal/push_diagnostics.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One bounded catch-up `/sync` after a message push while the app is in
/// the background (2026-10-21), followed by alerts for the backlog it
/// delivered (2026-10-27).
///
/// Phones stop the sync loop in the background and rely on FCM to wake the
/// app. The push path only fetches the one event it shows and does not store
/// it, so tapping the notification used to open the chat before the resume
/// catch-up had delivered the message: it appeared a second or more later.
/// Telegram and Messenger fetch on the push instead. This sync runs right
/// after the push, while the radio is still awake from the event fetch (no
/// extra wake-up), and stores the message, the other chats' backlog, read
/// markers and keys, so the tap shows the chat as it is.
///
/// Missed pushes: FCM drops pushes it could not deliver in time (a night in
/// airplane mode) or beyond its queue (`onDeletedMessages`, forwarded as a
/// resync wake), and a push whose fetch failed shows at most a generic alert.
/// So the catch-up also follows a failed or generic push, and [notify] then
/// alerts for the unread messages the sync brought that no push showed
/// (`pushBacklogHelper`, with the push's own policy and [NotifiedMessages]).
///
/// Bounds: the server answers at once (`timeout=0`); a waiting long-poll of
/// a just-paused loop is dropped rather than joined; at most one catch-up
/// per [minInterval] per account (a burst of pushes is covered by the first
/// one, and the next push's event is then read from the database); the
/// caller waits at most [wait] for the sync and [notifyWait] for the alerts.
/// Nothing loops or repeats, and nothing runs without a push.
class PushCatchUp {
  PushCatchUp({
    this.minInterval = const Duration(seconds: 10),
    this.wait = const Duration(seconds: 15),
    this.notifyWait = const Duration(seconds: 20),
    this.notify,
    DateTime Function()? clock,
    @visibleForTesting Future<List<Event>?> Function(Client client)? sync,
  }) : _clock = clock ?? DateTime.now,
       _sync = sync ?? _restartSync;

  final Duration minInterval;
  final Duration wait;
  final Duration notifyWait;

  /// Alerts for the timeline events the sync delivered; returns how many
  /// notifications it showed. Not called after a failed sync.
  final Future<int> Function(Client client, List<Event> arrived)? notify;
  final DateTime Function() _clock;

  /// Syncs once; the timeline events the sync delivered (none for the
  /// account's first sync, whose history is not new), or null when it failed.
  final Future<List<Event>?> Function(Client client) _sync;
  final _last = Expando<DateTime>('push catch-up');
  final _running = Expando<Future<int?>>('push catch-up run');

  static Future<List<Event>?> _restartSync(Client client) async {
    // A first (initial) sync brings old history, never a missed message.
    final initial = client.prevBatch == null;
    final arrived = <Event>[];
    var synced = false;
    final events = client.onTimelineEvent.stream.listen(arrived.add);
    final syncs = client.onSync.stream.listen((_) => synced = true);
    try {
      // The SDK reports a failed sync on its status stream, never by
      // throwing; only a processed response reaches `onSync`.
      await client.restartSync(timeout: Duration.zero);
    } finally {
      await events.cancel();
      await syncs.cancel();
    }
    if (!synced) return null;
    return initial ? const <Event>[] : arrived;
  }

  /// Push outcomes followed by a catch-up: a message notification was shown,
  /// or the push's message could not be loaded (a generic alert or none).
  /// Silenced, read or own messages and test pushes are not.
  static const after = {
    PushOutcome.shown,
    PushOutcome.shownFallback,
    PushOutcome.fetchFailed,
    PushOutcome.timeout,
  };

  /// Whether a push with [outcome] is followed by a catch-up: one of [after]
  /// while the phone app is not in the foreground ([away]).
  static bool wanted(
    PushOutcome outcome, {
    required bool mobile,
    required AppLifecycleState? lifecycle,
  }) => after.contains(outcome) && away(mobile: mobile, lifecycle: lifecycle);

  /// The phone app is not on screen, so its sync loop is off.
  static bool away({
    required bool mobile,
    required AppLifecycleState? lifecycle,
  }) => mobile && lifecycle != AppLifecycleState.resumed;

  /// Starts (or joins) the catch-up of [client]; null when it is skipped.
  /// Completes with the number of backlog notifications shown, or null when
  /// the sync failed; within [wait] plus [notifyWait], and never throws.
  Future<int?>? run(Client client) {
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
    late final Future<int?> started;
    started = () async {
      try {
        // Future.sync: even a synchronous throw completes after `started`
        // was assigned, so `finally` can always compare it.
        final arrived = await Future<List<Event>?>.sync(
          () => _sync(client),
        ).timeout(wait);
        if (arrived == null) return null;
        final notify = this.notify;
        if (notify == null || arrived.isEmpty) return 0;
        return await Future<int>.sync(
          () => notify(client, arrived),
        ).timeout(notifyWait);
      } catch (error) {
        // Offline, timed out or rejected: the resume catch-up still runs.
        Logs().w('[Push] catch_up_sync_failed', error.runtimeType.toString());
        return null;
      } finally {
        if (identical(_running[client], started)) _running[client] = null;
      }
    }();
    _running[client] = started;
    return started;
  }
}

/// Message notifications this device already posted, by event, so each
/// message alerts at most once: a push for a message the catch-up backlog
/// already showed (or the same push delivered twice) stays silent, and a
/// notification the user dismissed is not posted again by a later
/// catch-up, also after the process restarted.
///
/// Kept as short one-way digests of account and event (no Matrix ids) in
/// the app's preferences, the newest [limit] only.
abstract final class NotifiedMessages {
  @visibleForTesting
  static const storeKey = 'chatloom.push.notified_messages';
  static const limit = 256;

  /// Oldest first.
  static final _digests = <String>{};
  static SharedPreferences? _store;
  static Future<void>? _loading;
  static Future<void> _saving = Future<void>.value();

  static String _digest(String clientName, String eventId) => sha256
      .convert(utf8.encode('$clientName\u0000$eventId'))
      .toString()
      .substring(0, 20);

  /// Reads the stored digests once per isolate; never throws.
  static Future<void> load(SharedPreferences store) {
    _store = store;
    return _loading ??= () async {
      try {
        final stored = store.getStringList(storeKey) ?? const <String>[];
        final known = Set<String>.of(_digests);
        _digests
          ..clear()
          ..addAll(stored)
          ..addAll(known);
        _trim();
      } catch (_) {}
    }();
  }

  static bool contains(String clientName, String eventId) =>
      _digests.contains(_digest(clientName, eventId));

  /// Records the event as notified; false when it already was.
  static bool claim(String clientName, String eventId) {
    final digest = _digest(clientName, eventId);
    if (!_digests.add(digest)) return false;
    _trim();
    _save();
    return true;
  }

  /// The notification could not be shown after [claim]: a later push or
  /// catch-up may show it.
  static void release(String clientName, String eventId) {
    if (_digests.remove(_digest(clientName, eventId))) _save();
  }

  static void _trim() {
    while (_digests.length > limit) {
      _digests.remove(_digests.first);
    }
  }

  static void _save() {
    final store = _store;
    if (store == null) return;
    final snapshot = _digests.toList();
    _saving = _saving
        .then((_) => store.setStringList(storeKey, snapshot))
        .then<void>((_) {}, onError: (Object _) {});
  }

  @visibleForTesting
  static Future<void> get saved => _saving;

  @visibleForTesting
  static void debugReset() {
    _digests.clear();
    _store = null;
    _loading = null;
    _saving = Future<void>.value();
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

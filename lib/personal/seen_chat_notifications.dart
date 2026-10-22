// SPDX-License-Identifier: AGPL-3.0-or-later

/// Clears a chat's system notification once the chat is read in the app.
///
/// Incognito (the default) sends no read receipt, so the server's unread state
/// never drops and the push path never learns that a chat was read. Telegram
/// and Messenger remove a chat's notifications as soon as it is read on any
/// surface; this does the same, purely locally: while a conversation page is
/// the current route, the app is in the foreground and unlocked, and the page
/// shows the newest message of its rooms (a merged person has several), their
/// notifications are cancelled and the group summary is updated. Nothing is
/// sent to the server, so the receipt and read-marker invariants hold.
///
/// Pages report themselves with one call from the place where they observe
/// what is seen ([seen]); coming back from the background or the lock screen
/// into an open chat clears it again.
///
/// A merged person has one notification for all its networks
/// (`notification_threads.dart`). It is cleared by a page that shows every
/// joined network of the person (the merged page); a page showing one
/// network clears only that network's own (pre-merge) notification, so
/// another network's unread lines stay in the shade.
library;

import 'dart:async';

import 'package:chatloom/personal/notification_threads.dart';
import 'package:chatloom/personal/person_location.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/utils/notification_client_routing.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/utils/push_helper.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart' show PersonGroup;

class _OpenConversation {
  final BuildContext context;
  List<Room> rooms;
  bool Function() atBottom;
  _OpenConversation(this.context, this.rooms, this.atBottom);
}

class _VisibilityObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) SeenChatNotifications._hide();
  }
}

abstract final class SeenChatNotifications {
  /// Test seam replacing the notification plugin.
  @visibleForTesting
  static FlutterLocalNotificationsPlugin Function()? debugPlugin;

  /// Test seam replacing [_surfaceVisible].
  @visibleForTesting
  static bool Function()? debugSurfaceVisible;

  /// Test seam: whether the Android group summary is maintained.
  @visibleForTesting
  static bool? debugUpdatesSummary;

  /// Test seam replacing [personGroupOf].
  @visibleForTesting
  static PersonGroup? Function(Room room)? debugGroupOf;

  /// The app is in the foreground and not behind the app lock.
  static bool _surfaceVisible() =>
      debugSurfaceVisible?.call() ??
      (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          PersonalPrivacy.surfaceUnlocked);

  /// A few recent pages; disposed ones are dropped on every pass.
  static const _maxOpen = 8;
  static final _open = <_OpenConversation>[];

  /// Notification id → `lastEventId|generation` already cleared, so a page
  /// that reports itself on every timeline update costs no platform call
  /// until a new message arrives or the app becomes visible again.
  static final _cleared = <int, String>{};
  static int _generation = 0;
  static bool _wasVisible = false;
  static bool _watching = false;
  static bool _scheduled = false;

  /// The conversation page at [context] shows [rooms]; [atBottom] tells
  /// whether their newest message is on screen. Coalesced into one check
  /// after the frame, when the page is still the current route.
  static void seen(
    BuildContext context,
    Iterable<Room> rooms, {
    required bool Function() atBottom,
  }) {
    if (kIsWeb) return;
    final list = List<Room>.unmodifiable(rooms);
    final existing = _open.firstWhereOrNull(
      (entry) => identical(entry.context, context),
    );
    if (existing != null) {
      existing
        ..rooms = list
        ..atBottom = atBottom;
    } else {
      _open.add(_OpenConversation(context, list, atBottom));
      if (_open.length > _maxOpen) _open.removeAt(0);
    }
    _watch();
    _schedule();
  }

  /// Whether a new message in [roomId] lands on a conversation the user is
  /// looking at, so its push stays silent like the open single chat. Covers
  /// merged person pages, whose route carries no room id.
  static bool isOpen(String clientName, String roomId) {
    if (kIsWeb || !_surfaceVisible()) return false;
    _prune();
    return _open.any(
      (entry) =>
          _current(entry.context) &&
          entry.rooms.any(
            (room) => room.id == roomId && room.client.clientName == clientName,
          ),
    );
  }

  static bool _current(BuildContext context) =>
      context.mounted && ModalRoute.of(context)?.isCurrent != false;

  static void _prune() => _open.removeWhere((entry) => !entry.context.mounted);

  static void _hide() => _wasVisible = false;

  /// Resume and unlock both show the open page again: detected on the first
  /// visible frame (the lock layer has no hook), with no work while hidden.
  static void _watch() {
    if (_watching) return;
    _watching = true;
    _wasVisible = _surfaceVisible();
    WidgetsBinding.instance.addObserver(_VisibilityObserver());
    SchedulerBinding.instance.addPersistentFrameCallback((_) {
      final visible = _surfaceVisible();
      if (visible && !_wasVisible) {
        _generation++;
        if (_open.isNotEmpty) _schedule();
      }
      _wasVisible = visible;
    });
  }

  static void _schedule() {
    if (_scheduled) return;
    // Already after layout (a page's own post-frame pass): check now rather
    // than paying for another frame.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.postFrameCallbacks) {
      _evaluate();
      return;
    }
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      _evaluate();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  static void _evaluate() {
    _prune();
    if (_open.isEmpty || !_surfaceVisible()) return;
    final due = <String, Set<int>>{};
    bool clear(String clientName, int id, String token) {
      if (_cleared[id] == token) return false;
      if (_cleared.length > 256) _cleared.clear();
      _cleared[id] = token;
      (due[clientName] ??= <int>{}).add(id);
      return true;
    }

    for (final entry in _open) {
      if (!_current(entry.context)) continue;
      bool bottom;
      try {
        bottom = entry.atBottom();
      } catch (_) {
        bottom = false;
      }
      if (!bottom) continue;
      final shown = {for (final room in entry.rooms) room.id};
      final people = <String>{};
      for (final room in entry.rooms) {
        final clientName = room.client.clientName;
        // The merge is looked up only when something new is seen here.
        if (!clear(
          clientName,
          messageNotificationId(clientName, room.id),
          '${room.lastEvent?.eventId}|$_generation',
        )) {
          continue;
        }
        final group = _groupOf(room);
        if (group == null || !people.add(group.id)) continue;
        final members = [
          for (final member in group.members)
            if (room.client.getRoomById(member.roomId) case final Room source
                when source.membership == Membership.join)
              source,
        ];
        if (!members.every((source) => shown.contains(source.id))) continue;
        clear(
          clientName,
          personNotificationId(clientName, group.id),
          '${members.map((source) => source.lastEvent?.eventId).join(',')}'
          '|$_generation',
        );
      }
    }
    for (final MapEntry(key: clientName, value: ids) in due.entries) {
      unawaited(_cancel(clientName, ids).catchError((Object _) {}));
    }
  }

  static PersonGroup? _groupOf(Room room) {
    try {
      return (debugGroupOf ?? personGroupOf)(room);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _cancel(String clientName, Set<int> ids) async {
    final notifications =
        debugPlugin?.call() ?? FlutterLocalNotificationsPlugin();
    NotificationThreads.forget(ids);
    Iterable<int> present;
    try {
      present = (await notifications.getActiveNotifications().timeout(
        const Duration(seconds: 2),
      )).map((n) => n.id).whereType<int>().where(ids.contains).toList();
    } catch (_) {
      // Without the query, cancelling an absent notification is a no-op.
      present = ids;
    }
    if (present.isEmpty) return;
    for (final id in present) {
      try {
        await notifications.cancel(id: id);
      } catch (_) {}
    }
    if (debugUpdatesSummary ?? PlatformInfos.isAndroid) {
      try {
        await updateSummaryNotification(
          flutterLocalNotificationsPlugin: notifications,
          clientName: clientName,
        );
      } catch (_) {}
    }
  }

  @visibleForTesting
  static void debugReset() {
    _open.clear();
    _cleared.clear();
    _generation = 0;
    _scheduled = false;
    _wasVisible = _surfaceVisible();
  }
}

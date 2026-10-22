// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:matrix/matrix.dart';

/// Telegram opens a chat with its messages already in place: the tap starts
/// reading the room's timeline from the local store, and the chat route is
/// pushed once it is ready (or after [maxWait]), so the page slides in with
/// its rows instead of a placeholder.
///
/// The SDK binds a timeline's callbacks when the timeline is created; a
/// preload forwards them to the chat page that adopts it. At most one preload
/// exists (the chat being opened); a newer one, or a chat that opens another
/// room, cancels it. Nothing is sent: opening a timeline only reads.
class ChatTimelinePreload {
  ChatTimelinePreload._(this.room) {
    future = Future.sync(
      () => room.getTimeline(
        onUpdate: () => _onUpdate?.call(),
        onInsert: (index) => _onInsert?.call(index),
      ),
    );
    future.then<void>((loaded) {
      if (_discarded) {
        loaded.cancelSubscriptions();
      } else {
        timeline = loaded;
      }
    }, onError: (Object _) {});
  }

  /// The longest a tap waits for the timeline before the route is pushed
  /// anyway (the chat then shows the timeline as soon as it arrives).
  static const Duration maxWait = Duration(milliseconds: 100);

  final Room room;
  late final Future<Timeline> future;

  /// The loaded timeline, once [future] completed.
  Timeline? timeline;

  void Function()? _onUpdate;
  void Function(int index)? _onInsert;
  bool _adopted = false;
  bool _discarded = false;

  static ChatTimelinePreload? _pending;

  /// Starts loading [room]'s timeline and completes when it is ready, after
  /// [wait] at the latest, or at once on an error (the chat then loads it
  /// itself and shows its own retry).
  static Future<void> warm(Room room, {Duration wait = maxWait}) async {
    _pending?.discard();
    final preload = _pending = ChatTimelinePreload._(room);
    try {
      await preload.future.timeout(wait);
    } catch (_) {
      // Too slow or failed: navigate anyway.
    }
  }

  /// The preload of [room], handed over to exactly one chat page.
  static ChatTimelinePreload? take(Room room) {
    final preload = _pending;
    if (preload == null) return null;
    _pending = null;
    if (preload.room.id != room.id ||
        !identical(preload.room.client, room.client)) {
      preload.discard();
      return null;
    }
    return preload;
  }

  /// Routes the timeline's SDK callbacks to the adopting chat.
  void adopt({
    required void Function() onUpdate,
    required void Function(int index) onInsert,
  }) {
    _adopted = true;
    _onUpdate = onUpdate;
    _onInsert = onInsert;
  }

  /// Cancels a preload that no chat adopts (it opened at an event).
  void discard() {
    if (_adopted) return;
    _discarded = true;
    timeline?.cancelSubscriptions();
    timeline = null;
  }
}

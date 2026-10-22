// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

/// Whether [room] may have a disappearing-message timer (the mautrix
/// `com.beeper.disappearing_timer` room state). Fail closed: anything but an
/// explicit "off" counts as on, and so does a state that is not loaded.
///
/// The SDK keeps only "important" state events in memory until a room is
/// post-loaded (its timeline opened, `Room.partial`), and the timer is not
/// one of them. Making it important would hide every timer already stored
/// outside the preloaded box, so a chat not opened in this session reads as
/// "no timer" although its stored state may say otherwise. Such a room
/// counts as disappearing until [loadRoomState] has read its state.
/// Automatic transcription and media prefetch use this; a chat the user
/// opened is always loaded.
bool roomMayDisappear(Room room) {
  final state = room.getState(beeperDisappearingTimerKey);
  if (state != null) return disappearingTimerLimits(state.content);
  return room.partial;
}

final _loading = Expando<Future<void>>();

/// Reads [room]'s stored state from the local database (what opening its
/// chat does; no network), so [roomMayDisappear] can decide. Joins a load
/// already running and never throws: after a failed read the room keeps
/// counting as disappearing until its chat is opened.
Future<void> loadRoomState(Room room) {
  if (!room.partial) return Future<void>.value();
  return _loading[room] ??= () async {
    try {
      await room.postLoad();
    } catch (_) {
      // Stays partial, i.e. fail closed.
    }
  }();
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';

/// Bridge info state of a portal room: mautrix bridgev2 sends `m.bridge` and
/// `uk.half-shot.bridge` (`Portal.getBridgeInfo`), Beeper also
/// `com.beeper.bridge`. All three are important state events
/// (`lib/utils/client_manager.dart`), so they are loaded with the room.
const bridgeInfoStateTypes = [
  'm.bridge',
  'uk.half-shot.bridge',
  'com.beeper.bridge',
];

/// Whether [room] is a bridge portal (a Telegram, WhatsApp, … chat seen
/// through Matrix). Its other members are the bridge bot and puppets of the
/// remote people, which can never take part in cross-signing verification.
/// Uses only loaded state and never touches encryption. A cleared (empty)
/// bridge info event does not count.
bool isBridgedRoom(Room room) {
  for (final type in bridgeInfoStateTypes) {
    final states = room.states[type];
    if (states == null) continue;
    for (final state in states.values) {
      if (state.content.isNotEmpty) return true;
    }
  }
  return false;
}

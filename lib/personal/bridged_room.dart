// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

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

Set<String> declaredBridgeBots(Room room) => {
  for (final type in bridgeInfoStateTypes)
    for (final state
        in room.states[type]?.values ?? const <StrippedStateEvent>[])
      if (state.content['bridgebot'] case final String bot when bot.isNotEmpty)
        bot,
};

bool isBridgeBotMember(Room room, String userId, {Set<String>? declared}) =>
    (declared ?? declaredBridgeBots(room)).contains(userId) ||
    room
            .getState(EventTypes.RoomMember, userId)
            ?.content['com.beeper.bridge.is_bridge_bot'] ==
        true;

/// Keep the server's totals with lazy members, subtracting only bots with
/// known membership. A fully loaded list can also count rooms without totals.
int humanParticipantCount(Room room, {bool includeInvited = false}) {
  final bots = declaredBridgeBots(room);
  int count(Membership membership, int? total) {
    final members = room.getParticipants([membership]);
    final botCount = members
        .where((member) => isBridgeBotMember(room, member.id, declared: bots))
        .length;
    return math.max(0, (total ?? members.length) - botCount);
  }

  return count(Membership.join, room.summary.mJoinedMemberCount) +
      (includeInvited
          ? count(Membership.invite, room.summary.mInvitedMemberCount)
          : 0);
}

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

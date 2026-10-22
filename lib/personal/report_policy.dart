// SPDX-License-Identifier: AGPL-3.0-or-later

/// Where "Report" is offered (copy-settings CS-24).
///
/// `reportEvent` / `reportUser` go to the admins of the account's homeserver.
/// For a bridged chat that is Beeper, not WhatsApp, Telegram or the other
/// network the message came from, and the bridges never forward a report.
/// "Report" therefore stays in native Matrix rooms only; "Block" (the ignore
/// list) is unaffected.
library;

import 'package:chatloom/personal/bridge_contact_search.dart'
    show discoverBridges;
import 'package:chatloom/personal/conversation_classification.dart'
    show canonicalNetwork;
import 'package:matrix/matrix.dart';

const _bridgeStateTypes = [
  'm.bridge',
  'uk.half-shot.bridge',
  'com.beeper.bridge',
];

/// Whether [room] is a bridge portal: any bridge info state that does not
/// name Matrix itself. Unknown networks count as bridged (a report would
/// still go to the homeserver, not to that network).
bool roomIsBridged(Room room) {
  for (final type in _bridgeStateTypes) {
    for (final info in room.states[type]?.values ?? <StrippedStateEvent>[]) {
      final protocol = info.content['protocol'];
      final id = protocol is Map ? protocol['id'] : null;
      final name = protocol is Map ? protocol['displayname'] : null;
      final network = canonicalNetwork(id) ?? canonicalNetwork(name);
      if (network != 'matrix') return true;
    }
  }
  return false;
}

/// "Report message" is offered in [room] (native Matrix rooms only).
bool canReportInRoom(Room room) => !roomIsBridged(room);

/// "Report user" is offered for [userId]: never for the account itself, a
/// bridge bot or a bridge ghost (puppet of a network contact), and never
/// inside a bridged [room]. Uses only local state.
bool canReportUser(Client client, String userId, {Room? room}) {
  if (userId == client.userID) return false;
  if (room != null && roomIsBridged(room)) return false;
  for (final bridge in discoverBridges(client.rooms)) {
    if (bridge.botId == userId || bridge.ownsGhost(userId)) return false;
  }
  // A one-to-one chat with this user that is bridged: also a network contact.
  final direct = client.getDirectChatFromUserId(userId);
  final directRoom = direct == null ? null : client.getRoomById(direct);
  return directRoom == null || !roomIsBridged(directRoom);
}

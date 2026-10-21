// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:matrix/matrix.dart';

/// Loads [room]'s member list in the background when its chat opens, so the
/// first send does not wait for a `/members` round trip in the trust check
/// (`showTrustUserInRoomDialog`, which runs before the message is stored)
/// or in the first encryption. The trust check itself stays where it is: it
/// asks before anything is stored, so a cancelled send leaves no bubble.
///
/// Only encrypted rooms whose list is not complete yet, and not large
/// groups (the SDK warns above 100 members). The SDK keeps the result (in
/// its database for encrypted rooms), so this runs about once per room.
void warmUpSendPath(Room room) {
  if (!room.encrypted || room.participantListComplete) return;
  final joined = room.summary.mJoinedMemberCount;
  if (joined != null && joined > 100) return;
  unawaited(
    room.requestParticipants().then<void>((_) {}, onError: (Object _) {}),
  );
}

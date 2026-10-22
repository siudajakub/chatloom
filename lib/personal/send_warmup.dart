// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/animation.dart';
import 'package:matrix/matrix.dart';

/// Loads [room]'s member list in the background when its chat opens, so the
/// first send does not wait for a `/members` round trip in the trust check
/// (`showTrustUserInRoomDialog`, which runs before the message is stored)
/// or in the first encryption. The trust check itself stays where it is: it
/// asks before anything is stored, so a cancelled send leaves no bubble.
///
/// Only encrypted rooms whose list is not complete yet, and not large
/// groups (the SDK warns above 100 members). The SDK keeps the result (in
/// its database for encrypted rooms, one transaction for the whole list),
/// so this runs about once per room. With the opening page's [route]
/// animation it starts once the slide has finished: the request and the
/// member writes then never compete with the first frames of the chat.
void warmUpSendPath(Room room, {Animation<double>? route}) {
  if (!room.encrypted || room.participantListComplete) return;
  final joined = room.summary.mJoinedMemberCount;
  if (joined != null && joined > 100) return;
  Future<void> load() =>
      room.requestParticipants().then<void>((_) {}, onError: (Object _) {});
  if (route == null || route.status != AnimationStatus.forward) {
    unawaited(load());
    return;
  }
  unawaited(
    _settled(route).then((_) {
      if (!room.participantListComplete) return load();
    }),
  );
}

/// Completes when [route] stops moving forward (the push transition ended),
/// at the latest after half a second, so a stalled animation never blocks.
Future<void> _settled(Animation<double> route) async {
  final settled = Completer<void>();
  void listener(AnimationStatus status) {
    if (status != AnimationStatus.forward && !settled.isCompleted) {
      settled.complete();
    }
  }

  route.addStatusListener(listener);
  try {
    await settled.future.timeout(
      const Duration(milliseconds: 500),
      onTimeout: () {},
    );
  } finally {
    route.removeStatusListener(listener);
  }
}

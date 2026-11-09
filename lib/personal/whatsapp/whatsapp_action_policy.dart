// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

import '../bridged_room.dart';
import '../capabilities.dart' show PersonalCapabilityUnavailable;

enum WhatsAppAction { createPoll, vote, endPoll, replyButton, listReply }

/// This release receives WhatsApp rich messages and opens web links. It
/// never sends poll or interactive replies, regardless of bridge support.
/// The room of the original event decides this policy, not a merged
/// composer's current sending source or a conversation's display name.
abstract final class WhatsAppActionPolicy {
  static const unavailableReason =
      'Open WhatsApp to create polls, vote or reply to buttons.';

  static bool isWhatsApp(Room room) {
    for (final type in bridgeInfoStateTypes) {
      for (final state
          in room.states[type]?.values ?? const <StrippedStateEvent>[]) {
        final protocol = state.content['protocol'];
        final id = protocol is Map ? protocol['id'] : null;
        if (id is String &&
            {'whatsapp', 'whatsappgo'}.contains(id.trim().toLowerCase())) {
          return true;
        }
      }
    }
    return false;
  }

  /// Other networks retain their existing capabilities and permissions.
  static bool allows(Room room, WhatsAppAction action) => switch (action) {
    // These new actions have no enabled sending implementation in v1,
    // including when source identity is unknown.
    WhatsAppAction.replyButton || WhatsAppAction.listReply => false,
    _ => !isWhatsApp(room),
  };

  static bool _containsMutation(Map content) {
    var current = content;
    for (var depth = 0; depth < 4; depth++) {
      if (current.containsKey(WhatsAppInteractiveContent.contentKey) ||
          _pollTypes.any(current.containsKey) ||
          _pollTypes.contains(current['msgtype'])) {
        return true;
      }
      final nested = current['m.new_content'];
      if (nested is! Map) return false;
      current = nested;
    }
    // Legitimate Matrix edits have one new_content level. Do not recurse
    // through arbitrary or cyclic maps on a request authorization path.
    return true;
  }

  /// Called before local echo and again immediately before transport, so a
  /// stale UI callback or a queued retry cannot bypass the release policy.
  static void authorizeOutgoing(
    Room room,
    String type,
    Map<String, dynamic> content,
  ) {
    if (!isWhatsApp(room)) return;
    if (_pollTypes.contains(type) ||
        type.startsWith('pl.personal.chat.whatsapp.') ||
        _containsMutation(content)) {
      throw const PersonalCapabilityUnavailable(unavailableReason);
    }
  }
}

const _pollTypes = {
  WhatsAppPollSnapshot.startKey,
  WhatsAppPollSnapshot.responseKey,
  'org.matrix.msc3381.poll.end',
  'm.poll.start',
  'm.poll.response',
  'm.poll.end',
};

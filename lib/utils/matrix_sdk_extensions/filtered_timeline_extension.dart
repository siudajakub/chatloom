// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/message_deletion.dart';
import 'package:chatloom/personal/message_delivery.dart';
import 'package:chatloom/personal/round_video/telegram_media_protocol.dart';
import 'package:matrix/matrix.dart';

extension VisibleInGuiExtension on List<Event> {
  List<Event> filterByVisibleInGui({
    String? exceptionEventId,
    String? threadId,
  }) => where((event) {
    if (threadId != null &&
        event.relationshipType != RelationshipTypes.reaction) {
      if ((event.relationshipType != RelationshipTypes.thread ||
              event.relationshipEventId != threadId) &&
          event.eventId != threadId) {
        return false;
      }
    } else if (event.relationshipType == RelationshipTypes.thread) {
      return false;
    }
    return event.isVisibleInGui || event.eventId == exceptionEventId;
  }).toList();
}

extension IsStateExtension on Event {
  bool get isVisibleInGui =>
      // always filter out edit and reaction relationships
      !const {
        RelationshipTypes.edit,
        RelationshipTypes.reaction,
      }.contains(relationshipType) &&
      // always filter out m.key.* and other known but unimportant events
      !isKnownHiddenStates &&
      // event types to hide: redaction and reaction events
      // if a reaction has been redacted we also want it to be hidden in the timeline
      !const {EventTypes.Reaction, EventTypes.Redaction}.contains(type) &&
      // if we enabled to hide all redacted events, don't show those
      (!AppSettings.hideRedactedEvents.value || !redacted) &&
      // if we enabled to hide all unknown events, don't show those
      (!AppSettings.hideUnknownEvents.value || isEventTypeKnown) &&
      // a message the user just deleted disappears at once
      !MessageDeletions.hides(this);

  bool get isState =>
      !const {EventTypes.Message, EventTypes.Sticker}.contains(type);

  /// Runs of these fold into one "more events" line. Encrypted events are
  /// messages waiting for a key, never folded state.
  bool get isCollapsedState => !const {
    EventTypes.Message,
    EventTypes.Sticker,
    EventTypes.Encrypted,
    EventTypes.RoomCreate,
    EventTypes.RoomTombstone,
  }.contains(type);

  bool get isKnownHiddenStates =>
      isTelegramMediaControl(type) ||
      type == PollEventContent.responseType ||
      // Bridge delivery reports render on the message they refer to.
      type == beeperMessageSendStatusType ||
      type.startsWith('m.key.verification.');
}

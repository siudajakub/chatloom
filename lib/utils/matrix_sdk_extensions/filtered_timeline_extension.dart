// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/message_deletion.dart';
import 'package:chatloom/personal/deleted_messages.dart';
import 'package:chatloom/personal/hidden_messages.dart';
import 'package:chatloom/personal/kept_messages.dart';
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
      // deleted messages (including one the user is deleting right now)
      // show as a placeholder unless they are hidden
      isDeletedShown &&
      // if we enabled to hide all unknown events, don't show those
      (!AppSettings.hideUnknownEvents.value || isEventTypeKnown) &&
      // "Remove for you": hidden in ChatLoom only (FX-16)
      !HiddenMessages.hides(this);

  /// False for a deleted message that is not drawn: Settings → Chats →
  /// "Hide deleted messages", or ChatLoom's own tidy-up of an undelivered
  /// message, reaction or edit ([MessageDeletions.isCleanup]). A message
  /// kept by "Keep deleted messages" is always drawn (with its content).
  bool get isDeletedShown {
    if (!isDeletedForDisplay(this)) return true;
    if (MessageDeletions.isCleanup(this)) return false;
    if (KeptMessages.of(this) != null) return true;
    return !AppSettings.hideRedactedEvents.value;
  }

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

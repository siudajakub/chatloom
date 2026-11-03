// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/personal/bridged_room.dart';
import 'package:matrix/matrix.dart';

const _bridgeMetadata = {
  ...bridgeInfoStateTypes,
  'com.beeper.room_features',
  'com.beeper.disappearing_timer',
  'io.element.functional_members',
};

bool _isBot(Room room, String? id) {
  if (id == null) return false;
  for (final type in bridgeInfoStateTypes) {
    for (final state in room.states[type]?.values ?? <StrippedStateEvent>[]) {
      if (state.content['bridgebot'] == id) return true;
    }
  }
  return room
          .getState(EventTypes.RoomMember, id)
          ?.content['com.beeper.bridge.is_bridge_bot'] ==
      true;
}

bool _permissionsChanged(Event event) {
  final before = event.prevContent;
  if (before == null || before.isEmpty) return false;
  int level(Map map, String key, int fallback) =>
      map[key] is int ? map[key] as int : fallback;
  for (final field in [
    'events_default',
    'state_default',
    'invite',
    'kick',
    'ban',
    'redact',
  ]) {
    final fallback = {'state_default', 'kick', 'ban', 'redact'}.contains(field)
        ? 50
        : 0;
    if (level(before, field, fallback) !=
        level(event.content, field, fallback)) {
      return true;
    }
  }
  final oldEvents = before['events'];
  final newEvents = event.content['events'];
  for (final type in [
    EventTypes.Message,
    EventTypes.RoomName,
    EventTypes.RoomTopic,
    EventTypes.RoomAvatar,
  ]) {
    final fallback = type == EventTypes.Message
        ? 'events_default'
        : 'state_default';
    final defaultLevel = type == EventTypes.Message ? 0 : 50;
    final oldLevel = level(before, fallback, defaultLevel);
    final newLevel = level(event.content, fallback, defaultLevel);
    if ((oldEvents is Map ? level(oldEvents, type, oldLevel) : oldLevel) !=
        (newEvents is Map ? level(newEvents, type, newLevel) : newLevel)) {
      return true;
    }
  }
  final oldUsers = before['users'];
  final newUsers = event.content['users'];
  final oldDefault = level(before, 'users_default', 0);
  final newDefault = level(event.content, 'users_default', 0);
  if (oldDefault != newDefault) return true;
  for (final id in {
    if (oldUsers is Map) ...oldUsers.keys.whereType<String>(),
    if (newUsers is Map) ...newUsers.keys.whereType<String>(),
  }) {
    if (_isBot(event.room, id)) continue;
    if ((oldUsers is Map ? level(oldUsers, id, oldDefault) : oldDefault) !=
        (newUsers is Map ? level(newUsers, id, newDefault) : newDefault)) {
      return true;
    }
  }
  return false;
}

/// Bridge bookkeeping is kept in the SDK but omitted from conversation rows.
/// Only state is eligible: a person's message never disappears because it
/// carries bridge metadata. Encryption, upgrades and actual removals survive.
bool isBridgeTimelineNoise(Event event) {
  if (event.stateKey == null || !isBridgedRoom(event.room)) return false;
  if ({EventTypes.Encryption, EventTypes.RoomTombstone}.contains(event.type)) {
    return false;
  }
  if (_bridgeMetadata.contains(event.type)) return true;
  if (event.content['com.beeper.exclude_from_timeline'] == true) return true;
  if ({EventTypes.RoomName, EventTypes.RoomAvatar}.contains(event.type) &&
      event.content['fi.mau.implicit_name'] == true) {
    return true;
  }
  if (event.type == EventTypes.RoomPowerLevels) {
    return _isBot(event.room, event.senderId) && !_permissionsChanged(event);
  }
  if (event.type != EventTypes.RoomMember) return false;
  if (_isBot(event.room, event.stateKey)) return true;
  final change = event.roomMemberChangeType;
  if ({
    RoomMemberChangeType.avatar,
    RoomMemberChangeType.displayname,
    RoomMemberChangeType.other,
  }.contains(change)) {
    return true;
  }
  // Remote joins use an invitation followed by a puppet accepting it. Only
  // the final join is useful; bootstrap joins carry the prior exclusion flag.
  if (change == RoomMemberChangeType.acceptInvite &&
      event.prevContent?['com.beeper.exclude_from_timeline'] == true) {
    return true;
  }
  if (change == RoomMemberChangeType.invite &&
      event.stateKey != event.room.client.userID &&
      (event.content['fi.mau.will_auto_accept'] == true ||
          _isBot(event.room, event.senderId))) {
    return true;
  }
  return false;
}

String _targetName(Event event) {
  if (event.stateKey == event.room.client.userID) return 'You';
  for (final value in [
    event.content['displayname'],
    event.room
        .getState(EventTypes.RoomMember, event.stateKey ?? '')
        ?.content['displayname'],
    event.prevContent?['displayname'],
  ]) {
    if (value is String && value.trim().isNotEmpty && !value.startsWith('@')) {
      return value.trim();
    }
  }
  return 'Someone';
}

/// Remote actions use the vocabulary of a chat, without bot names, Matrix
/// invitations or technical identifiers. Native Matrix rooms keep SDK copy.
String? bridgeStateText(Event event) {
  if (event.stateKey == null || !isBridgedRoom(event.room)) return null;
  switch (event.type) {
    case EventTypes.RoomMember:
      final name = _targetName(event);
      return switch (event.roomMemberChangeType) {
        RoomMemberChangeType.join ||
        RoomMemberChangeType.acceptInvite => '$name joined the chat',
        RoomMemberChangeType.invite =>
          name == 'You'
              ? 'You were invited to the chat'
              : '$name was added to the chat',
        RoomMemberChangeType.leave => '$name left the chat',
        RoomMemberChangeType.kick =>
          name == 'You'
              ? 'You were removed from the chat'
              : '$name was removed from the chat',
        RoomMemberChangeType.ban =>
          name == 'You'
              ? 'You were blocked from the chat'
              : '$name was blocked from the chat',
        RoomMemberChangeType.unban =>
          name == 'You'
              ? 'You can rejoin the chat'
              : '$name can rejoin the chat',
        RoomMemberChangeType.rejectInvite => '$name declined the invitation',
        RoomMemberChangeType.withdrawInvitation =>
          'An invitation was cancelled',
        RoomMemberChangeType.knock => '$name requested to join the chat',
        _ => 'Contact updated',
      };
    case EventTypes.RoomPowerLevels:
      return 'Chat permissions updated';
    case EventTypes.RoomName:
      final name = event.content['name'];
      return name is String && name.trim().isNotEmpty
          ? 'Chat renamed to $name'
          : 'Chat name updated';
    case EventTypes.RoomTopic:
      return 'Chat description updated';
    case EventTypes.RoomAvatar:
      return 'Chat photo updated';
    case EventTypes.RoomCreate:
      return 'Chat connected';
    case EventTypes.RoomJoinRules:
    case EventTypes.GuestAccess:
    case EventTypes.HistoryVisibility:
      return 'Chat settings updated';
    default:
      return null;
  }
}

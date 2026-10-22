// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/bridge_contact_search.dart' show searchFold;
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/private_avatar.dart'
    show personAvatarSourcePrefix;
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:uuid/uuid.dart';

/// One row of the merge picker: an ordinary chat or an already merged person
/// (all of its sources join the merge together).
class MergeCandidate {
  /// Inbox entity: a room id or `person:<group id>`.
  final String entityId;
  final Room representative;
  final List<Room> sources;
  final PersonGroup? group;
  final String name;
  final Set<String> networks;
  final DateTime? lastActivity;
  final String _search;

  MergeCandidate._({
    required this.entityId,
    required this.representative,
    required this.sources,
    required this.group,
    required this.name,
    required this.networks,
    required this.lastActivity,
    required String search,
  }) : _search = search;

  /// Case-insensitive match on the shown (private) name, every source's
  /// network name and the network itself. Local only: nothing is sent.
  bool matches(String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+'))
      ..removeWhere((word) => word.isEmpty);
    return words.every(_search.contains);
  }

  @override
  String toString() => 'MergeCandidate(redacted)';
}

/// Chats and merged persons of the active account that can be merged with
/// [anchor] (whose own entity is left out). Only joined one-to-one chats
/// ([InboxProjection.mergeable]); network groups, bot-only technical rooms,
/// spaces and the private journal never appear. Newest activity first.
List<MergeCandidate> mergeCandidates(PersonalClient personal, {Room? anchor}) {
  final projection = InboxProjection.snapshot(personal);
  final client = personal.client;
  final index = projection.buildIndex(client.rooms);
  final excluded = anchor == null ? null : projection.entityFor(anchor);
  final result = <MergeCandidate>[];
  for (final record in index.records) {
    if (record.technical || record.entityId == excluded) continue;
    final representative = client.getRoomById(record.representativeRoomId);
    if (representative == null) continue;
    final group = projection.groupFor(representative);
    final sources = group == null
        ? [representative]
        : projection.activeSourcesOf(group);
    if (sources.isEmpty || !sources.every(InboxProjection.mergeable)) continue;
    final search = [
      record.displayName,
      ?group?.name,
      for (final source in sources) source.getLocalizedDisplayname(),
      for (final network in record.networks) ...[
        network,
        notionNetworkLabel(network),
      ],
    ].join('\n').toLowerCase();
    result.add(
      MergeCandidate._(
        entityId: record.entityId,
        representative: representative,
        sources: sources,
        group: group,
        name: record.displayName,
        networks: record.networks,
        lastActivity: record.lastActivity,
        search: search,
      ),
    );
  }
  result.sort((a, b) {
    final at = a.lastActivity, bt = b.lastActivity;
    if (at == null || bt == null) {
      return at == bt ? a.name.compareTo(b.name) : (at == null ? 1 : -1);
    }
    final byTime = bt.compareTo(at);
    return byTime != 0 ? byTime : a.name.compareTo(b.name);
  });
  return result;
}

/// What a merge writes. [group] is saved; [absorbed] persons (other merged
/// persons that were selected) are unmerged because all of their sources
/// now belong to [group]. [previous] restores the state on undo.
class MergePlan {
  final PersonGroup group;
  final PersonGroup? previous;
  final List<PersonGroup> absorbed;
  const MergePlan._(this.group, this.previous, this.absorbed);
  bool get createsGroup => previous == null;
  @override
  String toString() => 'MergePlan(redacted)';
}

/// Unites [rooms] (and the persons they already belong to) into one person.
/// The person of [anchor] (else the first selected person) keeps its id,
/// so its private nickname, pins and rules stay attached. Chats that were
/// left keep their place (they return when joined again); a chat of such a
/// person that is no longer a one-to-one chat is dropped, so merging again
/// repairs it. Throws [ArgumentError] for fewer than two sources or a
/// source that cannot be merged (see [InboxProjection.mergeable]).
MergePlan planMerge(
  PersonalClient personal,
  List<Room> rooms, {
  Room? anchor,
  String? name,
}) {
  final client = personal.client;
  final ordered = [?anchor, ...rooms.where((room) => room.id != anchor?.id)];
  if (ordered.any(
    (room) =>
        !identical(room.client, client) || !InboxProjection.mergeable(room),
  )) {
    throw ArgumentError('A selected chat cannot be merged');
  }
  // Every saved person that contains a selected chat, the anchor's first.
  final saved = personal.groups;
  final involved = <PersonGroup>[];
  for (final room in ordered) {
    for (final group in saved) {
      if (!involved.any((known) => known.id == group.id) &&
          group.members.any((member) => member.roomId == room.id)) {
        involved.add(group);
      }
    }
  }
  bool unsafe(ConversationRef member) {
    final room = client.getRoomById(member.roomId);
    return room != null &&
        room.membership == Membership.join &&
        !InboxProjection.mergeable(room);
  }

  final members = <String, ConversationRef>{};
  for (final group in involved) {
    for (final member in group.members) {
      if (unsafe(member)) continue;
      members.putIfAbsent(member.roomId, () => member);
    }
  }
  for (final room in ordered) {
    members.putIfAbsent(room.id, () => personal.ref(room));
  }
  if (members.length < 2) throw ArgumentError('Select another chat');
  final target = involved.firstOrNull;
  final trimmed = name?.trim();
  final previousDefault = target?.defaultRoomId;
  final group = PersonGroup(
    id: target?.id ?? const Uuid().v4(),
    name: trimmed?.isNotEmpty == true
        ? trimmed!
        : target?.name ?? InboxProjection(personal).displayName(ordered.first),
    members: members.values.toList(),
    defaultRoomId:
        previousDefault != null && members.containsKey(previousDefault)
        ? previousDefault
        : ordered.first.id,
    revision: target?.revision ?? 0,
  );
  return MergePlan._(group, target, involved.skip(1).toList());
}

/// How often an absorbed person's removal is tried in the background (each
/// attempt waits for the worker's acknowledgement, see
/// [PersonalClient.removeGroup]).
const _absorbAttempts = 3;

/// Writes [plan]; the merged person is visible as soon as the private store
/// accepted the change (before the worker acknowledges it).
///
/// Absorbed persons are hidden at once: their chats now belong to the
/// larger person ([resolvePersonGroups]), so even when their removal has to
/// wait for an earlier acknowledgement, or fails while the worker is
/// offline, neither person falls apart (CC-14). The removal is retried in
/// the background; a leftover shows in People settings with Clean up.
Future<void> applyMerge(PersonalClient personal, MergePlan plan) async {
  await personal.putGroup(plan.group);
  for (final group in plan.absorbed) {
    unawaited(_removeAbsorbed(personal, plan.group, group.id));
  }
}

Future<void> _removeAbsorbed(
  PersonalClient personal,
  PersonGroup target,
  String absorbedId,
) async {
  for (var attempt = 0; attempt < _absorbAttempts; attempt++) {
    // Undone meanwhile (the target lost the absorbed chats): keep it.
    final current = personal.groups.where((g) => g.id == target.id);
    if (current.isEmpty ||
        current.first.members.length < target.members.length) {
      return;
    }
    try {
      await personal.removeGroup(absorbedId);
      return;
    } catch (_) {
      // Still hidden behind the larger person; try again.
    }
  }
  Logs().w('A merged person could not be cleaned up after a merge');
}

/// Reverts [plan]: a new person is unmerged, an extended one gets its
/// previous sources back, absorbed persons are restored.
Future<void> undoMerge(PersonalClient personal, MergePlan plan) async {
  final previous = plan.previous;
  if (previous == null) {
    await personal.removeGroup(plan.group.id);
  } else {
    await personal.putGroup(previous);
  }
  for (final group in plan.absorbed) {
    await personal.putGroup(group);
  }
}

// ---------------------------------------------------------------------------
// Person editing (sources, routing, name, photo, notifications). Every write
// is private, end-to-end encrypted metadata; no room, message or account
// changes. Preferences live in their own keys (`person-prefs:<id>`, the
// person's `org:` metadata), never as new fields of the `person:<id>` group:
// older builds rewrite that JSON without fields they do not know.

/// Adds [rooms] to [group] (persons they belong to are absorbed). The
/// person's first active chat anchors the merge, so its id is kept.
MergePlan planAddToPerson(
  PersonalClient personal,
  PersonGroup group,
  List<Room> rooms,
) {
  final anchor = InboxProjection(personal).activeSourcesOf(group).firstOrNull;
  if (anchor != null) {
    return planMerge(personal, [anchor, ...rooms], anchor: anchor);
  }
  // None of its chats is joined right now (all left or replaced): extend
  // the saved person directly, absorbing persons of the added chats.
  if (rooms.isEmpty ||
      rooms.any(
        (room) =>
            !identical(room.client, personal.client) ||
            !InboxProjection.mergeable(room),
      )) {
    throw ArgumentError('A selected chat cannot be merged');
  }
  final saved = personal.groups;
  final current = saved.where((g) => g.id == group.id).firstOrNull ?? group;
  final absorbed = [
    for (final other in saved)
      if (other.id != current.id &&
          other.members.any((m) => rooms.any((room) => room.id == m.roomId)))
        other,
  ];
  final next = current.withSources([
    for (final other in absorbed) ...other.members,
    for (final room in rooms) personal.ref(room),
  ]);
  return MergePlan._(
    next.withDefaultSource(rooms.first.id),
    current,
    absorbed,
  );
}

/// Removes the chat [roomId] from [group] and returns the saved person, or
/// null when only one chat was left and the person was unmerged. The chat,
/// its messages and the person's private settings are kept.
Future<PersonGroup?> removePersonSource(
  PersonalClient personal,
  PersonGroup group,
  String roomId,
) async {
  final active = InboxProjection(personal)
      .activeSourcesOf(group)
      .where((room) => room.id != roomId)
      .firstOrNull;
  final next = group.withoutSource(roomId, preferredDefault: active?.id);
  if (next == null) {
    await personal.removeGroup(group.id);
    return null;
  }
  await personal.putGroup(next);
  return next;
}

/// Makes [roomId] the person's default chat (the fallback of automatic
/// routing and the target of `Always <network>`).
Future<PersonGroup> setPersonDefaultSource(
  PersonalClient personal,
  PersonGroup group,
  String roomId,
) async {
  final next = group.withDefaultSource(roomId);
  if (!identical(next, group)) await personal.putGroup(next);
  return next;
}

Future<void> _putPreferences(
  PersonalClient personal,
  String groupId,
  PersonPreferences Function(PersonPreferences current) change,
) async {
  final key = personPreferencesKey(groupId);
  final previous = personal.values[key];
  final current = PersonPreferences.fromJson(previous);
  await personal.put(key, change(current).toJson(previous));
}

/// "Automatic" or, with [PersonRouting.fixed], "Always" the network of
/// [defaultRoomId] (or of the current default chat).
Future<void> setPersonRouting(
  PersonalClient personal,
  PersonGroup group,
  PersonRouting routing, {
  String? defaultRoomId,
}) async {
  if (defaultRoomId != null) {
    await setPersonDefaultSource(personal, group, defaultRoomId);
  }
  if (InboxProjection(personal).preferencesFor(group.id).routing != routing) {
    await _putPreferences(
      personal,
      group.id,
      (current) => current.copyWith(routing: routing),
    );
  }
}

Future<void> _putMetadata(
  PersonalClient personal,
  String entity,
  ConversationMetadata Function(ConversationMetadata current) change,
) async {
  final current = InboxProjection(personal).metadataForEntity(entity);
  // Archive markers and unknown fields of other builds stay.
  await personal.put(
    'org:$entity',
    {
      ...?personal.values['org:$entity'],
      ...change(current).toJson(),
    }.cast<String, dynamic>(),
  );
}

/// A private custom name for the person; null or blank goes back to the
/// person's network or saved name.
Future<void> setPersonNickname(
  PersonalClient personal,
  PersonGroup group,
  String? name,
) async {
  final entity = 'person:${group.id}';
  final trimmed = name?.trim() ?? '';
  final value = trimmed.isEmpty ? null : trimmed;
  await _putMetadata(personal, entity, (current) => current.setNickname(value));
  // The legacy hook other builds still read, including an explicit reset.
  await personal.put('nickname:$entity', {'name': value ?? ''});
}

/// Names the person after the chat [roomId]: its current network name, also
/// after the contact renames. The saved name follows for builds that
/// predate this choice.
Future<void> usePersonSourceName(
  PersonalClient personal,
  PersonGroup group,
  String roomId,
) async {
  if (!group.members.any((m) => m.roomId == roomId)) {
    throw ArgumentError('Unknown group member');
  }
  final entity = 'person:${group.id}';
  final legacy = personal.values['nickname:$entity']?['name'];
  final hasNickname =
      InboxProjection(personal).metadataForEntity(entity).nickname != null ||
      (legacy is String && legacy.trim().isNotEmpty);
  if (hasNickname) await setPersonNickname(personal, group, null);
  await _putPreferences(
    personal,
    group.id,
    (current) => current.copyWith(nameRoomId: () => roomId),
  );
  final live = personal.client.getRoomById(roomId)?.getLocalizedDisplayname();
  if (live != null && live.trim().isNotEmpty && live.trim() != group.name) {
    await personal.putGroup(group.withName(live));
  }
}

/// Back to the name saved with the person (no custom name, no network).
Future<void> usePersonSavedName(
  PersonalClient personal,
  PersonGroup group,
) async {
  final entity = 'person:${group.id}';
  final legacy = personal.values['nickname:$entity']?['name'];
  if (InboxProjection(personal).metadataForEntity(entity).nickname != null ||
      (legacy is String && legacy.trim().isNotEmpty)) {
    await setPersonNickname(personal, group, null);
  }
  if (InboxProjection(personal).preferencesFor(group.id).nameRoomId != null) {
    await _putPreferences(
      personal,
      group.id,
      (current) => current.copyWith(nameRoomId: () => null),
    );
  }
}

/// Changes the private `org:` metadata of the person (pin, low priority,
/// ignore, colours). Archive markers and unknown fields stay.
Future<void> updatePersonMetadata(
  PersonalClient personal,
  PersonGroup group,
  ConversationMetadata Function(ConversationMetadata current) change,
) => _putMetadata(personal, 'person:${group.id}', change);

/// Pins the person at the end of the pinned list, or unpins it.
Future<void> setPersonPinned(
  PersonalClient personal,
  PersonGroup group,
  bool pinned,
) {
  final orders = personal.values.entries
      .where((e) => e.key.startsWith('org:'))
      .map((e) => e.value['pinOrder'])
      .whereType<int>();
  final next = orders.isEmpty ? 0 : orders.reduce((a, b) => a > b ? a : b) + 1;
  return updatePersonMetadata(
    personal,
    group,
    (current) => current.setPin(pinned ? (current.pinOrder ?? next) : null),
  );
}

/// Archives the person privately (new activity in any of its chats brings
/// it back), or returns it to the inbox.
Future<void> setPersonArchived(
  PersonalClient personal,
  PersonGroup group,
  bool archived,
) async {
  final entity = 'person:${group.id}';
  final projection = InboxProjection(personal);
  final current = projection.metadataForEntity(entity);
  final previous = {...?personal.values['org:$entity']}
    ..remove('archivedAt')
    ..remove('archiveSources');
  await personal.put(
    'org:$entity',
    {
      ...previous,
      ...current.setArchived(archived).toJson(),
      if (archived) ...{
        'archivedAt': DateTime.now().toUtc().toIso8601String(),
        'archiveSources': {
          for (final room in projection.activeSourcesOf(group))
            room.id: room.lastEvent?.eventId,
        },
      },
    }.cast<String, dynamic>(),
  );
}

/// The person's photo: the network photo of [roomId], or (null) the
/// automatic one; a private photo, when set, is the automatic one.
Future<void> setPersonAvatarSource(
  PersonalClient personal,
  PersonGroup group,
  String? roomId,
) async {
  if (roomId != null && !group.members.any((m) => m.roomId == roomId)) {
    throw ArgumentError('Unknown group member');
  }
  await _putMetadata(
    personal,
    'person:${group.id}',
    (current) => current.setAvatar(
      roomId == null ? null : '$personAvatarSourcePrefix$roomId',
    ),
  );
}

/// The notification mode of the whole person (all of its chats); null
/// follows the network defaults. A chat's own override still wins.
Future<void> setPersonNotificationMode(
  PersonalClient personal,
  PersonGroup group,
  PersonalNotificationMode? mode,
) => _putMetadata(
  personal,
  'person:${group.id}',
  (current) => current.setNotificationMode(mode),
);

/// Overrides the person's mode for the chat [roomId]; null follows the
/// person.
Future<void> setPersonSourceNotificationMode(
  PersonalClient personal,
  String roomId,
  PersonalNotificationMode? mode,
) => _putMetadata(
  personal,
  roomId,
  (current) => current.setNotificationMode(mode),
);

/// Search text of a merged person beyond its shown name: the saved name and
/// every source's network name and network (FT-08). Empty for an ordinary
/// chat.
String personSearchText(InboxProjection projection, InboxRecord record) {
  if (!record.entityId.startsWith('person:')) return '';
  final group = projection.groupById(
    record.entityId.substring('person:'.length),
  );
  if (group == null) return '';
  return [
    group.name,
    for (final room in projection.activeSourcesOf(group))
      room.getLocalizedDisplayname(),
    for (final network in record.networks) notionNetworkLabel(network),
  ].join(' ');
}

// ---------------------------------------------------------------------------
// Merge suggestions (FT-09): local only, dismissible, never applied by
// themselves.

/// Phone numbers a bridge exposes for the other person of [room] in its
/// local member state (`com.beeper.bridge.identifiers`, `tel:` entries),
/// digits only. Nothing is fetched.
Set<String> bridgePhoneNumbers(Room room) {
  final own = room.client.userID;
  final result = <String>{};
  final members = room.states[EventTypes.RoomMember];
  if (members == null) return result;
  for (final entry in members.entries) {
    if (entry.key == own) continue;
    final content = entry.value.content;
    if (content['com.beeper.bridge.is_bridge_bot'] == true) continue;
    final identifiers = content['com.beeper.bridge.identifiers'];
    if (identifiers is! List) continue;
    for (final value in identifiers.whereType<String>()) {
      if (!value.startsWith('tel:')) continue;
      final digits = value.substring(4).replaceAll(RegExp(r'\D'), '');
      if (digits.length >= 7) result.add(digits);
    }
  }
  return result;
}

/// Suggested merges of the active account: chats and persons on different
/// networks with the same name or phone number. With [anchor] only pairs
/// that include its conversation.
List<MergeSuggestion> personMergeSuggestions(
  PersonalClient personal, {
  Room? anchor,
  int limit = 20,
}) {
  if (!personal.ready) return const [];
  final projection = InboxProjection.snapshot(personal);
  final client = personal.client;
  final index = projection.buildIndex(client.rooms);
  final candidates = <MergeSuggestionCandidate>[];
  for (final record in index.records) {
    if (record.technical ||
        record.isGroup ||
        record.metadata.ignored ||
        record.placement == ChatPlacement.ignored) {
      continue;
    }
    final representative = client.getRoomById(record.representativeRoomId);
    if (representative == null) continue;
    final group = projection.groupFor(representative);
    final sources = group == null
        ? [representative]
        : projection.activeSourcesOf(group);
    if (sources.isEmpty || !sources.every(InboxProjection.mergeable)) continue;
    candidates.add(
      MergeSuggestionCandidate(
        entityId: record.entityId,
        networks: record.networks,
        names: {
          searchFold(record.displayName),
          for (final source in sources)
            searchFold(source.getLocalizedDisplayname()),
        },
        phones: {for (final source in sources) ...bridgePhoneNumbers(source)},
        lastActivity: record.lastActivity,
      ),
    );
  }
  final dismissed = {
    for (final key in personal.values.keys)
      if (key.startsWith('merge-dismissed:')) key,
  };
  final all = mergeSuggestions(
    candidates,
    dismissed: dismissed,
    limit: anchor == null ? limit : candidates.length,
  );
  if (anchor == null) return all;
  final entity = projection.entityFor(anchor);
  return [
    for (final suggestion in all)
      if (suggestion.first.entityId == entity ||
          suggestion.second.entityId == entity)
        suggestion,
  ].take(limit).toList();
}

/// Remembers (privately, synced) that [suggestion] is not wanted.
Future<void> dismissMergeSuggestion(
  PersonalClient personal,
  MergeSuggestion suggestion,
) => personal.put(suggestion.dismissKey, {
  'dismissedAt': DateTime.now().toUtc().toIso8601String(),
});

/// The rooms of one side of a suggestion (a chat, or a person's active
/// chats), resolved now; empty when it changed meanwhile.
List<Room> suggestionRooms(
  PersonalClient personal,
  MergeSuggestionCandidate side,
) {
  final projection = InboxProjection(personal);
  final id = side.entityId;
  if (id.startsWith('person:')) {
    final group = projection.groupById(id.substring('person:'.length));
    return group == null ? const [] : projection.activeSourcesOf(group);
  }
  final room = personal.client.getRoomById(id);
  return room != null && InboxProjection.mergeable(room) ? [room] : const [];
}

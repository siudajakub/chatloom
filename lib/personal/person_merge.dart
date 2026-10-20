// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/personal_client.dart';
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
        : group.members
              .map((member) => client.getRoomById(member.roomId))
              .whereType<Room>()
              .toList();
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
/// so its private nickname, pins and rules stay attached. Throws
/// [ArgumentError] for fewer than two sources or a source that cannot be
/// merged (see [InboxProjection.mergeable]).
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
  final members = <String, ConversationRef>{};
  for (final group in involved) {
    for (final member in group.members) {
      members.putIfAbsent(member.roomId, () => member);
    }
  }
  for (final room in ordered) {
    members.putIfAbsent(room.id, () => personal.ref(room));
  }
  if (members.length < 2) throw ArgumentError('Select another chat');
  final target = involved.firstOrNull;
  final trimmed = name?.trim();
  final group = PersonGroup(
    id: target?.id ?? const Uuid().v4(),
    name: trimmed?.isNotEmpty == true
        ? trimmed!
        : target?.name ?? InboxProjection(personal).displayName(ordered.first),
    members: members.values.toList(),
    defaultRoomId: target?.defaultRoomId ?? ordered.first.id,
    revision: target?.revision ?? 0,
  );
  return MergePlan._(group, target, involved.skip(1).toList());
}

/// Writes [plan]; the merged person is visible as soon as the private store
/// accepted the change (before the worker acknowledges it).
Future<void> applyMerge(PersonalClient personal, MergePlan plan) async {
  await personal.putGroup(plan.group);
  for (final group in plan.absorbed) {
    // Hidden at once; the delete may wait for an earlier acknowledgement.
    personal.removeGroup(group.id).ignore();
  }
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

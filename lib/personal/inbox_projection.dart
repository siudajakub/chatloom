// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/privacy.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

export 'package:personal_core/personal_core.dart' show InboxFilter, InboxRecord;

/// Private inbox presentation. It never changes native room membership/state.
class InboxProjection {
  final PersonalClient personal;
  InboxProjection(this.personal);

  static String? _text(Object? value) => value is String ? value : null;

  List<PersonGroup> get _validGroups {
    final parsed = <PersonGroup>[];
    for (final group in personal.groups) {
      if (group.members.every(
        (m) =>
            m.accountId == personal.client.userID &&
            personal.client.getRoomById(m.roomId)?.isDirectChat == true &&
            personal.client.getRoomById(m.roomId)?.membership ==
                Membership.join,
      )) {
        parsed.add(group);
      }
    }
    final counts = <String, int>{};
    for (final group in parsed) {
      for (final member in group.members) {
        counts.update(member.roomId, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    return parsed
        .where((g) => g.members.every((m) => counts[m.roomId] == 1))
        .toList();
  }

  PersonGroup? groupFor(Room room) {
    for (final group in _validGroups) {
      if (group.members.any((m) => m.roomId == room.id)) return group;
    }
    return null;
  }

  String entityFor(Room room) {
    final group = groupFor(room);
    return group == null ? room.id : 'person:${group.id}';
  }

  String metadataKey(Room room) => 'org:${entityFor(room)}';
  ConversationMetadata metadataFor(Room room) =>
      metadataForEntity(entityFor(room));
  ConversationMetadata metadataForEntity(String entity) {
    final value = personal.values['org:$entity'];
    if (value != null) {
      try {
        final metadata = ConversationMetadata.fromJson({
          ...value,
          'entityId': entity,
        });
        final sources = value['archiveSources'];
        if (metadata.archived &&
            sources is Map &&
            sources.entries.any((entry) {
              final latest = personal.client
                  .getRoomById(entry.key as String)
                  ?.lastEvent;
              return latest != null && latest.eventId != entry.value;
            })) {
          return metadata.onActivity();
        }
        final roomIds = entity.startsWith('person:')
            ? _validGroups
                  .where((g) => 'person:${g.id}' == entity)
                  .expand((g) => g.members.map((m) => m.roomId))
                  .toSet()
            : {entity};
        if (metadata.archived && roomIds.any(_dueRoomIds().contains)) {
          return metadata.onActivity();
        }
        return metadata;
      } catch (_) {}
    }
    return ConversationMetadata(entityId: entity);
  }

  Set<String> _dueRoomIds() {
    final result = <String>{};
    for (final reminder in personal.reminders.values.where(
      (r) => r['state'] == 'done',
    )) {
      try {
        final ref = ConversationRef.fromJson(
          Map<String, dynamic>.from(reminder['conversation'] as Map),
        );
        if (ref.accountId != personal.client.userID) continue;
        final room = personal.client.getRoomById(ref.roomId);
        if (room == null) continue;
        final group = groupFor(room);
        final entity = group == null ? room.id : 'person:${group.id}';
        final archived = personal.values['org:$entity']?['archivedAt'];
        final archivedAt = archived is String
            ? DateTime.tryParse(archived)
            : null;
        final due = reminder['dueAt'];
        final dueAt = due is String ? DateTime.tryParse(due) : null;
        if (dueAt == null ||
            (archivedAt != null && !dueAt.isAfter(archivedAt))) {
          continue;
        }
        result.add(ref.roomId);
      } catch (_) {}
    }
    return result;
  }

  Set<String> labelsFor(Room room) {
    final entity = entityFor(room);
    final group = groupFor(room);
    return {
      if (personal.values.containsKey('labels:$entity'))
        ..._legacyLabels(entity)
      else ...[
        ...metadataForEntity(entity).labelIds,
        if (group != null)
          for (final member in group.members) ..._legacyLabels(member.roomId),
      ],
    }.where(personal.values.containsKey).toSet();
  }

  Iterable<String> _legacyLabels(String entity) {
    final value = personal.values['labels:$entity']?['labels'];
    return value is List ? value.whereType<String>() : const [];
  }

  String displayName(Room room) {
    final group = groupFor(room);
    final entity = entityFor(room);
    final override =
        metadataForEntity(entity).nickname ??
        _text(personal.values['nickname:$entity']?['name']);
    return override?.trim().isNotEmpty == true
        ? override!
        : group?.name ?? room.getLocalizedDisplayname();
  }

  int unreadCount(Room room) {
    final group = groupFor(room);
    if (group == null) return room.notificationCount;
    return group.members
        .map((m) => personal.client.getRoomById(m.roomId))
        .whereType<Room>()
        .fold(0, (count, r) => count + r.notificationCount);
  }

  bool get hasDraftConflicts =>
      personal.conflicts.keys.any((k) => k.startsWith('draft:'));

  List<Room> rooms(
    Iterable<Room> input, {
    InboxFilter filter = InboxFilter.inbox,
    String query = '',
    String? labelKey,
  }) {
    final available = {
      for (final room in input.where(
        (r) => !r.isSpace && !PersonalPrivacy.isJournal(r),
      ))
        room.id: room,
    };
    final groups = _validGroups;
    final members = <String, PersonGroup>{};
    for (final group in groups) {
      // A network group room can never be hidden by an invalid DM merge.
      if (group.members.every(
        (m) => available[m.roomId]?.isDirectChat == true,
      )) {
        for (final member in group.members) {
          members[member.roomId] = group;
        }
      }
    }
    final emitted = <String>{};
    final records = <InboxRecord>[];
    final representatives = <String, Room>{};
    for (final room in available.values) {
      final group = members[room.id];
      final entity = group == null ? room.id : 'person:${group.id}';
      if (!emitted.add(entity)) continue;
      final sourceRooms = group == null
          ? [room]
          : group.members.map((m) => available[m.roomId]!).toList();
      final representative = group == null
          ? room
          : available[group.defaultRoomId] ?? sourceRooms.first;
      final lastEvents =
          sourceRooms.map((r) => r.lastEvent).whereType<Event>().toList()
            ..sort((a, b) => b.originServerTs.compareTo(a.originServerTs));
      final latest = lastEvents.firstOrNull;
      final metadata = metadataForEntity(entity);
      final nickname =
          metadata.nickname ??
          _text(personal.values['nickname:$entity']?['name']);
      final title = nickname?.trim().isNotEmpty == true
          ? nickname!
          : group?.name ?? room.getLocalizedDisplayname();
      final labels = personal.values.containsKey('labels:$entity')
          ? _legacyLabels(entity).toSet()
          : {
              ...metadata.labelIds,
              for (final source in sourceRooms) ..._legacyLabels(source.id),
            };
      final record = InboxRecord(
        representativeRoomId: representative.id,
        entityId: entity,
        displayName: title,
        metadata: metadata,
        networks: sourceRooms.map(PersonalClient.networkOf),
        labelKeys: labels,
        isGroup: group == null && !room.isDirectChat,
        unread: sourceRooms.any((r) => r.isUnread),
        unreadCount: sourceRooms.fold(0, (n, r) => n + r.notificationCount),
        hasDraft:
            (_text(personal.values['draft:$entity']?['text']) ?? '')
                .isNotEmpty ||
            personal.conflicts.containsKey('draft:$entity') ||
            sourceRooms.any(
              (r) =>
                  (_text(personal.values['draft:${r.id}']?['text']) ?? '')
                      .isNotEmpty ||
                  personal.conflicts.containsKey('draft:${r.id}'),
            ),
        unanswered:
            latest != null &&
            latest.type == EventTypes.Message &&
            !latest.redacted &&
            latest.senderId != personal.client.userID &&
            sourceRooms.any((r) => r.canSendDefaultMessages),
        lastActivity: latest?.originServerTs,
      );
      records.add(record);
      representatives[representative.id] = representative;
    }
    final hidden = personal.values.entries
        .where(
          (e) => e.key.startsWith('label:') && e.value['showInInbox'] == false,
        )
        .map((e) => e.key)
        .toSet();
    final visible = projectInbox(
      records,
      filter: filter,
      query: query,
      labelKey: labelKey,
      hiddenLabelKeys: hidden,
    );
    if (filter == InboxFilter.inbox) {
      final due = _dueRoomIds();
      final ids = visible.map((r) => r.entityId).toSet();
      for (final record in records) {
        final group = members[record.representativeRoomId];
        if (due.contains(record.representativeRoomId) ||
            (group != null &&
                group.members.any((m) => due.contains(m.roomId)))) {
          ids.add(record.entityId);
        }
      }
      return projectInbox(records, filter: InboxFilter.all, query: query)
          .where((r) => ids.contains(r.entityId))
          .map((r) => representatives[r.representativeRoomId]!)
          .toList(growable: false);
    }
    return visible
        .map((r) => representatives[r.representativeRoomId]!)
        .toList(growable: false);
  }
}

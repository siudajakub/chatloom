// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/conversation_classification.dart';
import 'package:chatloom/personal/own_sender.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

export 'package:personal_core/personal_core.dart' show InboxFilter, InboxRecord;

/// Private inbox presentation. It never changes native room membership/state.
class InboxProjection {
  final PersonalClient personal;
  InboxProjection(this.personal) : _snapshot = false;

  /// Use only within one synchronous render/filter pass, never for actions.
  InboxProjection.snapshot(this.personal) : _snapshot = true;
  final bool _snapshot;
  List<PersonGroup>? _groups;
  Map<String, PersonGroup>? _groupIndex;
  final _metadata = <String, ConversationMetadata>{};
  Set<String>? _due;
  late final classifier = ConversationClassifier(personal.client.rooms);

  NetworkPreferences networkPreferences(String network) =>
      NetworkPreferences.fromJson(
        personal.values['network-policy:$network'] ?? {},
        network,
      );

  ChatPlacement placementFor(Room room) {
    final metadata = metadataFor(room);
    if (metadata.ignored) return ChatPlacement.ignored;
    if (metadata.placement != null) return metadata.placement!;
    final kind = classifier.classify(room);
    return kind.isGroup
        ? networkPreferences(kind.network).groupPlacement
        : ChatPlacement.inbox;
  }

  PersonalNotificationMode notificationModeFor(Room room) {
    final metadata = metadataFor(room);
    if (placementFor(room) == ChatPlacement.ignored)
      return PersonalNotificationMode.muted;
    final source = metadataForEntity(room.id);
    final kind = classifier.classify(room);
    final policy = networkPreferences(kind.network);
    final explicit = source.notificationMode ?? metadata.notificationMode;
    final inherited =
        (kind.isGroup ? policy.groupNotifications : null) ??
        policy.notifications;
    if (explicit == PersonalNotificationMode.muted) return explicit!;
    // An active (possibly timed) mute from the inbox menu outranks the other
    // choices but never loosens a fully muted network default.
    if (metadata.muted || source.muted) {
      return explicit == null && inherited == PersonalNotificationMode.muted
          ? PersonalNotificationMode.muted
          : PersonalNotificationMode.mentionsOnly;
    }
    return explicit ??
        inherited ??
        ((metadata.lowPriority || source.lowPriority)
            ? PersonalNotificationMode.mentionsOnly
            : PersonalNotificationMode.all);
  }

  static String? _text(Object? value) => value is String ? value : null;

  /// Whether [room] can be a source of a merged person: a joined one-to-one
  /// chat that is either a native `m.direct` chat or a chat its own bridge
  /// declares a DM. Beeper bridges usually do not write `m.direct`, so
  /// requiring it hid every saved merge of bridged chats. Bridge metadata
  /// alone grants nothing (any member may send state): the declaration
  /// counts only as an explicit `com.beeper.room_type.v2: dm` sent by the
  /// room's joined bridge bot, and no bridge state may declare another type.
  /// A network group (also a 2-member one) therefore never merges, so the
  /// person's composer can never send into a group. A room its bridge left
  /// undeclared while declaring kinds elsewhere (bridgev2 groups, channels)
  /// is not [Room.isDirectChatForDisplay], so even `m.direct` cannot merge it.
  /// Merging is presentation only; sending still targets a source room.
  static bool mergeable(Room? room) =>
      room != null &&
      room.membership == Membership.join &&
      !room.isSpace &&
      !PersonalPrivacy.isJournal(room) &&
      room.isDirectChatForDisplay &&
      (room.isDirectChat || _botDeclaredDirect(room));

  static const _bridgeStateTypes = [
    'm.bridge',
    'uk.half-shot.bridge',
    'com.beeper.bridge',
  ];

  static bool _botDeclaredDirect(Room room) {
    var declared = false;
    for (final type in _bridgeStateTypes) {
      for (final event in room.states[type]?.values ?? <StrippedStateEvent>[]) {
        final content = event.content;
        final kind = content['com.beeper.room_type.v2'];
        final legacy = content['com.beeper.room_type'];
        // Any declaration of another kind, by anyone, rules a merge out.
        if ((kind != null && kind != 'dm') ||
            (legacy != null && legacy != 'dm')) {
          return false;
        }
        final bot = content['bridgebot'];
        if (kind != 'dm' ||
            bot is! String ||
            event.senderId != bot ||
            room.getState(EventTypes.RoomMember, bot)?.content['membership'] !=
                'join') {
          continue;
        }
        declared = true;
      }
    }
    return declared;
  }

  List<PersonGroup> get _validGroups =>
      _snapshot ? (_groups ??= _parseValidGroups()) : _parseValidGroups();

  List<PersonGroup> _parseValidGroups() {
    final parsed = <PersonGroup>[];
    for (final group in personal.groups) {
      if (group.members.every(
        (m) =>
            m.accountId == personal.client.userID &&
            mergeable(personal.client.getRoomById(m.roomId)),
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

  /// The valid person group with [id], if any.
  PersonGroup? groupById(String id) {
    for (final group in _validGroups) {
      if (group.id == id) return group;
    }
    return null;
  }

  PersonGroup? groupFor(Room room) {
    if (_snapshot) {
      _groupIndex ??= {
        for (final group in _validGroups)
          for (final member in group.members) member.roomId: group,
      };
      return _groupIndex![room.id];
    }
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
  ConversationMetadata metadataForEntity(String entity) => _snapshot
      ? _metadata.putIfAbsent(entity, () => _readMetadata(entity))
      : _readMetadata(entity);

  ConversationMetadata _readMetadata(String entity) {
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

  Set<String> _dueRoomIds() =>
      _snapshot ? (_due ??= _readDueRoomIds()) : _readDueRoomIds();

  Set<String> _readDueRoomIds() {
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

  /// Network avatar of the conversation: the room's own, or for a merged
  /// person the first source room that has one (the default network may
  /// have no photo). Private avatars are resolved by the widgets.
  Uri? avatarFor(Room room) {
    final own = room.avatar;
    if (own != null) return own;
    final group = groupFor(room);
    if (group == null) return null;
    return avatarForGroup(group);
  }

  Uri? avatarForGroup(PersonGroup group) {
    final rooms = [
      group.defaultRoomId,
      ...group.members.map((m) => m.roomId),
    ].map(personal.client.getRoomById).whereType<Room>();
    for (final source in rooms) {
      final avatar = source.avatar;
      if (avatar != null) return avatar;
    }
    return null;
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
    final projection = _snapshot ? this : InboxProjection.snapshot(personal);
    return projection.select(
      projection.buildIndex(input),
      filter: filter,
      query: query,
    );
  }

  /// Snapshot only: drops cached metadata so the next read sees fresh state.
  void forgetEntity(String entity) {
    _metadata.remove(entity);
  }

  static bool _candidate(Room room) =>
      !room.isSpace && !PersonalPrivacy.isJournal(room);

  /// All inbox records of [input], unfiltered. Reusable across filter/search
  /// changes; [InboxIndex.updateRooms] refreshes single rooms in place.
  InboxIndex buildIndex(Iterable<Room> input) {
    assert(_snapshot, 'An index caches state; build it from a snapshot.');
    final available = {
      for (final room in input.where(_candidate)) room.id: room,
    };
    final groups = _validGroups;
    final members = <String, PersonGroup>{};
    for (final group in groups) {
      // A network group room can never be hidden by an invalid DM merge.
      if (group.members.every((m) => mergeable(available[m.roomId]))) {
        for (final member in group.members) {
          members[member.roomId] = group;
        }
      }
    }
    final index = InboxIndex._(this, available, members);
    for (final room in available.values) {
      final group = members[room.id];
      final entity = group == null ? room.id : 'person:${group.id}';
      if (index._records.containsKey(entity)) continue;
      index._put(entity, _record(room, entity, group, available));
    }
    return index;
  }

  (InboxRecord, Room) _record(
    Room room,
    String entity,
    PersonGroup? group,
    Map<String, Room> available,
  ) {
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
    final kinds = sourceRooms.map(classifier.classify).toList();
    final record = InboxRecord(
      representativeRoomId: representative.id,
      entityId: entity,
      displayName: title,
      metadata: metadata,
      networks: kinds.map((kind) => kind.network),
      labelKeys: labels,
      isGroup: group == null && kinds.single.isGroup,
      technical: kinds.every((kind) => kind.technical),
      placement: placementFor(representative),
      unread: sourceRooms.any((r) => r.isUnread),
      unreadCount: sourceRooms.fold(0, (n, r) => n + r.notificationCount),
      hasDraft:
          (_text(personal.values['draft:$entity']?['text']) ?? '').isNotEmpty ||
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
          !OwnSenderResolver.of(personal.client).isOwnEvent(latest) &&
          sourceRooms.any((r) => r.canSendDefaultMessages),
      lastActivity: latest?.originServerTs,
    );
    return (record, representative);
  }

  /// Applies the private view rules to an index (pure, no state reads except
  /// the cached due-reminder set).
  List<Room> select(
    InboxIndex index, {
    InboxFilter filter = InboxFilter.inbox,
    String query = '',
  }) {
    final records = index.records;
    // Legacy labels remain stored, but no longer control inbox visibility.
    final visible = projectInbox(
      records,
      filter: filter == InboxFilter.label ? InboxFilter.inbox : filter,
      query: query,
    );
    if (filter == InboxFilter.inbox) {
      final due = _dueRoomIds();
      final ids = visible.map((r) => r.entityId).toSet();
      for (final record in records) {
        if (record.technical ||
            record.placement != ChatPlacement.inbox ||
            record.metadata.ignored)
          continue;
        final group = index._members[record.representativeRoomId];
        if (due.contains(record.representativeRoomId) ||
            (group != null &&
                group.members.any((m) => due.contains(m.roomId)))) {
          ids.add(record.entityId);
        }
      }
      return projectInbox(records, filter: InboxFilter.all, query: query)
          .where((r) => ids.contains(r.entityId))
          .map((r) => index._representatives[r.representativeRoomId]!)
          .toList(growable: false);
    }
    return visible
        .map((r) => index._representatives[r.representativeRoomId]!)
        .toList(growable: false);
  }
}

/// Unfiltered inbox records of one snapshot plus what selection needs.
class InboxIndex {
  final InboxProjection projection;
  final Map<String, Room> _available;
  final Map<String, PersonGroup> _members;
  final _records = <String, InboxRecord>{};
  final _representatives = <String, Room>{};
  List<InboxRecord>? _list;
  InboxIndex._(this.projection, this._available, this._members);

  void _put(String entity, (InboxRecord, Room) value) {
    _records[entity] = value.$1;
    _representatives[value.$2.id] = value.$2;
    _list = null;
  }

  List<InboxRecord> get records => _list ??= List.unmodifiable(_records.values);
  Iterable<Room> get rooms => _available.values;
  InboxRecord? recordFor(Room room) =>
      _records[_members[room.id] == null
          ? room.id
          : 'person:${_members[room.id]!.id}'];

  /// Recomputes the records of [roomIds] in place. Returns false when the
  /// change may affect other records (room set, merged persons, bridges) and
  /// the caller must build a new index instead.
  bool updateRooms(Iterable<String> roomIds, Iterable<Room> current) {
    final client = projection.personal.client;
    var count = 0;
    for (final room in current) {
      if (InboxProjection._candidate(room)) count++;
    }
    if (count != _available.length) return false;
    final grouped = {
      for (final group in projection.personal.groups)
        for (final member in group.members) member.roomId,
    };
    final changed = <Room>[];
    for (final id in roomIds) {
      final room = client.getRoomById(id);
      final known = _available[id];
      if (room == null) {
        if (known != null) return false;
        continue;
      }
      if (!identical(room, known) ||
          !InboxProjection._candidate(room) ||
          grouped.contains(id) ||
          _members.containsKey(id) ||
          !projection.classifier.covers(room)) {
        if (known == null && !InboxProjection._candidate(room)) continue;
        return false;
      }
      changed.add(room);
    }
    for (final room in changed) {
      projection.forgetEntity(room.id);
      _put(room.id, projection._record(room, room.id, null, _available));
    }
    return true;
  }
}

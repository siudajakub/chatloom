// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/conversation_classification.dart';
import 'package:chatloom/personal/network_chat_actions.dart';
import 'package:chatloom/personal/own_sender.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/private_avatar.dart';
import 'package:chatloom/personal/push_rule_mirror.dart';
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
  PersonGroupResolution? _resolved;
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
    // An unaccepted message request stays quiet (Messenger, Instagram):
    // only an explicit choice for this chat lets it alert.
    if (explicit == null && kind.messageRequest) {
      return inherited == PersonalNotificationMode.muted
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

  /// Saved persons resolved against the current chats (see
  /// [PersonGroupResolution]): a person stays merged while one of its chats
  /// is joined; a chat two persons list belongs to one of them.
  PersonGroupResolution get resolution =>
      _snapshot ? (_resolved ??= _resolve()) : _resolve();

  PersonGroupResolution _resolve() =>
      resolvePersonGroups(personal.groups, _memberState);

  PersonMemberState _memberState(ConversationRef member) {
    final room = member.accountId == personal.client.userID
        ? personal.client.getRoomById(member.roomId)
        : null;
    if (room == null || room.membership != Membership.join) {
      return PersonMemberState.inactive;
    }
    return mergeable(room) ? PersonMemberState.active : PersonMemberState.unsafe;
  }

  List<PersonGroup> get _validGroups => resolution.valid;

  /// The valid person group with [id], if any.
  PersonGroup? groupById(String id) {
    for (final group in _validGroups) {
      if (group.id == id) return group;
    }
    return null;
  }

  /// The person that shows [room] (only for a joined chat it owns).
  PersonGroup? groupFor(Room room) => resolution.ownerOf(room.id);

  /// Every chat of [group] with its current status. Works for any group,
  /// also one that is not (or no longer) saved.
  List<PersonSource> sourcesOf(PersonGroup group) {
    final owners = resolution;
    return [
      for (final member in group.members)
        PersonSource._(
          member,
          member.accountId == personal.client.userID
              ? personal.client.getRoomById(member.roomId)
              : null,
          owners,
          group,
        ),
    ];
  }

  /// The chats of [group] it shows right now (joined, owned by it).
  List<Room> activeSourcesOf(PersonGroup group) => [
    for (final source in sourcesOf(group))
      if (source.status == PersonSourceStatus.active) source.room!,
  ];

  /// Private preferences of the person [groupId] (routing, name source).
  PersonPreferences preferencesFor(String groupId) =>
      PersonPreferences.fromJson(personal.values[personPreferencesKey(groupId)]);

  /// The one name of a merged person everywhere: the private nickname, else
  /// the current name of the chosen source chat, else the saved name.
  String personName(PersonGroup group) {
    final entity = 'person:${group.id}';
    final override =
        metadataForEntity(entity).nickname ??
        _text(personal.values['nickname:$entity']?['name']);
    if (override?.trim().isNotEmpty == true) return override!;
    final source = preferencesFor(group.id).nameRoomId;
    if (source != null && group.members.any((m) => m.roomId == source)) {
      final name = personal.client.getRoomById(source)?.getLocalizedDisplayname();
      if (name != null && name.trim().isNotEmpty) return name;
    }
    return group.name;
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

  Iterable<String> _legacyLabels(String entity) {
    final value = personal.values['labels:$entity']?['labels'];
    return value is List ? value.whereType<String>() : const [];
  }

  String displayName(Room room) {
    final group = groupFor(room);
    if (group != null) return personName(group);
    final entity = room.id;
    final override =
        metadataForEntity(entity).nickname ??
        _text(personal.values['nickname:$entity']?['name']);
    return override?.trim().isNotEmpty == true
        ? override!
        : room.getLocalizedDisplayname();
  }

  /// Network avatar of the conversation: the room's own, or for a merged
  /// person its chosen network photo, else the first source room that has
  /// one (the default network may have no photo). Private avatars are
  /// resolved by the widgets.
  Uri? avatarFor(Room room) {
    final group = groupFor(room);
    if (group != null) return avatarForGroup(group) ?? room.avatar;
    return room.avatar;
  }

  Uri? avatarForGroup(PersonGroup group) {
    final chosen = personAvatarSource(
      metadataForEntity('person:${group.id}').avatarAsset,
    );
    if (chosen != null && group.members.any((m) => m.roomId == chosen)) {
      final avatar = personal.client.getRoomById(chosen)?.avatar;
      if (avatar != null) return avatar;
    }
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
    return activeSourcesOf(
      group,
    ).fold(0, (count, r) => count + r.notificationCount);
  }

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

  /// A chat whose network deletion is in flight is hidden at once
  /// ([NetworkChatActions.deleteChat]) and comes back if it is refused.
  static bool _candidate(Room room) =>
      !room.isSpace &&
      !PersonalPrivacy.isJournal(room) &&
      !NetworkChatActions.isDeleting(room);

  /// All inbox records of [input], unfiltered. Reusable across filter/search
  /// changes; [InboxIndex.updateRooms] refreshes single rooms in place.
  InboxIndex buildIndex(Iterable<Room> input) {
    assert(_snapshot, 'An index caches state; build it from a snapshot.');
    final available = {
      for (final room in input.where(_candidate)) room.id: room,
    };
    final members = <String, PersonGroup>{};
    for (final entry in resolution.owners.entries) {
      // Only chats of this index; a network group room never hides here.
      if (mergeable(available[entry.key])) members[entry.key] = entry.value;
    }
    final index = InboxIndex._(this, available, members);
    for (final room in available.values) {
      final group = members[room.id];
      final entity = group == null ? room.id : 'person:${group.id}';
      if (index._records.containsKey(entity)) continue;
      final sources = group == null
          ? [room]
          : [
              for (final member in group.members)
                if (members[member.roomId]?.id == group.id)
                  available[member.roomId]!,
            ];
      index._put(entity, _record(room, entity, group, sources));
    }
    return index;
  }

  (InboxRecord, Room) _record(
    Room room,
    String entity,
    PersonGroup? group,
    List<Room> sourceRooms,
  ) {
    final representative = group == null
        ? room
        : sourceRooms.firstWhere(
            (source) => source.id == group.defaultRoomId,
            orElse: () => sourceRooms.first,
          );
    final lastEvents =
        sourceRooms.map((r) => r.lastEvent).whereType<Event>().toList()
          ..sort((a, b) => b.originServerTs.compareTo(a.originServerTs));
    final latest = lastEvents.firstOrNull;
    final metadata = metadataForEntity(entity);
    final String title;
    if (group != null) {
      title = personName(group);
    } else {
      final nickname =
          metadata.nickname ??
          _text(personal.values['nickname:$entity']?['name']);
      title = nickname?.trim().isNotEmpty == true
          ? nickname!
          : room.getLocalizedDisplayname();
    }
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
      messageRequest: group == null && kinds.single.messageRequest,
      placement: placementFor(representative),
      unread: sourceRooms.any(personalRoomUnread),
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
        .where(
          (record) =>
              filter != InboxFilter.groups ||
              record.networks.any(
                (network) => networkPreferences(network).showInGroups,
              ),
        )
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
      _put(room.id, projection._record(room, room.id, null, [room]));
    }
    return true;
  }
}

/// One chat of a merged person and its current status.
class PersonSource {
  final ConversationRef member;

  /// The chat on this device; null when it was left or deleted.
  final Room? room;
  final PersonSourceStatus status;

  /// The other person that shows this chat ([PersonSourceStatus.elsewhere]).
  final PersonGroup? owner;

  PersonSource._(
    this.member,
    this.room,
    PersonGroupResolution resolution,
    PersonGroup group,
  ) : status = _statusOf(member, room, resolution, group),
      owner = switch (resolution.ownerOf(member.roomId)) {
        final PersonGroup other when other.id != group.id => other,
        _ => null,
      };

  static PersonSourceStatus _statusOf(
    ConversationRef member,
    Room? room,
    PersonGroupResolution resolution,
    PersonGroup group,
  ) {
    if (room == null || room.membership != Membership.join) {
      return PersonSourceStatus.inactive;
    }
    final owner = resolution.ownerOf(member.roomId);
    if (owner != null && owner.id != group.id) {
      return PersonSourceStatus.elsewhere;
    }
    return InboxProjection.mergeable(room)
        ? PersonSourceStatus.active
        : PersonSourceStatus.unsafe;
  }

  /// Can receive this person's messages: joined and not shown by another
  /// person. (A joined chat that is no longer a one-to-one chat keeps the
  /// whole person out of the inbox; it is flagged on the person page.)
  bool get sendable =>
      status == PersonSourceStatus.active ||
      status == PersonSourceStatus.unsafe;

  /// An invitation is pending for this chat (it is not joined).
  bool get invited => room?.membership == Membership.invite;

  @override
  String toString() => 'PersonSource(${status.name}, redacted)';
}

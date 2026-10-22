// SPDX-License-Identifier: AGPL-3.0-or-later
import 'contracts.dart';

/// An original event, never a copied message in a synthetic room.
class MergedEvent<T> {
  final SourceEventRef source;
  final DateTime timestamp;
  final bool isOutgoing;
  final T value;
  final int revision;

  MergedEvent({
    required this.source,
    required this.timestamp,
    required this.isOutgoing,
    required this.value,
    this.revision = 0,
  }) {
    if (revision < 0) throw ArgumentError('Invalid event revision');
  }

  /// Stable identity of the source event, computed once per merged event.
  late final String key = source.key;

  @override
  String toString() => 'MergedEvent(redacted, revision: $revision)';
}

int compareMergedEvents<T>(MergedEvent<T> a, MergedEvent<T> b) {
  final byTime = a.timestamp.compareTo(b.timestamp);
  return byTime != 0 ? byTime : a.key.compareTo(b.key);
}

class _SourcePageState {
  bool initialized = false;
  bool hasMore = true;
  DateTime? oldestCovered;
  String? cursor;
}

/// A k-way history buffer. Failed/empty partial pages do not erase events.
/// Cursor values are opaque; the transport owns fetching, retries and errors.
class MergedTimelineBuffer<T> {
  final List<ConversationRef> members;
  final Map<String, _SourcePageState> _pages = {};
  final Map<String, MergedEvent<T>> _events = {};
  List<MergedEvent<T>>? _sorted;
  List<MergedEvent<T>>? _covered;

  MergedTimelineBuffer(Iterable<ConversationRef> members)
    : members = List.unmodifiable(members) {
    if (this.members.isEmpty ||
        this.members.map((m) => m.key).toSet().length != this.members.length) {
      throw ArgumentError('Invalid timeline members');
    }
    for (final member in this.members) {
      _pages[member.key] = _SourcePageState();
    }
  }

  /// Sorted once per mutation; repeated reads during one render are free.
  List<MergedEvent<T>> get events => _sorted ??= List.unmodifiable(
    _events.values.toList()..sort(compareMergedEvents),
  );

  bool get initialized => _pages.values.every((p) => p.initialized);
  bool get hasMore => _pages.values.any((p) => p.hasMore);

  /// Only expose a complete prefix of newest history: a lagging member must
  /// fetch further before older globally interleaved events can be published.
  /// Equal timestamps at a page boundary remain buffered until fully covered.
  List<MergedEvent<T>> get coveredEvents => _covered ??= _computeCovered();

  List<MergedEvent<T>> _computeCovered() {
    if (!initialized) return const [];
    DateTime? frontier;
    for (final page in _pages.values.where((p) => p.hasMore)) {
      final oldest = page.oldestCovered;
      if (oldest == null) return const [];
      if (frontier == null || oldest.isAfter(frontier)) frontier = oldest;
    }
    if (frontier == null) return events;
    return List.unmodifiable(
      events.where((event) => event.timestamp.isAfter(frontier!)),
    );
  }

  void _invalidate() {
    _sorted = null;
    _covered = null;
  }

  String? cursorFor(ConversationRef member) => _page(member).cursor;

  /// Sources that do not yet prove coverage through the requested timestamp.
  List<ConversationRef> sourcesNeededThrough(DateTime cutoff) =>
      List.unmodifiable(
        members.where((member) {
          final page = _page(member);
          return !page.initialized ||
              (page.hasMore &&
                  (page.oldestCovered == null ||
                      !page.oldestCovered!.isBefore(cutoff)));
        }),
      );

  void addPage({
    required ConversationRef member,
    required Iterable<MergedEvent<T>> events,
    required bool hasMore,
    String? cursor,
  }) {
    final page = _page(member);
    final incoming = events.toList();
    // Validate the whole page before mutating, including all event identities.
    if (incoming.any((e) => e.source.conversation != member)) {
      throw ArgumentError('Page contains an event from another source');
    }
    if (hasMore && cursor == null) {
      throw ArgumentError('A continuing page requires an opaque cursor');
    }
    for (final event in incoming) {
      final oldest = page.oldestCovered;
      if (oldest == null || event.timestamp.isBefore(oldest)) {
        page.oldestCovered = event.timestamp;
      }
      _upsert(event);
    }
    page.initialized = true;
    page.hasMore = hasMore;
    page.cursor = hasMore ? cursor : null;
    _invalidate();
  }

  void addLive(MergedEvent<T> event) {
    _page(event.source.conversation);
    _upsert(event);
  }

  void _upsert(MergedEvent<T> event) {
    final previous = _events[event.key];
    if (previous == null || event.revision > previous.revision) {
      _events[event.key] = event;
      _invalidate();
    }
  }

  _SourcePageState _page(ConversationRef member) =>
      _pages[member.key] ?? (throw ArgumentError('Unknown timeline member'));
}

class MergedSendRouter {
  static const recentOutgoingWindow = Duration(minutes: 30);

  /// The network of the next message: a reply stays on its source, an
  /// explicit [override] wins, then (when [automatic]) the source of the
  /// recent conversation, else the person's default chat.
  ///
  /// [available] are the members that can receive messages right now (a
  /// chat that was left or deleted, or that belongs to another person, is
  /// not). Automatic routing never picks an unavailable member and an
  /// unavailable default falls back to the first available member. Without
  /// [available] every member counts as available. With [automatic] false
  /// (`Always <network>`) recent traffic is ignored.
  static SendTarget resolve({
    required PersonGroup group,
    required DateTime now,
    MergedEvent<Object?>? recentEvent,
    ConversationRef? override,
    SourceEventRef? replyTo,
    bool automatic = true,
    Set<ConversationRef>? available,
  }) {
    ConversationRef checked(ConversationRef ref) => group.members.firstWhere(
      (member) => member == ref,
      orElse: () => throw ArgumentError('Target is not a group member'),
    );
    bool usable(ConversationRef ref) =>
        available == null || available.contains(ref);

    if (replyTo != null) {
      final source = checked(replyTo.conversation);
      if (override != null && checked(override) != source) {
        throw ArgumentError('A reply must stay on the original network');
      }
      return SendTarget(conversation: source);
    }
    if (override != null) return SendTarget(conversation: checked(override));
    final preferred = group.members.firstWhere(
      (member) => member.roomId == group.defaultRoomId,
    );
    final fallback = usable(preferred)
        ? preferred
        : group.members.where(usable).firstOrNull ?? preferred;
    if (recentEvent == null || !automatic) {
      return SendTarget(conversation: fallback);
    }
    final source = checked(recentEvent.source.conversation);
    if (!usable(source)) return SendTarget(conversation: fallback);
    final age = now.difference(recentEvent.timestamp);
    if (!recentEvent.isOutgoing ||
        (!age.isNegative && age <= recentOutgoingWindow)) {
      return SendTarget(conversation: source);
    }
    return SendTarget(conversation: fallback);
  }
}

/// Source edits of a saved person. Each returns a new group with the next
/// revision; nothing about rooms, messages or accounts changes.
extension PersonGroupEdits on PersonGroup {
  /// Without the chat [roomId]; null when fewer than two chats would remain
  /// (the person is then unmerged). Removing the default makes
  /// [preferredDefault] (when it remains) or the first remaining chat the
  /// default.
  PersonGroup? withoutSource(String roomId, {String? preferredDefault}) {
    if (!members.any((member) => member.roomId == roomId)) {
      throw ArgumentError('Unknown group member');
    }
    final remaining = members.where((m) => m.roomId != roomId).toList();
    if (remaining.length < 2) return null;
    final keepsDefault = remaining.any((m) => m.roomId == defaultRoomId);
    final nextDefault = keepsDefault
        ? defaultRoomId
        : remaining.any((m) => m.roomId == preferredDefault)
        ? preferredDefault!
        : remaining.first.roomId;
    return _edited(members: remaining, defaultRoomId: nextDefault);
  }

  /// With [added] chats appended (already present ones are ignored).
  PersonGroup withSources(Iterable<ConversationRef> added) {
    final next = [...members];
    for (final member in added) {
      if (!next.contains(member)) next.add(member);
    }
    return next.length == members.length ? this : _edited(members: next);
  }

  /// With [roomId] as the default chat (the fallback of automatic routing
  /// and the target of `Always <network>`).
  PersonGroup withDefaultSource(String roomId) {
    if (!members.any((member) => member.roomId == roomId)) {
      throw ArgumentError('The default must be a member');
    }
    return roomId == defaultRoomId ? this : _edited(defaultRoomId: roomId);
  }

  /// With the saved name [value] (what builds without person preferences
  /// show when no private nickname is set).
  PersonGroup withName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) throw ArgumentError('A group needs a name');
    return trimmed == name ? this : _edited(name: trimmed);
  }

  PersonGroup _edited({
    List<ConversationRef>? members,
    String? defaultRoomId,
    String? name,
  }) => PersonGroup(
    id: id,
    name: name ?? this.name,
    members: members ?? this.members,
    defaultRoomId: defaultRoomId ?? this.defaultRoomId,
    revision: revision + 1,
  );
}

/// Eligibility comes from verified room membership, never names or avatars.
class PersonGroupManager {
  final Map<ConversationRef, bool> isDirectMessage;

  PersonGroupManager(Map<ConversationRef, bool> isDirectMessage)
    : isDirectMessage = Map.unmodifiable(isDirectMessage);

  PersonGroup create({
    required String id,
    required String name,
    required List<ConversationRef> members,
    required ConversationRef defaultConversation,
  }) {
    if (id.trim().isEmpty || name.trim().isEmpty) {
      throw ArgumentError('A group needs an ID and a name');
    }
    _checkMembers(members);
    if (!members.contains(defaultConversation)) {
      throw ArgumentError('The default must be a member');
    }
    return PersonGroup(
      id: id,
      name: name.trim(),
      members: members,
      defaultRoomId: defaultConversation.roomId,
    );
  }

  PersonGroup addMember(PersonGroup group, ConversationRef member) {
    if (group.members.contains(member)) return group;
    return _replace(group, [...group.members, member]);
  }

  /// Null dissolves a two-member merge. The returned original references remain
  /// available to the caller; no room, message or account is ever deleted here.
  PersonGroup? removeMember(
    PersonGroup group,
    ConversationRef member, {
    ConversationRef? replacementDefault,
  }) {
    if (!group.members.contains(member)) {
      throw ArgumentError('Unknown group member');
    }
    final remaining = group.members.where((m) => m != member).toList();
    if (remaining.length < 2) return null;
    if (member.roomId == group.defaultRoomId && replacementDefault == null) {
      throw ArgumentError('Choose a replacement default before removing it');
    }
    final defaultMember =
        replacementDefault ??
        remaining.firstWhere((m) => m.roomId == group.defaultRoomId);
    if (!remaining.contains(defaultMember)) {
      throw ArgumentError('The replacement default must remain in the group');
    }
    return _replace(group, remaining, defaultRoomId: defaultMember.roomId);
  }

  PersonGroup rename(PersonGroup group, String name) {
    if (name.trim().isEmpty) throw ArgumentError('A group needs a name');
    return _replace(group, group.members, name: name.trim());
  }

  List<ConversationRef> unmerge(PersonGroup group) =>
      List.unmodifiable(group.members);

  PersonGroup _replace(
    PersonGroup group,
    List<ConversationRef> members, {
    String? name,
    String? defaultRoomId,
  }) {
    _checkMembers(members);
    return PersonGroup(
      id: group.id,
      name: name ?? group.name,
      members: members,
      defaultRoomId: defaultRoomId ?? group.defaultRoomId,
      revision: group.revision + 1,
    );
  }

  void _checkMembers(Iterable<ConversationRef> members) {
    if (members.any((m) => isDirectMessage[m] != true)) {
      throw ArgumentError('Only confirmed direct conversations can be merged');
    }
  }
}

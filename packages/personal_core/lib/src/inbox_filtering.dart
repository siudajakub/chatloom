// SPDX-License-Identifier: AGPL-3.0-or-later
import 'organization.dart';
import 'network_preferences.dart';

enum InboxFilter {
  inbox,
  unread,
  drafts,
  unanswered,
  direct,
  groups,
  ignored,
  technical,
  label,
  archive,
  lowPriority,
  all,

  /// Message requests from people the user has not accepted yet (Instagram,
  /// Messenger). They also stay in their usual views, tagged.
  requests,
  aside,
}

class InboxRecord {
  final String representativeRoomId;
  final String entityId;
  final String displayName;
  final Set<String> networks;
  final Set<String> labelKeys;
  final bool isGroup;
  final bool technical;

  /// An unaccepted message request (bridge-declared).
  final bool messageRequest;
  final ChatPlacement placement;
  final bool unread;
  final int unreadCount;
  final bool hasDraft;
  final bool unanswered;

  /// The user moved this unread chat down ("Move down") until its next
  /// message: it keeps its unread state but sorts by time among the read
  /// chats instead of above them.
  final bool movedDown;
  final DateTime? lastActivity;
  final ConversationMetadata metadata;
  InboxRecord({
    required this.representativeRoomId,
    required this.entityId,
    required this.displayName,
    required this.metadata,
    Iterable<String> networks = const [],
    Iterable<String> labelKeys = const [],
    this.isGroup = false,
    this.technical = false,
    this.messageRequest = false,
    this.placement = ChatPlacement.inbox,
    this.unread = false,
    this.unreadCount = 0,
    this.hasDraft = false,
    this.unanswered = false,
    this.movedDown = false,
    this.lastActivity,
  }) : networks = Set.unmodifiable(networks),
       labelKeys = Set.unmodifiable(labelKeys);

  /// This record with [hasDraft] replaced (a draft saved or cleared).
  InboxRecord withDraft(bool hasDraft) => InboxRecord(
    representativeRoomId: representativeRoomId,
    entityId: entityId,
    displayName: displayName,
    metadata: metadata,
    networks: networks,
    labelKeys: labelKeys,
    isGroup: isGroup,
    technical: technical,
    messageRequest: messageRequest,
    placement: placement,
    unread: unread,
    unreadCount: unreadCount,
    hasDraft: hasDraft,
    unanswered: unanswered,
    movedDown: movedDown,
    lastActivity: lastActivity,
  );

  @override
  String toString() => 'InboxRecord(redacted)';
}

List<InboxRecord> projectInbox(
  Iterable<InboxRecord> records, {
  InboxFilter filter = InboxFilter.inbox,
  String query = '',
  String? labelKey,
  Set<String> hiddenLabelKeys = const {},
}) {
  final trimmed = query.toLowerCase().trim();
  // An empty query matches everything: no per-record search text is built.
  final terms = trimmed.isEmpty
      ? const <String>[]
      : trimmed.split(RegExp(r'\s+'));
  bool matches(String Function() searchable) {
    if (terms.isEmpty) return true;
    final text = searchable().toLowerCase();
    return terms.every(text.contains);
  }

  final result = records.where((record) {
    var placement = record.metadata.placement ?? record.placement;
    // A pinned group stays on the main list as well as under Groups.
    if (placement == ChatPlacement.groups && record.metadata.isPinned)
      placement = ChatPlacement.inbox;
    final ignored =
        record.metadata.ignored || placement == ChatPlacement.ignored;
    if (record.technical)
      return filter == InboxFilter.technical &&
          matches(() => '${record.displayName} ${record.networks.join(' ')}');
    if (filter == InboxFilter.technical) return false;
    if (ignored && filter != InboxFilter.ignored) return false;
    if (!ignored && filter == InboxFilter.ignored) return false;
    // Aside is a destination, not a group/unread/archive overlay. Pins and
    // new activity must never bring these chats back into the main views.
    final aside = placement == ChatPlacement.aside;
    if (!ignored && aside != (filter == InboxFilter.aside)) return false;
    final inInbox =
        placement == ChatPlacement.inbox &&
        !record.metadata.archived &&
        !record.metadata.lowPriority &&
        !record.labelKeys.any(hiddenLabelKeys.contains);
    // Chats moved to Groups (Telegram groups by default) still count as
    // unread, like Telegram's Unread folder; "All chats" and the main list
    // keep leaving them out (code-client CC-37, J's decision).
    final inGroups =
        placement == ChatPlacement.groups &&
        !record.metadata.archived &&
        !record.metadata.lowPriority &&
        !record.labelKeys.any(hiddenLabelKeys.contains);
    final matchesFilter = switch (filter) {
      InboxFilter.inbox => inInbox,
      InboxFilter.unread => (inInbox || inGroups) && record.unread,
      InboxFilter.drafts => inInbox && record.hasDraft,
      InboxFilter.unanswered => inInbox && record.unanswered,
      InboxFilter.direct => inInbox && !record.isGroup,
      InboxFilter.groups =>
        !record.metadata.archived &&
            !record.metadata.lowPriority &&
            record.isGroup &&
            !record.labelKeys.any(hiddenLabelKeys.contains),
      InboxFilter.ignored => ignored,
      InboxFilter.aside => aside,
      InboxFilter.technical => false,
      InboxFilter.label =>
        labelKey != null && record.labelKeys.contains(labelKey),
      InboxFilter.archive => record.metadata.archived,
      InboxFilter.lowPriority => record.metadata.lowPriority,
      InboxFilter.all => placement == ChatPlacement.inbox,
      InboxFilter.requests =>
        record.messageRequest && !record.metadata.archived,
    };
    return matchesFilter &&
        matches(() => '${record.displayName}\n${record.networks.join(' ')}');
  }).toList();
  // One clock reading per projection: a timed mute ending mid-sort can no
  // longer make the comparator inconsistent, and the sort keys are computed
  // once per record instead of on every comparison.
  final now = DateTime.now();
  final keyed = [
    for (final record in result)
      (
        record: record,
        raised: _raised(record, now),
        time: (record.lastActivity ?? _epoch).microsecondsSinceEpoch,
      ),
  ];
  keyed.sort((a, b) {
    final x = a.record.metadata, y = b.record.metadata;
    if (x.isPinned != y.isPinned) return x.isPinned ? -1 : 1;
    if (x.isPinned) {
      final pin = x.pinOrder!.compareTo(y.pinOrder!);
      if (pin != 0) return pin;
    } else if (a.raised != b.raised) {
      return a.raised ? -1 : 1;
    }
    final time = b.time.compareTo(a.time);
    return time != 0 ? time : a.record.entityId.compareTo(b.record.entityId);
  });
  return List.unmodifiable([for (final entry in keyed) entry.record]);
}

final _epoch = DateTime.fromMillisecondsSinceEpoch(0);

/// Unread, unmuted chats sit above the other unpinned chats unless the user
/// moved them down; inside each band the newest message comes first.
bool _raised(InboxRecord record, DateTime now) =>
    record.unread && !record.metadata.mutedAt(now) && !record.movedDown;

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
    this.lastActivity,
  }) : networks = Set.unmodifiable(networks),
       labelKeys = Set.unmodifiable(labelKeys);
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
  final terms = query.toLowerCase().trim().split(RegExp(r'\s+'));
  final result = records.where((record) {
    var placement = record.metadata.placement ?? record.placement;
    // A pinned group stays on the main list as well as under Groups.
    if (placement == ChatPlacement.groups && record.metadata.isPinned)
      placement = ChatPlacement.inbox;
    final ignored =
        record.metadata.ignored || placement == ChatPlacement.ignored;
    if (record.technical)
      return filter == InboxFilter.technical &&
          terms.every(
            '${record.displayName} ${record.networks.join(' ')}'
                .toLowerCase()
                .contains,
          );
    if (filter == InboxFilter.technical) return false;
    if (ignored && filter != InboxFilter.ignored) return false;
    if (!ignored && filter == InboxFilter.ignored) return false;
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
      InboxFilter.technical => false,
      InboxFilter.label =>
        labelKey != null && record.labelKeys.contains(labelKey),
      InboxFilter.archive => record.metadata.archived,
      InboxFilter.lowPriority => record.metadata.lowPriority,
      InboxFilter.all => placement == ChatPlacement.inbox,
      InboxFilter.requests =>
        record.messageRequest && !record.metadata.archived,
    };
    final searchable = '${record.displayName}\n${record.networks.join(' ')}'
        .toLowerCase();
    return matchesFilter && terms.every(searchable.contains);
  }).toList();
  result.sort((a, b) {
    if (a.metadata.isPinned != b.metadata.isPinned)
      return a.metadata.isPinned ? -1 : 1;
    if (a.metadata.isPinned) {
      final pin = a.metadata.pinOrder!.compareTo(b.metadata.pinOrder!);
      if (pin != 0) return pin;
    }
    final time = (b.lastActivity ?? DateTime.fromMillisecondsSinceEpoch(0))
        .compareTo(a.lastActivity ?? DateTime.fromMillisecondsSinceEpoch(0));
    return time != 0 ? time : a.entityId.compareTo(b.entityId);
  });
  return List.unmodifiable(result);
}

// SPDX-License-Identifier: AGPL-3.0-or-later

/// Source identity and chronology needed by either conversation presenter.
///
/// Callers must pass actual chronological neighbours, including a [boundary]
/// item for separators or history gaps. A missing neighbour never implies that
/// the group continues into unloaded history.
class ConversationGroupingItem {
  final String accountId;
  final String sourceId;
  final String senderId;
  final bool outgoing;
  final DateTime timestamp;
  final String? threadId;
  final String deliveryState;
  final bool boundary;

  /// A reply opens a new group: its quote sits between it and the message
  /// before it, so the two never join.
  final bool startsSeries;

  const ConversationGroupingItem({
    required this.accountId,
    required this.sourceId,
    required this.senderId,
    required this.outgoing,
    required this.timestamp,
    this.threadId,
    this.deliveryState = 'sent',
    this.boundary = false,
    this.startsSeries = false,
  });
}

/// Position in ascending chronology, independent of ListView.reverse.
enum ConversationGroupPosition { single, first, middle, last }

ConversationGroupPosition conversationGroupPosition({
  required ConversationGroupingItem item,
  ConversationGroupingItem? older,
  ConversationGroupingItem? newer,
}) {
  final joinsOlder = older != null && _canJoin(older, item);
  final joinsNewer = newer != null && _canJoin(item, newer);
  if (joinsOlder && joinsNewer) return ConversationGroupPosition.middle;
  if (joinsOlder) return ConversationGroupPosition.last;
  if (joinsNewer) return ConversationGroupPosition.first;
  return ConversationGroupPosition.single;
}

bool _canJoin(ConversationGroupingItem older, ConversationGroupingItem newer) {
  if (older.boundary || newer.boundary || newer.startsSeries) return false;
  if (older.accountId != newer.accountId ||
      older.sourceId != newer.sourceId ||
      older.senderId != newer.senderId ||
      older.outgoing != newer.outgoing ||
      older.threadId != newer.threadId ||
      older.deliveryState != newer.deliveryState) {
    return false;
  }
  final olderLocal = older.timestamp.toLocal();
  final newerLocal = newer.timestamp.toLocal();
  if (olderLocal.year != newerLocal.year ||
      olderLocal.month != newerLocal.month ||
      olderLocal.day != newerLocal.day) {
    return false;
  }
  final gap = newer.timestamp.difference(older.timestamp);
  return !gap.isNegative && gap <= const Duration(minutes: 5);
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'contracts.dart';
import 'organization.dart';

class ConversationSearchEntry {
  final ConversationRef conversation;
  final ConversationMetadata metadata;
  final String displayName;
  final bool isGroup;
  final bool readOnly;
  final int unreadCount;
  final bool hasDraft;
  final DateTime? lastIncomingAt;
  final DateTime? lastOutgoingAt;
  const ConversationSearchEntry({
    required this.conversation,
    required this.metadata,
    required this.displayName,
    this.isGroup = false,
    this.readOnly = false,
    this.unreadCount = 0,
    this.hasDraft = false,
    this.lastIncomingAt,
    this.lastOutgoingAt,
  });
  bool get unanswered =>
      !readOnly &&
      lastIncomingAt != null &&
      (lastOutgoingAt == null || lastIncomingAt!.isAfter(lastOutgoingAt!));
  @override
  String toString() => 'ConversationSearchEntry(redacted)';
}

class MessageSearchEntry {
  final SourceEventRef source;
  final DateTime timestamp;
  final String text;
  final String? transcript;
  final String? fileName;
  final String messageType;
  final bool isOutgoing;
  final bool bookmarked;
  final bool redacted;
  const MessageSearchEntry({
    required this.source,
    required this.timestamp,
    this.text = '',
    this.transcript,
    this.fileName,
    this.messageType = 'text',
    this.isOutgoing = false,
    this.bookmarked = false,
    this.redacted = false,
  });
  @override
  String toString() => 'MessageSearchEntry(redacted)';
}

/// Local predicates only: SDK timelines and a private index own retrieval.
class PersonalSearchQuery {
  final String text;
  final Set<String> networks;
  final Set<String> labelIds;
  final Set<String> messageTypes;
  final bool? groups;
  final bool unreadOnly;
  final bool draftsOnly;
  final bool unansweredOnly;
  final bool bookmarksOnly;
  final bool? outgoing;
  final DateTime? after;
  final DateTime? before;
  PersonalSearchQuery({
    this.text = '',
    Iterable<String> networks = const [],
    Iterable<String> labelIds = const [],
    Iterable<String> messageTypes = const [],
    this.groups,
    this.unreadOnly = false,
    this.draftsOnly = false,
    this.unansweredOnly = false,
    this.bookmarksOnly = false,
    this.outgoing,
    this.after,
    this.before,
  }) : networks = Set.unmodifiable(networks),
       labelIds = Set.unmodifiable(labelIds),
       messageTypes = Set.unmodifiable(messageTypes) {
    if (after != null && before != null && !after!.isBefore(before!)) {
      throw ArgumentError('Invalid search time range');
    }
  }

  bool _matchesConversationFilters(ConversationSearchEntry entry) =>
      (networks.isEmpty || networks.contains(entry.conversation.network)) &&
      (labelIds.isEmpty || entry.metadata.labelIds.containsAll(labelIds)) &&
      (groups == null || groups == entry.isGroup) &&
      (!unreadOnly || entry.unreadCount > 0) &&
      (!draftsOnly || entry.hasDraft) &&
      (!unansweredOnly || entry.unanswered);

  bool matchesConversation(ConversationSearchEntry entry) =>
      _matchesConversationFilters(entry) &&
      _textMatches(entry.metadata.nickname ?? entry.displayName);

  /// When a message query includes conversation filters, missing metadata is
  /// unverified, not an implicit match. Message keywords match the body rather
  /// than requiring the same keywords to appear in the conversation title.
  bool matchesMessage(
    MessageSearchEntry entry, {
    ConversationSearchEntry? conversation,
  }) =>
      !entry.redacted &&
      ((labelIds.isEmpty &&
              groups == null &&
              !unreadOnly &&
              !draftsOnly &&
              !unansweredOnly) ||
          (conversation != null &&
              conversation.conversation == entry.source.conversation &&
              _matchesConversationFilters(conversation))) &&
      (networks.isEmpty ||
          networks.contains(entry.source.conversation.network)) &&
      (messageTypes.isEmpty || messageTypes.contains(entry.messageType)) &&
      (!bookmarksOnly || entry.bookmarked) &&
      (outgoing == null || outgoing == entry.isOutgoing) &&
      (after == null || entry.timestamp.isAfter(after!)) &&
      (before == null || entry.timestamp.isBefore(before!)) &&
      _textMatches(
        [entry.text, entry.transcript ?? '', entry.fileName ?? ''].join('\n'),
      );

  bool _textMatches(String value) {
    final terms = text.trim().toLowerCase().split(RegExp(r'\s+'));
    final normalized = value.toLowerCase();
    return terms.every(normalized.contains);
  }

  @override
  String toString() => 'PersonalSearchQuery(redacted)';
}

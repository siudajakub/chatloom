// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:personal_core/personal_core.dart';

/// A display constraint only. This never selects a source or changes a target.
bool notionMatchesNetwork(Iterable<String> sources, String? selected) =>
    selected == null || sources.contains(selected);

/// The network filter is deliberately applied after visibility/archive rules.
List<InboxRecord> notionFilterRecords(
  Iterable<InboxRecord> records, {
  String? network,
  InboxFilter filter = InboxFilter.inbox,
  String query = '',
  Set<String> hiddenLabelKeys = const {},
}) =>
    projectInbox(
          records,
          filter: filter,
          query: query,
          hiddenLabelKeys: hiddenLabelKeys,
        )
        .where((record) => notionMatchesNetwork(record.networks, network))
        .toList(growable: false);

/// Selections belong to an account, including when switching back to it.
class NotionAccountNetworkSelection {
  final Map<String, String> _selections = {};
  String? forAccount(String account) => _selections[account];
  void select(String account, String? network) {
    if (network == null) {
      _selections.remove(account);
    } else {
      _selections[account] = network;
    }
  }
}

String inboxViewLabel(InboxFilter filter) => switch (filter) {
  InboxFilter.groups => 'Groups',
  InboxFilter.ignored => 'Ignored',
  InboxFilter.technical => 'Technical',
  InboxFilter.inbox => 'Messages',
  InboxFilter.unread => 'Unread',
  InboxFilter.drafts => 'Drafts',
  InboxFilter.unanswered => 'Unanswered',
  InboxFilter.direct => 'People',
  InboxFilter.archive => 'Archive',
  InboxFilter.lowPriority => 'Low priority',
  InboxFilter.label => 'Messages',
  InboxFilter.all => 'All chats',
};

String notionNetworkLabel(String network) => switch (network.toLowerCase()) {
  'whatsapp' => 'WhatsApp',
  'slack' => 'Slack',
  'facebook' || 'facebookgo' || 'messenger' => 'Messenger',
  'instagram' || 'instagramgo' => 'Instagram',
  'telegram' => 'Telegram',
  'signal' => 'Signal',
  'discord' => 'Discord',
  'imessage' => 'iMessage',
  'sms' => 'SMS',
  'matrix' => 'Matrix',
  'unknown' || 'other' => 'Other',
  _ =>
    RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$').hasMatch(network)
        ? 'Other'
        : network,
};

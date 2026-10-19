// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// One encryption or sync problem as the inbox shows it.
@immutable
class InboxHealthItem {
  const InboxHealthItem({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    this.tone = NotionCalloutTone.warning,
  });

  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final NotionCalloutTone tone;
}

/// The inbox's single status row: the most important problem with its
/// one-tap fix, "N more" for the rest, and a dismiss that lasts until the
/// problems change. Data and callbacks only.
class InboxHealthNotice extends StatelessWidget {
  final List<InboxHealthItem> items;
  final ValueChanged<int> onFix;
  final VoidCallback onDismiss;
  final VoidCallback? onDetails;

  /// Index of the item whose fix is running.
  final int? busy;

  const InboxHealthNotice({
    super.key,
    required this.items,
    required this.onFix,
    required this.onDismiss,
    this.onDetails,
    this.busy,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final first = items.first;
    final more = items.length - 1;
    return NotionCallout(
      icon: first.icon,
      tone: first.tone,
      title: first.title,
      message: first.message,
      actionLabel: first.actionLabel,
      onAction: () => onFix(0),
      actionBusy: busy == 0,
      secondaryLabel: more > 0 ? '$more more' : null,
      onSecondary: more > 0 ? onDetails : null,
      onDismiss: onDismiss,
      dismissLabel: 'Hide until something changes',
    );
  }
}

/// Every current problem with its own fix (the "N more" sheet).
class InboxHealthDetails extends StatelessWidget {
  final List<InboxHealthItem> items;
  final ValueChanged<int> onFix;
  final int? busy;

  const InboxHealthDetails({
    super.key,
    required this.items,
    required this.onFix,
    this.busy,
  });

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: NotionSpace.xs,
      children: [
        for (final (index, item) in items.indexed)
          NotionCallout(
            icon: item.icon,
            tone: item.tone,
            title: item.title,
            message: item.message,
            actionLabel: item.actionLabel,
            onAction: () => onFix(index),
            actionBusy: busy == index,
          ),
      ],
    ),
  );
}

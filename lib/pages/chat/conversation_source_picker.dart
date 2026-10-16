// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:fluffychat/personal/ui/notion_network_filter.dart';
import 'package:fluffychat/personal/ui/notion_network_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart';

/// A real source, including the account and room identity used by the caller.
/// Titles/subtitles are display names; raw source identifiers are never shown.
class ConversationSourceOption {
  final ConversationRef conversation;
  final String title;
  final String? subtitle;
  final bool available;
  final String? unavailableReason;

  const ConversationSourceOption({
    required this.conversation,
    required this.title,
    this.subtitle,
    this.available = true,
    this.unavailableReason,
  });
}

/// Cancellation returns null and does not mutate any source selection.
/// Callers must revalidate their current account, reply and source after await.
Future<ConversationRef?> showConversationSourcePicker(
  BuildContext context, {
  required List<ConversationSourceOption> sources,
  ConversationRef? selected,
}) {
  final options = List<ConversationSourceOption>.unmodifiable(sources);
  final media = MediaQuery.of(context);
  final maxHeight = math.max(
    120.0,
    media.size.height - media.viewInsets.bottom - media.padding.vertical - 48,
  );
  Widget contents(BuildContext context) => TextFieldTapRegion(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: _ConversationSourceList(sources: options, selected: selected),
    ),
  );
  if (media.size.width < 600) {
    return showModalBottomSheet<ConversationRef>(
      context: context,
      requestFocus: false,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => SafeArea(top: false, child: contents(context)),
    );
  }
  return showDialog<ConversationRef>(
    context: context,
    requestFocus: false,
    builder: (context) =>
        Dialog(child: SizedBox(width: 420, child: contents(context))),
  );
}

class _ConversationSourceList extends StatelessWidget {
  final List<ConversationSourceOption> sources;
  final ConversationRef? selected;

  const _ConversationSourceList({
    required this.sources,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 8, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Send via',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: 'Cancel source selection',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
      Flexible(
        child: sources.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(20),
                child: Text('No sending sources available'),
              )
            : ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 8),
                itemCount: sources.length,
                itemBuilder: (context, index) =>
                    _option(context, sources[index]),
              ),
      ),
    ],
  );

  Widget _option(BuildContext context, ConversationSourceOption option) {
    final active = option.conversation == selected;
    final network = notionNetworkLabel(option.conversation.network);
    final reason = option.available
        ? null
        : option.unavailableReason ?? 'Source unavailable';
    final description = [
      network,
      option.title,
      if (option.subtitle != null) option.subtitle!,
      if (reason != null) reason,
    ].join(', ');
    void select() => Navigator.of(context).pop(option.conversation);
    return Semantics(
      label: description,
      button: true,
      selected: active,
      enabled: option.available,
      excludeSemantics: true,
      onTap: option.available ? select : null,
      child: Material(
        color: active
            ? Theme.of(context).colorScheme.surfaceContainerHighest
            : Colors.transparent,
        child: InkWell(
          onTap: option.available ? select : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
              children: [
                NotionNetworkGlyph(
                  network: option.conversation.network.toLowerCase(),
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        network,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      Text(option.title),
                      if (option.subtitle != null)
                        Text(
                          option.subtitle!,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      if (reason != null)
                        Text(
                          reason,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (active)
                  const Icon(Icons.check, size: 20)
                else if (!option.available)
                  const Icon(Icons.block_outlined, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

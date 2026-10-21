// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/personal/ui/notion_network_selector.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart';

import 'conversation_motion.dart';

/// Optional for a composer host that sends through a chosen source (the
/// merged person chat): the editor hint names that source, for example
/// "Message via Telegram". Other hosts keep the plain hint.
abstract interface class ConversationSourceHintHost {
  String get composerHint;
}

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
  Widget contents(BuildContext context) {
    // Only the values used: the whole MediaQuery would rebuild the list on
    // every unrelated change (for example each frame of the keyboard).
    final maxHeight = math.max(
      120.0,
      MediaQuery.sizeOf(context).height -
          MediaQuery.viewInsetsOf(context).bottom -
          MediaQuery.paddingOf(context).vertical -
          48,
    );
    return TextFieldTapRegion(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: _ConversationSourceList(sources: options, selected: selected),
      ),
    );
  }

  if (MediaQuery.sizeOf(context).width < 600) {
    return showModalBottomSheet<ConversationRef>(
      context: context,
      useRootNavigator: true,
      requestFocus: false,
      isScrollControlled: true,
      useSafeArea: true,
      // The design system's sheet motion (a quick plain slide under reduced
      // motion), as every other Notion sheet.
      sheetAnimationStyle: NotionMotion.sheetStyleOf(context),
      // A glass sheet in the dock's language (DESIGN.md "Glass").
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: NotionShapes.sheet,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: NotionGlassPanel(
          borderRadius: NotionGlass.sheetRadius,
          child: SafeArea(top: false, child: contents(context)),
        ),
      ),
    );
  }
  return showDialog<ConversationRef>(
    context: context,
    requestFocus: false,
    animationStyle: ConversationMotion.reduced(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: (context) => Dialog(
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: NotionGlass.dialogRadius,
      ),
      child: SizedBox(
        width: 420,
        child: NotionGlassPanel(
          borderRadius: NotionGlass.dialogRadius,
          child: contents(context),
        ),
      ),
    ),
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
              child: Semantics(
                header: true,
                child: Text(
                  'Send via',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
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
      // Rounded highlight inset from the panel edge; text stays on the
      // 20 pt gutter (8 inset + 12 padding).
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: NotionSpace.xs),
        child: Material(
          color: active
              ? Theme.of(context).colorScheme.surfaceContainerHighest
              : Colors.transparent,
          shape: NotionShapes.row,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: option.available ? select : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: NotionSpace.sm,
                vertical: NotionSpace.sm,
              ),
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
      ),
    );
  }
}

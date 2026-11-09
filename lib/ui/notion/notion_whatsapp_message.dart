// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion_contrast.dart';
import 'notion_tokens.dart';

/// An already received URL action. The caller validates the destination and
/// owns opening or copying it; this presentation never fetches a URL.
@immutable
class NotionMessageUrlAction {
  const NotionMessageUrlAction({required this.label, required this.url});

  final String label;
  final String url;
}

/// URL actions inside a message bubble, with separate open and copy targets.
/// Pass the bubble's foreground colours for own or custom-colour bubbles.
/// Both callbacks receive the unchanged URL, including its query and fragment.
class NotionWhatsAppActions extends StatelessWidget {
  const NotionWhatsAppActions({
    super.key,
    required this.actions,
    required this.onOpen,
    required this.onCopy,
    this.textColor,
    this.linkColor,
    this.backgroundColor,
  });

  final List<NotionMessageUrlAction> actions;
  final ValueChanged<String> onOpen;
  final ValueChanged<String> onCopy;
  final Color? textColor;
  final Color? linkColor;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) return const SizedBox.shrink();
    final colors = context.notion.colors;
    final foreground = textColor ?? colors.textSecondary;
    final link = NotionContrast.readable(
      backgroundColor ?? colors.surface,
      linkColor ?? textColor ?? colors.accent,
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: NotionBubble.mediaMaxWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: NotionSpace.xs,
        children: [
          for (final (index, action) in actions.indexed)
            _UrlActionRow(
              index: index,
              action: action,
              foreground: foreground,
              link: link,
              onOpen: () => onOpen(action.url),
              onCopy: () => onCopy(action.url),
            ),
        ],
      ),
    );
  }
}

class _UrlActionRow extends StatelessWidget {
  const _UrlActionRow({
    required this.index,
    required this.action,
    required this.foreground,
    required this.link,
    required this.onOpen,
    required this.onCopy,
  });

  final int index;
  final NotionMessageUrlAction action;
  final Color foreground;
  final Color link;
  final VoidCallback onOpen;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final host = Uri.tryParse(action.url)?.host;
    final domain = host == null || host.isEmpty ? action.url : host;
    return Material(
      color: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: NotionRadius.mdAll,
        side: BorderSide(
          color: foreground.withValues(alpha: .24),
          width: NotionSize.border,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              container: true,
              button: true,
              label: '${action.label}, $domain',
              hint: 'Open link in browser',
              onTap: onOpen,
              excludeSemantics: true,
              child: Tooltip(
                message: action.url,
                excludeFromSemantics: true,
                child: InkWell(
                  key: ValueKey('whatsapp-open-$index'),
                  onTap: onOpen,
                  excludeFromSemantics: true,
                  focusColor: link.withValues(alpha: .16),
                  hoverColor: link.withValues(alpha: .08),
                  borderRadius: NotionRadius.mdAll,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: NotionSize.touchTarget,
                      minWidth: NotionSize.touchTarget,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(NotionSpace.sm),
                      child: Row(
                        children: [
                          Icon(
                            Icons.open_in_new_rounded,
                            color: link,
                            size: NotionSize.iconSm,
                          ),
                          const SizedBox(width: NotionSpace.xs),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              spacing: NotionSpace.xxs,
                              children: [
                                Text(
                                  action.label,
                                  style: NotionType.callout.copyWith(
                                    color: link,
                                    fontWeight: FontWeight.w600,
                                    decoration: TextDecoration.underline,
                                    decorationColor: link,
                                  ),
                                ),
                                Text(
                                  domain,
                                  textDirection: TextDirection.ltr,
                                  style: NotionType.caption.copyWith(
                                    color: foreground,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Semantics(
            container: true,
            button: true,
            label: 'Copy link to $domain',
            onTap: onCopy,
            excludeSemantics: true,
            child: IconButton(
              key: ValueKey('whatsapp-copy-$index'),
              tooltip: 'Copy link',
              onPressed: onCopy,
              style: IconButton.styleFrom(
                minimumSize: const Size.square(NotionSize.touchTarget),
                foregroundColor: link,
                shape: NotionShapes.pill,
              ),
              icon: const Icon(Icons.copy_rounded, size: NotionSize.iconSm),
            ),
          ),
        ],
      ),
    );
  }
}

/// One received poll option. A missing count means unknown, not zero.
@immutable
class NotionPollOption {
  const NotionPollOption({
    required this.id,
    required this.label,
    this.votes,
    this.selected = false,
  });

  final String id;
  final String label;
  final int? votes;
  final bool selected;
}

/// A received poll and the results available to the caller. It has no voting
/// callback, focus target or gesture. [status] explains both where to vote and
/// whether the visible results are partial; the caller supplies localized copy.
class NotionReadOnlyPoll extends StatelessWidget {
  const NotionReadOnlyPoll({
    super.key,
    required this.question,
    required this.options,
    required this.status,
    this.textColor,
    this.linkColor,
  });

  final String question;
  final List<NotionPollOption> options;
  final String status;
  final Color? textColor;
  final Color? linkColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    final foreground = textColor ?? colors.text;
    final secondary = textColor ?? colors.textSecondary;
    final accent = linkColor ?? textColor ?? colors.accent;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      readOnly: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: NotionBubble.mediaMaxWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                question,
                style: NotionType.bodyStrong.copyWith(color: foreground),
              ),
            ),
            const SizedBox(height: NotionSpace.xs),
            for (final option in options)
              Semantics(
                key: ValueKey('whatsapp-poll-option-${option.id}'),
                container: true,
                label: option.label,
                value: option.votes?.toString(),
                selected: option.selected,
                readOnly: true,
                excludeSemantics: true,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: NotionSpace.xs),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox.square(
                        dimension: NotionSize.icon,
                        child: option.selected
                            ? Icon(
                                Icons.check_rounded,
                                color: accent,
                                size: NotionSize.icon,
                              )
                            : null,
                      ),
                      const SizedBox(width: NotionSpace.xs),
                      Expanded(
                        flex: 4,
                        child: Text(
                          option.label,
                          style: NotionType.callout.copyWith(color: foreground),
                        ),
                      ),
                      if (option.votes != null) ...[
                        const SizedBox(width: NotionSpace.sm),
                        Flexible(
                          child: Text(
                            option.votes.toString(),
                            textAlign: TextAlign.end,
                            style: NotionType.caption.copyWith(
                              color: secondary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            const SizedBox(height: NotionSpace.xs),
            Text(status, style: NotionType.caption.copyWith(color: secondary)),
          ],
        ),
      ),
    );
  }
}

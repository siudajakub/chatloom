// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/message_preview.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'conversation_source.dart';

/// Reply/edit context above the composer (Messenger style): "Replying to
/// Anna" or "Editing message" over a one-line muted preview, with a small
/// round close button at the end. It grows in and out with a size reveal
/// (keeping the last content while it collapses), and switching the target
/// cross-fades the content. It reads only the reply/edit target, never the
/// composer text, so typing does not rebuild it.
class ReplyDisplay extends StatefulWidget {
  final ConversationComposerHost controller;
  const ReplyDisplay(this.controller, {super.key});

  @override
  State<ReplyDisplay> createState() => _ReplyDisplayState();
}

class _ReplyDisplayState extends State<ReplyDisplay> {
  Widget? _last;

  ConversationComposerHost get controller => widget.controller;

  Event _display(Event event) {
    final timeline = controller.timelineFor(event);
    return timeline == null ? event : event.getDisplayEvent(timeline);
  }

  @override
  Widget build(BuildContext context) {
    final reply = controller.replyEvent;
    final edit = controller.editEvent;
    final target = reply ?? edit;
    if (target != null) {
      final l10n = L10n.of(context);
      final display = _display(target);
      _last = Padding(
        padding: const EdgeInsetsDirectional.only(
          start: NotionSpace.sm,
          top: NotionSpace.xxs,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: NotionFadeThrough(
                alignment: AlignmentDirectional.centerStart,
                child: _ReplyLines(
                  key: ValueKey((reply?.eventId, edit?.eventId)),
                  editing: reply == null,
                  title: reply != null
                      ? l10n.replyingToName(
                          display.senderFromMemoryOrFallback.calcDisplayname(),
                        )
                      : l10n.editingMessage,
                  preview: personalPreviewLabel(
                    display,
                    i18n: MatrixLocals(l10n),
                  ),
                ),
              ),
            ),
            _CloseButton(
              label: reply != null ? l10n.cancelReply : l10n.close,
              onPressed: controller.cancelReplyEventAction,
            ),
          ],
        ),
      );
    }
    return NotionSizeReveal(
      visible: target != null,
      alignment: AlignmentDirectional.bottomStart,
      child: _last ?? const SizedBox.shrink(),
    );
  }
}

/// "Replying to Anna" / "Editing message" over a one-line muted preview.
class _ReplyLines extends StatelessWidget {
  final bool editing;
  final String title;
  final String preview;

  const _ReplyLines({
    super.key,
    required this.editing,
    required this.title,
    required this.preview,
  });

  @override
  Widget build(BuildContext context) {
    final notion = context.notion;
    final titleStyle = notion.typography.caption.copyWith(
      fontWeight: FontWeight.w600,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          spacing: NotionSpace.xxs,
          children: [
            if (editing)
              Icon(
                Icons.edit_outlined,
                size: titleStyle.fontSize,
                color: notion.colors.text,
              ),
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
            ),
          ],
        ),
        Text(
          preview,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: notion.typography.footnoteMuted,
        ),
      ],
    );
  }
}

/// Small round close glyph with a full-size touch target.
class _CloseButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const _CloseButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    return NotionPressable(
      scale: NotionMotion.pressIcon,
      child: IconButton(
        tooltip: label,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          minimumSize: const Size.square(NotionSize.touchTarget),
          shape: const CircleBorder(),
          foregroundColor: colors.text,
        ),
        icon: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.selected,
            shape: BoxShape.circle,
          ),
          child: const SizedBox.square(
            dimension: NotionSize.iconLg,
            child: Icon(Icons.close, size: NotionSize.iconSm),
          ),
        ),
      ),
    );
  }
}

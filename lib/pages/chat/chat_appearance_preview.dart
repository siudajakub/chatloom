// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// Sample conversation rendered with the same message bubbles as the timeline.
class ChatAppearancePreview extends StatelessWidget {
  final Widget background;
  final Color? backgroundColor;
  final Color? incomingColor;
  final Color? outgoingColor;

  const ChatAppearancePreview({
    super.key,
    required this.background,
    this.backgroundColor,
    this.incomingColor,
    this.outgoingColor,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    Widget bubble(String text, {required bool outgoing}) {
      final fill = outgoing ? outgoingColor : incomingColor;
      return ConversationBubble(
        outgoing: outgoing,
        backgroundColor: fill,
        avatar: outgoing
            ? null
            : const NotionInitialAvatar(
                name: 'Anna',
                size: NotionBubble.avatar,
              ),
        body: Text(
          text,
          style: NotionType.body.copyWith(
            color: fill == null ? null : NotionContrast.on(fill),
          ),
        ),
      );
    }

    return IgnorePointer(
      child: ClipRRect(
        borderRadius: NotionRadius.lgAll,
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: NotionRadius.lgAll,
            border: Border.all(color: tokens.colors.border),
          ),
          child: ColoredBox(
            color: backgroundColor ?? tokens.colors.background,
            child: Stack(
              children: [
                background,
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    NotionSpace.sm,
                    NotionSpace.xxs,
                    NotionSpace.sm,
                    NotionSpace.md,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      bubble('Coffee tomorrow?', outgoing: false),
                      bubble('How about ten?', outgoing: true),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// Presentation data only: no timeline, read receipts or media controllers.
class ChatThreadPreviewMessage {
  final String text;
  final String sender;
  final DateTime timestamp;
  final bool outgoing;
  final String? source;

  const ChatThreadPreviewMessage({
    required this.text,
    required this.sender,
    required this.timestamp,
    required this.outgoing,
    this.source,
  });
}

class ChatThreadPreview extends StatelessWidget {
  final List<ChatThreadPreviewMessage> messages;
  final bool loading;
  final bool failed;
  final bool loadingOlder;
  final VoidCallback? onLoadOlder;

  const ChatThreadPreview({
    super.key,
    required this.messages,
    this.loading = false,
    this.failed = false,
    this.loadingOlder = false,
    this.onLoadOlder,
  });

  @override
  Widget build(BuildContext context) {
    final typography = context.notion.typography;
    final localizations = MaterialLocalizations.of(context);
    final bubbleColors = ConversationBubbleColors.of(context);
    return Padding(
      padding: const EdgeInsets.all(NotionSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Preview · stays unread', style: typography.caption),
          const SizedBox(height: NotionSpace.sm),
          if (loading)
            const Center(
              child: NotionDelayedSpinner(semanticsLabel: 'Loading preview'),
            )
          else if (messages.isEmpty)
            Text(
              failed
                  ? 'Preview unavailable. Open the chat to try again.'
                  : 'No saved messages yet. Open the chat to load history.',
              style: typography.calloutMuted,
            )
          else
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: math.min(
                  MediaQuery.sizeOf(context).height * .36,
                  NotionSize.sheetDialogMaxHeight / 2,
                ),
              ),
              child: NotificationListener<ScrollUpdateNotification>(
                onNotification: (notification) {
                  if (notification.depth == 0 &&
                      notification.dragDetails != null &&
                      notification.metrics.extentAfter <
                          NotionSize.touchTarget * 2 &&
                      !loadingOlder) {
                    onLoadOlder?.call();
                  }
                  return false;
                },
                child: ListView.separated(
                  key: const ValueKey('chat-thread-preview-messages'),
                  primary: false,
                  shrinkWrap: true,
                  reverse: true,
                  itemCount: messages.length + 1,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: NotionSpace.sm),
                  itemBuilder: (context, index) {
                    if (index == messages.length) {
                      return onLoadOlder != null
                          ? NotionButton.ghost(
                              label: 'Load older messages',
                              busy: loadingOlder,
                              onPressed: loadingOlder ? null : onLoadOlder,
                            )
                          : Text(
                              'End of saved preview',
                              style: typography.caption,
                            );
                    }
                    final message = messages[messages.length - 1 - index];
                    return ConversationBubble(
                      outgoing: message.outgoing,
                      heading: Text(
                        [message.sender, ?message.source].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typography.caption,
                      ),
                      body: Text(
                        message.text,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: typography.body.copyWith(
                          color: message.outgoing
                              ? bubbleColors.outgoingText
                              : bubbleColors.text,
                        ),
                      ),
                      footer: Text(
                        '${localizations.formatShortDate(message.timestamp)} '
                        '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(message.timestamp))}',
                        style: typography.caption,
                      ),
                    );
                  },
                ),
              ),
            ),
          if (failed && messages.isNotEmpty) ...[
            const SizedBox(height: NotionSpace.xs),
            Text(
              'Some saved messages could not be loaded.',
              style: typography.caption,
            ),
          ],
        ],
      ),
    );
  }
}

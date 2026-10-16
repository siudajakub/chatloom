// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/conversation_bubble.dart';
import 'package:fluffychat/pages/chat/conversation_grouping.dart';
import 'package:fluffychat/pages/chat/conversation_message_actions.dart';
import 'package:fluffychat/pages/chat/conversation_message_gestures.dart';
import 'package:fluffychat/pages/chat/conversation_motion.dart';
import 'package:fluffychat/pages/chat/matrix_conversation_grouping.dart';
import 'package:fluffychat/personal/capabilities.dart';
import 'package:fluffychat/personal/inbox_projection.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/utils/adaptive_bottom_sheet.dart';
import 'package:fluffychat/utils/date_time_extension.dart';
import 'package:fluffychat/utils/file_description.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/member_actions_popup_menu_button.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import '../sticker_picker_dialog.dart';
import 'message_content.dart';
import 'message_reactions.dart';
import 'reply_content.dart';
import 'state_message.dart';

class Message extends StatelessWidget {
  final Event event;
  final Event? nextEvent;
  final Event? previousEvent;
  final bool displayReadMarker;
  final void Function(Event) onSelect;
  final void Function(Event) onInfoTab;
  final void Function(String) scrollToEventId;
  final void Function() onSwipe;
  final void Function() onMention;
  final void Function() onEdit;
  final void Function(String eventId)? enterThread;
  final bool longPressSelect;
  final bool textSelectionActive;
  final String? readMarkerEventId;
  final bool selected;
  final bool singleSelected;
  final Timeline timeline;
  final bool highlightMarker;
  final bool animateIn;
  final bool wallpaperMode;
  final ScrollController scrollController;
  final List<Color> colors;
  final void Function()? onExpand;
  final bool isCollapsed;
  final Set<String> bigEmojis;

  const Message(
    this.event, {
    this.nextEvent,
    this.previousEvent,
    this.displayReadMarker = false,
    this.longPressSelect = false,
    required this.bigEmojis,
    required this.onSelect,
    required this.onInfoTab,
    required this.scrollToEventId,
    required this.onSwipe,
    this.selected = false,
    this.textSelectionActive = false,
    this.readMarkerEventId,
    required this.onEdit,
    required this.singleSelected,
    required this.timeline,
    this.highlightMarker = false,
    this.animateIn = false,
    this.wallpaperMode = false,
    required this.onMention,
    required this.scrollController,
    required this.colors,
    this.onExpand,
    required this.enterThread,
    this.isCollapsed = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!{
      EventTypes.Message,
      EventTypes.Sticker,
      EventTypes.CallInvite,
      PollEventContent.startType,
    }.contains(event.type)) {
      if (event.type.startsWith('m.call.')) return const SizedBox.shrink();
      return StateMessage(event, onExpand: onExpand, isCollapsed: isCollapsed);
    }
    if (event.messageType == EventTypes.KeyVerificationRequest)
      return StateMessage(event);
    final own = event.senderId == event.room.client.userID;
    final position = conversationGroupPosition(
      item: conversationGroupingItem(event, boundary: displayReadMarker),
      // The production list is reversed: nextEvent is chronologically older.
      older: nextEvent == null
          ? null
          : conversationGroupingItem(
              nextEvent!,
              boundary: nextEvent!.eventId == readMarkerEventId,
            ),
      newer: previousEvent == null
          ? null
          : conversationGroupingItem(
              previousEvent!,
              boundary: previousEvent!.eventId == readMarkerEventId,
            ),
    );
    final first =
        position == ConversationGroupPosition.single ||
        position == ConversationGroupPosition.first;
    final last =
        position == ConversationGroupPosition.single ||
        position == ConversationGroupPosition.last;
    final display = event.getDisplayEvent(timeline);
    final palette = InboxProjection(
      PersonalClient.of(event.room.client),
    ).metadataFor(event.room).theme;
    final custom = own ? palette?.outgoingColor : palette?.incomingColor;
    final textColor = custom is int
        ? (Color(custom).computeLuminance() > .179
              ? Colors.black87
              : Colors.white)
        : ConversationBubbleColors.of(context).text;
    final radius = BorderRadius.circular(20);
    final media =
        {
          MessageTypes.Image,
          MessageTypes.Video,
          MessageTypes.Sticker,
        }.contains(event.messageType) &&
        event.fileDescription == null &&
        !event.redacted;
    final sender = event.senderFromMemoryOrFallback;
    final reactionPicker = singleSelected && event.room.canSendDefaultMessages;
    final replyCapability = RoomCapabilities.forFeature(
      BridgeFeature.reply,
      event.room,
      event: event,
    );
    final canReply =
        !event.redacted &&
        event.status.isSent &&
        event.room.membership == Membership.join &&
        event.room.canSendDefaultMessages &&
        replyCapability.status != CapabilityStatus.unavailable;
    final statusColor = theme.colorScheme.onSurfaceVariant;
    final status = Wrap(
      spacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (last || selected)
          Text(
            selected
                ? event.originServerTs.localizedDetailedTime(context)
                : event.originServerTs.localizedTimeOfDay(context),
            style: TextStyle(fontSize: 11, color: statusColor),
          ),
        if (event.hasAggregatedEvents(timeline, RelationshipTypes.edit))
          Text(
            L10n.of(context).edited,
            style: TextStyle(fontSize: 11, color: statusColor),
          ),
        if (display.status.isError)
          Text(
            L10n.of(context).couldNotBeSent,
            style: TextStyle(fontSize: 11, color: theme.colorScheme.error),
          ),
        if (display.status == EventStatus.sending) ...[
          Text(switch (display.fileSendingStatus) {
            null => L10n.of(context).sending,
            FileSendingStatus.generatingThumbnail => L10n.of(
              context,
            ).generatingThumbnail,
            FileSendingStatus.encrypting => L10n.of(context).encrypting,
            FileSendingStatus.uploading => L10n.of(context).uploading,
          }, style: TextStyle(fontSize: 11, color: statusColor)),
          const SizedBox.square(
            dimension: 11,
            child: CircularProgressIndicator(strokeWidth: 1),
          ),
        ],
      ],
    );
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (event.inReplyToEventId(includingFallback: false) != null)
          FutureBuilder<Event?>(
            future: event.getReplyEvent(timeline),
            builder: (context, snapshot) {
              final original = snapshot.data;
              if (original == null)
                return Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    snapshot.connectionState == ConnectionState.done
                        ? 'Original message unavailable'
                        : 'Loading reply…',
                  ),
                );
              return InkWell(
                onTap: () => scrollToEventId(original.eventId),
                child: AbsorbPointer(
                  child: ReplyContent(
                    original,
                    ownMessage: own,
                    foregroundColor: textColor,
                    timeline: timeline,
                  ),
                ),
              );
            },
          ),
        MessageContent(
          display,
          textColor: textColor,
          linkColor: custom is int ? textColor : theme.colorScheme.primary,
          onInfoTab: onInfoTab,
          borderRadius: radius,
          timeline: timeline,
          selected: selected,
          bigEmojis: bigEmojis,
        ),
      ],
    );
    final threads = event.aggregatedEvents(timeline, RelationshipTypes.thread);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: FluffyThemes.maxTimelineWidth,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConversationMessageEntrance(
                identity: event.transactionId ?? event.eventId,
                animate: animateIn,
                child: ConversationBubble(
                  outgoing: own,
                  groupPosition: position,
                  media: media,
                  selected: selected || highlightMarker,
                  backgroundColor: custom is int ? Color(custom) : null,
                  avatar: longPressSelect && !event.redacted
                      ? IconButton(
                          tooltip: L10n.of(context).select,
                          onPressed: () => onSelect(event),
                          icon: Icon(
                            selected
                                ? Icons.check_circle
                                : Icons.circle_outlined,
                          ),
                        )
                      : FutureBuilder<User?>(
                          future: event.fetchSenderUser(),
                          builder: (context, snapshot) {
                            final user = snapshot.data ?? sender;
                            return Avatar(
                              client: event.room.client,
                              mxContent: user.avatarUrl,
                              name: user.calcDisplayname(),
                              size: 28,
                              onTap: () => showMemberActionsPopupMenu(
                                context: context,
                                user: user,
                                onMention: onMention,
                              ),
                            );
                          },
                        ),
                  heading: first && !own && !event.room.isDirectChatForDisplay
                      ? Text(
                          sender.calcDisplayname(),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: statusColor,
                          ),
                        )
                      : null,
                  footer: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: own
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      status,
                      ConversationReactionFeedback(event, timeline),
                      if (reactionPicker) _reactionPicker(context),
                      if (enterThread != null && threads.isNotEmpty)
                        TextButton.icon(
                          onPressed: () => enterThread!(event.eventId),
                          icon: const Icon(Icons.message_outlined, size: 16),
                          label: Text(
                            '${L10n.of(context).countReplies(threads.length)} | ${threads.first.calcLocalizedBodyFallback(MatrixLocals(L10n.of(context)), withSenderNamePrefix: true)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                  reactions:
                      event.hasAggregatedEvents(
                        timeline,
                        RelationshipTypes.reaction,
                      )
                      ? MessageReactions(event, timeline)
                      : null,
                  surfaceBuilder: (surface) => ConversationMessageGestures(
                    identity: event.transactionId ?? event.eventId,
                    enabled:
                        !longPressSelect && !selected && !textSelectionActive,
                    swipeRightToLeft: AppSettings.swipeRightToLeftToReply.value,
                    interactiveContent: conversationHasInteractiveContent(
                      display,
                    ),
                    onReply: canReply ? onSwipe : null,
                    quickLikeEnabled: AppSettings.doubleTapToReact.value,
                    likeEmoji: AppSettings.doubleTapReaction.value,
                    onLike: () => ConversationMessageActions.react(
                      context,
                      event,
                      timeline,
                      AppSettings.doubleTapReaction.value,
                    ),
                    child: surface,
                  ),
                  body: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: longPressSelect ? () => onSelect(event) : null,
                    onLongPress: longPressSelect
                        ? null
                        : () {
                            HapticFeedback.heavyImpact();
                            onSelect(event);
                          },
                    child: AbsorbPointer(
                      absorbing: longPressSelect,
                      child: content,
                    ),
                  ),
                ),
              ),
              if (displayReadMarker)
                Row(
                  children: [
                    Expanded(
                      child: Divider(color: theme.colorScheme.outlineVariant),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 12,
                      ),
                      child: Text(
                        L10n.of(context).readUpToHere,
                        style: TextStyle(fontSize: 11, color: statusColor),
                      ),
                    ),
                    Expanded(
                      child: Divider(color: theme.colorScheme.outlineVariant),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _reactionPicker(BuildContext context) => Wrap(
    spacing: 2,
    children: [
      for (final emoji in AppConfig.defaultReactions)
        IconButton(
          tooltip: 'React $emoji',
          onPressed: () {
            onSelect(event);
            ConversationMessageActions.react(context, event, timeline, emoji);
          },
          icon: Text(emoji, style: const TextStyle(fontSize: 20)),
        ),
      IconButton(
        tooltip: L10n.of(context).customReaction,
        icon: const Icon(Icons.add_reaction_outlined),
        onPressed: () => _customReaction(context),
      ),
    ],
  );

  Future<void> _customReaction(BuildContext context) async {
    final theme = Theme.of(context);
    final emoji = await showAdaptiveBottomSheet<String>(
      context: context,
      builder: (context) => Scaffold(
        appBar: AppBar(
          title: Text(L10n.of(context).customReaction),
          leading: CloseButton(
            onPressed: () => Navigator.of(context).pop(null),
          ),
        ),
        body: SizedBox(
          height: double.infinity,
          child: DefaultTabController(
            length: 2,
            child: Column(
              children: [
                TabBar(
                  tabs: [
                    Tab(text: L10n.of(context).emojis),
                    Tab(text: L10n.of(context).stickers),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      EmojiPicker(
                        onEmojiSelected: (_, emoji) =>
                            Navigator.of(context).pop(emoji.emoji),
                        config: Config(
                          locale: Localizations.localeOf(context),
                          emojiViewConfig: const EmojiViewConfig(
                            backgroundColor: Colors.transparent,
                          ),
                          bottomActionBarConfig: const BottomActionBarConfig(
                            enabled: false,
                          ),
                          categoryViewConfig: CategoryViewConfig(
                            initCategory: Category.SMILEYS,
                            backspaceColor: theme.colorScheme.primary,
                            iconColor: theme.colorScheme.primary.withAlpha(128),
                            iconColorSelected: theme.colorScheme.primary,
                            indicatorColor: theme.colorScheme.primary,
                            backgroundColor: theme.colorScheme.surface,
                          ),
                          skinToneConfig: SkinToneConfig(
                            dialogBackgroundColor: Color.lerp(
                              theme.colorScheme.surface,
                              theme.colorScheme.primaryContainer,
                              0.75,
                            )!,
                            indicatorColor: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      StickerPickerDialog(
                        room: event.room,
                        usage: ImagePackUsage.emoticon,
                        onSelected: (sticker) =>
                            Navigator.of(context).pop(sticker.url.toString()),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (emoji == null || !context.mounted) return;
    await ConversationMessageActions.react(context, event, timeline, emoji);
  }
}

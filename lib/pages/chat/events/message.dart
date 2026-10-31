// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/config/themes.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/conversation_grouping.dart';
import 'package:chatloom/pages/chat/conversation_message_actions.dart';
import 'package:chatloom/pages/chat/conversation_message_gestures.dart';
import 'package:chatloom/pages/chat/conversation_message_menu.dart';
import 'package:chatloom/pages/chat/conversation_motion.dart';
import 'package:chatloom/pages/chat/matrix_conversation_grouping.dart';
import 'package:chatloom/pages/chat/media_album.dart';
import 'package:chatloom/personal/bridge_notices.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/deleted_messages.dart';
import 'package:chatloom/personal/delivery_ticks.dart';
import 'package:chatloom/personal/encryption/undecryptable_messages.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/instagram_share.dart';
import 'package:chatloom/personal/kept_messages.dart';
import 'package:chatloom/personal/media/gallery_content.dart';
import 'package:chatloom/personal/message_delivery.dart';
import 'package:chatloom/personal/message_preview.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/bridge_notice_line.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/date_time_extension.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:chatloom/widgets/member_actions_popup_menu_button.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart'
    show ChatTheme, isInstagramShare;

import 'kept_message.dart';
import 'message_content.dart';
import 'message_delivery_status.dart';
import 'message_delivery_ticks.dart';
import 'message_reactions.dart';
import 'outgoing_upload_progress.dart';
import 'reply_content.dart';
import 'round_video_view.dart';
import 'state_message.dart';

class Message extends StatelessWidget {
  final Event event;
  final Event? nextEvent;
  final Event? previousEvent;
  final bool displayReadMarker;
  final void Function(Event) onInfoTab;
  final void Function(String) scrollToEventId;
  final void Function() onSwipe;
  final void Function() onMention;
  final void Function(String eventId)? enterThread;
  final bool textSelectionActive;
  final String? readMarkerEventId;

  /// The actions of the long-press menu for this message (reply, copy,
  /// forward, delete...), decided by the conversation host. Reactions are
  /// added by the menu itself.
  final List<ConversationMessageAction> Function(Event event)? menuActions;
  final Timeline timeline;

  /// The message a jump landed on: it flashes once (Telegram), then rests.
  final bool highlightMarker;
  final bool wallpaperMode;
  final ScrollController scrollController;
  final void Function()? onExpand;
  final bool isCollapsed;
  final Set<String> bigEmojis;

  /// Private chat palette resolved once per list build by the caller. When
  /// null the row resolves it itself (slower: parses person groups per row).
  final ({ChatTheme? theme})? roomPalette;

  /// Heading over the first message of a series instead of the sender name,
  /// e.g. the source network in a merged person chat.
  final String? sourceLabel;

  /// Series breaks the list cannot see (hidden source state events).
  final bool Function(Event event)? seriesBoundary;

  /// Bridge features (reply, reaction, poll) must be verified, not merely
  /// not refused, before they are offered.
  final bool strictCapabilities;

  /// This row's place in a photo/video album (`MediaAlbums`): the lead
  /// draws the whole grid, a hidden member draws nothing (its row stays for
  /// list indexes and scroll targets); null for an ordinary message.
  final MediaAlbumSlot? album;

  const Message(
    this.event, {
    this.album,
    this.nextEvent,
    this.previousEvent,
    this.displayReadMarker = false,
    required this.bigEmojis,
    required this.onInfoTab,
    required this.scrollToEventId,
    required this.onSwipe,
    this.textSelectionActive = false,
    this.readMarkerEventId,
    this.menuActions,
    required this.timeline,
    this.highlightMarker = false,
    this.wallpaperMode = false,
    required this.onMention,
    required this.scrollController,
    this.onExpand,
    required this.enterThread,
    this.isCollapsed = false,
    this.roomPalette,
    this.sourceLabel,
    this.seriesBoundary,
    this.strictCapabilities = false,
    super.key,
  });

  /// Resolves the private palette for [room]; call once per list build.
  static ({ChatTheme? theme}) resolveRoomPalette(Room room) => (
    theme: InboxProjection(
      PersonalClient.of(room.client),
    ).metadataFor(room).theme,
  );

  /// Value-comparable form of a resolved palette, so listeners can tell a
  /// real colour/background change from unrelated private-store activity.
  static Object? paletteSignature(({ChatTheme? theme}) palette) {
    final theme = palette.theme;
    return theme == null
        ? null
        : (
            theme.backgroundColor,
            theme.incomingColor,
            theme.outgoingColor,
            theme.wallpaperAsset,
          );
  }

  @override
  Widget build(BuildContext context) {
    if (album?.lead == false) return const SizedBox.shrink();
    // A message the user is deleting draws as deleted at once, exactly as
    // it will once the server's redaction arrives (and after a restart).
    final event = deletedDisplayCopy(this.event);
    // "Keep deleted messages": the kept content instead of the placeholder.
    final kept = event.redacted ? KeptMessages.of(event) : null;
    final theme = Theme.of(context);
    // A message this device cannot decrypt yet is still a message: it keeps
    // its sender, side and grouping, and MessageContent shows its key state.
    if (!isUndecryptable(event) &&
        !{
          EventTypes.Message,
          EventTypes.Sticker,
          EventTypes.CallInvite,
          PollEventContent.startType,
        }.contains(event.type)) {
      if (event.type.startsWith('m.call.')) return const SizedBox.shrink();
      return StateMessage(event, onExpand: onExpand, isCollapsed: isCollapsed);
    }
    if (event.messageType == EventTypes.KeyVerificationRequest) {
      return StateMessage(event);
    }
    // A bridge's own notice is a service line, not the contact's bubble
    // (BR-08). Only notices pay for the display-event lookup.
    if (event.messageType == MessageTypes.Notice) {
      final notice = bridgeServiceNotice(event.getDisplayEvent(timeline));
      if (notice != null) return BridgeNoticeLine(notice: notice);
    }
    final own = event.senderId == event.room.client.userID;
    final boundary = seriesBoundary;
    final position = conversationGroupPosition(
      item: conversationGroupingItem(
        event,
        boundary: displayReadMarker || (boundary?.call(event) ?? false),
      ),
      // The production list is reversed: nextEvent is chronologically older.
      older: nextEvent == null
          ? null
          : conversationGroupingItem(
              nextEvent!,
              boundary:
                  nextEvent!.eventId == readMarkerEventId ||
                  (boundary?.call(nextEvent!) ?? false),
            ),
      newer: previousEvent == null
          ? null
          : conversationGroupingItem(
              previousEvent!,
              boundary:
                  previousEvent!.eventId == readMarkerEventId ||
                  (boundary?.call(previousEvent!) ?? false),
            ),
    );
    final first =
        position == ConversationGroupPosition.single ||
        position == ConversationGroupPosition.first;
    final last =
        position == ConversationGroupPosition.single ||
        position == ConversationGroupPosition.last;
    final display = event.getDisplayEvent(timeline);
    // Rounds render without a fill, so their text sits on the page.
    final round = MessageContent.rendersRound(display);
    final palette = round
        ? null
        : (roomPalette ?? resolveRoomPalette(event.room)).theme;
    final custom = own ? palette?.outgoingColor : palette?.incomingColor;
    final bubbleColors = ConversationBubbleColors.of(context);
    final textColor = custom is int
        ? NotionContrast.on(Color(custom))
        : (own ? bubbleColors.outgoingText : bubbleColors.text);
    final radius = ConversationBubble.radiusFor(
      outgoing: own,
      position: position,
      outerRadius: NotionDisplayPreferences.of(context).bubbleRadius,
    ).resolve(Directionality.of(context));
    // Time, captions and names sit on the chat background, which a private
    // palette may make light in the dark theme (or the reverse).
    final pageBackground = palette?.backgroundColor is int
        ? Color(palette!.backgroundColor!)
        : context.notion.colors.background;
    // Over a wallpaper, metadata gets a chip of the page colour.
    final metaBackdrop = wallpaperMode ? pageBackground : null;
    // A caption (an Instagram reel's link, too) stays inside the media
    // bubble below the frame, so captioned media keeps the media width.
    final media =
        {
          MessageTypes.Image,
          MessageTypes.Video,
          MessageTypes.Sticker,
          ...GalleryContent.msgTypes,
        }.contains(event.messageType) &&
        !event.redacted;
    final sharedPost =
        !display.redacted &&
        !round &&
        (isInstagramShare(display.content) ||
            (display.messageType == MessageTypes.Text &&
                InstagramShare.fromText(display.body) != null));
    final sender = event.senderFromMemoryOrFallback;
    final canReply = ConversationMessageActions.canReply(
      event,
      strict: strictCapabilities,
    );
    final pollBlocked =
        strictCapabilities &&
        event.type == PollEventContent.startType &&
        !RoomCapabilities.forFeature(
          BridgeFeature.poll,
          event.room,
          event: event,
        ).allowed;
    final statusColor = NotionContrast.readable(
      pageBackground,
      theme.colorScheme.onSurfaceVariant,
    );
    // Edits and reactions outlive a deletion on the server; a deleted
    // message shows neither (the SDK only drops them in the open session).
    final edited =
        !event.redacted &&
        event.hasAggregatedEvents(timeline, RelationshipTypes.edit);
    final delivery = own
        ? messageDeliveryOf(
            event,
            timeline,
            network: () =>
                notionNetworkLabel(PersonalClient.networkOf(event.room)),
          )
        : MessageDelivery.none;
    // Ticks of an own message: Telegram's clock while it is sending, ✓ sent,
    // ✓✓ delivered to the network, ✓✓ in the accent once read
    // (delivery-ticks lane). The slot stays from the clock on, so the ✓
    // grows in place when the server has the message.
    final ticks =
        own &&
            (delivery.kind == MessageDeliveryKind.none ||
                delivery.kind == MessageDeliveryKind.sending)
        ? messageDeliveryProgress(event, timeline)
        : DeliveryProgress.none;
    final displayPrefs = NotionDisplayPreferences.of(context);
    final showsTicks = ticks.tick != null && displayPrefs.deliveryTicks;
    // Over the circle: always the time, colours inherited from the pill.
    final roundStatus = round
        ? Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              if (edited) Text(L10n.of(context).edited),
              Text(event.originServerTs.localizedTimeOfDay(context)),
              if (showsTicks)
                MessageDeliveryTicks(
                  event: event,
                  timeline: timeline,
                  progress: ticks,
                  color: roundVideoOnScrim,
                  readColor: NotionContrast.readable(
                    NotionMediaColors.stageScrim.withValues(alpha: 1),
                    context.notion.colors.accent,
                    minimum: 3,
                  ),
                ),
              if (delivery.failed)
                Icon(
                  Icons.error,
                  size: NotionSize.iconSm,
                  color: theme.colorScheme.error,
                  semanticLabel: delivery.label,
                ),
              // Telegram's clock (in the tick slot when ticks show); the
              // circle itself shows the upload.
              if (delivery.kind == MessageDeliveryKind.sending && !showsTicks)
                const NotionDelayedReveal(
                  child: Icon(
                    Icons.schedule,
                    size: 11,
                    color: roundVideoOnScrim,
                  ),
                ),
            ],
          )
        : null;
    // Delivery-status block (composer-send lane). "Sending…" appears only
    // after the loader grace, so a fast send never flashes it; a failure
    // gets its own tappable line below (Retry / Delete).
    final sending = delivery.kind == MessageDeliveryKind.sending;
    // Settings → Appearance → "Message times": the group's last message
    // (default), every message, or none. Ticks stay on the group's last.
    final timeShown = displayPrefs.showsTime(last: last);
    final ticksShown = last && showsTicks;
    final timeVisible = timeShown || edited || ticksShown;
    final hasStatus = timeVisible || sending;
    // Photos, videos, voice and files fill a ring with their upload.
    final upload = sending && isOutgoingUpload(event);
    Widget sendingLabel({required bool clock}) => NotionDelayedReveal(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          Text(
            L10n.of(context).sending,
            style: TextStyle(fontSize: 11, color: statusColor),
          ),
          // Telegram's clock for text; an upload fills its ring.
          if (upload)
            OutgoingUploadIndicator(
              progress: uploadProgressOf(event),
              size: 11,
              strokeWidth: 1.5,
              color: statusColor,
            )
          else if (clock)
            Icon(Icons.schedule, size: 11, color: statusColor),
        ],
      ),
    );
    final status = Wrap(
      spacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (timeShown)
          Text(
            event.originServerTs.localizedTimeOfDay(context),
            style: TextStyle(fontSize: 11, color: statusColor),
          ),
        if (edited)
          Text(
            L10n.of(context).edited,
            style: TextStyle(fontSize: 11, color: statusColor),
          ),
        if (ticksShown)
          // One shape from sending to read: the clock turns into the ✓ and
          // "Sending…" folds away sideways instead of cutting out.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              MessageDeliveryTicks(
                event: event,
                timeline: timeline,
                progress: ticks,
                clock: !upload,
                color: statusColor,
                readColor: NotionContrast.readable(
                  pageBackground,
                  context.notion.colors.accent,
                  minimum: 3,
                ),
              ),
              NotionSizeReveal(
                visible: sending,
                axis: Axis.horizontal,
                alignment: AlignmentDirectional.centerStart,
                duration: NotionMotion.short,
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: NotionSpace.xxs,
                  ),
                  child: sendingLabel(clock: false),
                ),
              ),
            ],
          )
        else if (sending)
          sendingLabel(clock: true),
      ],
    );
    final messageContent = kept != null
        ? KeptMessageContent(
            kept: kept,
            event: event,
            textColor: textColor,
            fontSize: AppConfig.messageFontSize,
          )
        : MessageContent(
            display,
            textColor: textColor,
            // Links in a coloured own bubble take its text colour (underlined),
            // like Messenger; elsewhere the accent.
            linkColor: custom is int || own
                ? textColor
                : theme.colorScheme.primary,
            onInfoTab: onInfoTab,
            borderRadius: radius,
            timeline: timeline,
            selected: false,
            bigEmojis: bigEmojis,
            outgoing: own,
            roundStatus: roundStatus,
            album: album?.members,
          );
    final isReply = event.inReplyToEventId(includingFallback: false) != null;
    // The quoted original takes the muted colour of its own side, blended
    // towards the page, and stays opaque so wallpapers never show through.
    ({Color fill, Color text}) quoteColors(bool originalOwn) {
      final custom = originalOwn
          ? palette?.outgoingColor
          : palette?.incomingColor;
      final side = custom is int
          ? Color(custom)
          : (originalOwn ? bubbleColors.outgoing : bubbleColors.incoming);
      return ConversationReplyQuote.colorsFor(
        side: side,
        page: pageBackground,
        muted: bubbleColors.metadata,
      );
    }

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (strictCapabilities)
          AbsorbPointer(
            // A poll the bridge cannot deliver stays readable, not votable.
            absorbing: pollBlocked,
            child: messageContent,
          )
        else
          messageContent,
        if (pollBlocked)
          Text(
            RoomCapabilities.forFeature(
              BridgeFeature.poll,
              event.room,
              event: event,
            ).reason,
            style: NotionType.caption.copyWith(color: statusColor),
          ),
      ],
    );
    final threads = event.aggregatedEvents(timeline, RelationshipTypes.thread);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: ChatLoomThemes.maxTimelineWidth,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConversationBubble(
                compactMedia: sharedPost,
                outgoing: own,
                groupPosition: position,
                media: media || sharedPost,
                // Rounds and stickers float without a bubble (Telegram).
                chromeless: round || MessageContent.rendersSticker(display),
                flash: highlightMarker,
                backgroundColor: custom is int ? Color(custom) : null,
                quote: isReply
                    ? _ReplyPreview(
                        event: event,
                        timeline: timeline,
                        own: own,
                        colors: quoteColors,
                        captionColor: statusColor,
                        captionBackdrop: metaBackdrop,
                        onOpen: scrollToEventId,
                      )
                    : null,
                avatar: _SenderAvatar(event: event, onMention: onMention),
                heading: !first
                    ? null
                    : sourceLabel != null
                    ? ConversationMetaChip(
                        backdrop: metaBackdrop,
                        child: Text(
                          sourceLabel!,
                          style: NotionType.caption.copyWith(
                            color: statusColor,
                          ),
                        ),
                      )
                    // A reply caption already names the sender.
                    : !own &&
                          !isReply &&
                          !event.room.isDirectChatForDisplay &&
                          displayPrefs.senderNames
                    ? ConversationMetaChip(
                        backdrop: metaBackdrop,
                        child: Text(
                          sender.calcDisplayname(),
                          style: NotionType.caption.copyWith(
                            fontWeight: FontWeight.w600,
                            color: statusColor,
                          ),
                        ),
                      )
                    : null,
                footer: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: own
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    if (!round && hasStatus)
                      timeVisible
                          ? ConversationMetaChip(
                              backdrop: metaBackdrop,
                              child: status,
                            )
                          // Only "Sending…": the chip itself waits.
                          : NotionDelayedReveal(
                              child: ConversationMetaChip(
                                backdrop: metaBackdrop,
                                child: status,
                              ),
                            ),
                    if (delivery.failed)
                      MessageDeliveryFailure(
                        event: event,
                        timeline: timeline,
                        delivery: delivery,
                        backdrop: metaBackdrop,
                      ),
                    ConversationReactionFeedback(event, timeline),
                    if (enterThread != null && threads.isNotEmpty)
                      TextButton.icon(
                        onPressed: () => enterThread!(event.eventId),
                        icon: const Icon(Icons.message_outlined, size: 16),
                        label: Text(
                          '${L10n.of(context).countReplies(threads.length)} | ${personalEventPreview(threads.first, i18n: MatrixLocals(L10n.of(context)))}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
                reactions:
                    !event.redacted &&
                        event.hasAggregatedEvents(
                          timeline,
                          RelationshipTypes.reaction,
                        )
                    ? MessageReactions(
                        event,
                        timeline,
                        strict: strictCapabilities,
                        ring: pageBackground,
                      )
                    : null,
                // Swipe to reply on every message kind, double tap for the
                // network's first quick reaction, long-press for the menu.
                surfaceBuilder: (surface) => ConversationMessageGestures(
                  identity: event.transactionId ?? event.eventId,
                  enabled: !textSelectionActive,
                  swipeRightToLeft: AppSettings.swipeRightToLeftToReply.value,
                  onReply: canReply ? onSwipe : null,
                  // Only where a reaction can go out: no "unsupported"
                  // notice from a double tap on a chat without reactions
                  // or on a message still sending.
                  quickLikeEnabled:
                      AppSettings.doubleTapToReact.value &&
                      ConversationMessageActions.canReactAtAll(
                        event,
                        strict: strictCapabilities,
                      ),
                  likeLabel: 'Quick reaction',
                  likePreview: () {
                    final emoji = ConversationMessageActions.doubleTapReaction(
                      event.room,
                    );
                    return (
                      emoji: emoji,
                      adds: ConversationMessageActions.wouldAdd(
                        event,
                        timeline,
                        emoji,
                        strict: strictCapabilities,
                      ),
                    );
                  },
                  onLike: () => ConversationMessageActions.react(
                    context,
                    event,
                    timeline,
                    ConversationMessageActions.doubleTapReaction(event.room),
                    toggle: true,
                    strict: strictCapabilities,
                  ),
                  onLongPress: (press) =>
                      _openMenu(context, press, event, kept: kept),
                  // Mac: react · reply · more beside the hovered bubble.
                  hoverActions: PlatformInfos.isDesktop,
                  hoverReact: () => ConversationMessageActions.canReactAtAll(
                    event,
                    strict: strictCapabilities,
                  ),
                  outgoing: own,
                  pressAlignment: own
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: surface,
                ),
                // An edit or a deletion glides the bubble to its new size
                // (decryption and history never do).
                body: ConversationContentMorph(
                  revision: (event.redacted, edited ? display.body : null),
                  child: content,
                ),
              ),
              // The "N unread messages" divider is drawn by the list above
              // the first unread row (ConversationUnreadDivider).
            ],
          ),
        ),
      ),
    );
  }

  /// The long-press menu: quick reactions of this network (when it takes
  /// reactions here) above the lifted bubble, the host's actions below.
  void _openMenu(
    BuildContext context,
    ConversationMessagePress press,
    Event event, {
    KeptMessage? kept,
  }) {
    final canReact = ConversationMessageActions.canReactAtAll(
      event,
      strict: strictCapabilities,
    );
    final reactions = canReact
        ? ConversationMessageActions.quickReactions(event.room)
        : const <String>[];
    final own = ConversationMessageActions.ownReactionKeys(event, timeline);
    showConversationMessageMenu(
      context: context,
      press: press,
      outgoing: event.senderId == event.room.client.userID,
      reactions: reactions,
      ownReactions: own,
      onReact: (emoji) => ConversationMessageActions.react(
        context,
        event,
        timeline,
        emoji,
        toggle: true,
        strict: strictCapabilities,
      ),
      // "+" grows into the picker of exactly what this chat takes; a chat
      // whose whole set is already on the bar gets no "+".
      moreReactions:
          canReact && ConversationMessageActions.hasMoreReactions(event.room)
          ? EmojiReactionChoices(
              allowed: ConversationMessageActions.reactionChoices(event.room),
              quick: reactions,
              own: own,
            )
          : null,
      actions: press.reactionsOnly
          ? const []
          : menuActions?.call(event) ?? const [],
      caption: kept == null
          ? event.originServerTs.localizedDetailedTime(context)
          : '${event.originServerTs.localizedDetailedTime(context)} · '
                '${L10n.of(context).deletedAtTime(kept.deletedAt.localizedDetailedTime(context))}',
    );
  }
}

/// Sender avatar. Loaded member state wins, so later profile changes show on
/// the next row build; a one-shot member lookup is only the fallback while
/// that state is missing. Rebuilding the row never starts a new request.
class _SenderAvatar extends StatefulWidget {
  final Event event;
  final void Function() onMention;
  const _SenderAvatar({required this.event, required this.onMention});

  @override
  State<_SenderAvatar> createState() => _SenderAvatarState();
}

class _SenderAvatarState extends State<_SenderAvatar> {
  User? _fetched;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(_SenderAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event.senderId != widget.event.senderId ||
        oldWidget.event.room.id != widget.event.room.id ||
        !identical(oldWidget.event.room.client, widget.event.room.client)) {
      _fetched = null;
      _fetch();
    }
  }

  User? get _member {
    final event = widget.event;
    return event.room
        .getState(EventTypes.RoomMember, event.senderId)
        ?.asUser(event.room);
  }

  void _fetch() {
    final generation = ++_generation;
    // Member state already in memory needs no lookup.
    if (_member != null) return;
    // Once per mount/sender; requestUser answers from memory when it can.
    widget.event.fetchSenderUser().then((user) {
      if (!mounted || generation != _generation || user == null) return;
      setState(() => _fetched = user);
    }, onError: (Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final user = _member ?? _fetched ?? User(event.senderId, room: event.room);
    return Avatar(
      client: event.room.client,
      mxContent: user.avatarUrl,
      name: user.calcDisplayname(),
      size: 28,
      onTap: () => showMemberActionsPopupMenu(
        context: context,
        user: user,
        onMention: widget.onMention,
      ),
    );
  }
}

/// Reply preview that keeps its original across row rebuilds and re-resolves
/// it when the timeline has a fresher (decrypted, loaded, replaced) copy.
class _ReplyPreview extends StatefulWidget {
  final Event event;
  final Timeline timeline;
  final bool own;

  /// Quote fill and text for an original sent by this account (or not).
  final ({Color fill, Color text}) Function(bool originalOwn) colors;
  final Color captionColor;
  final Color? captionBackdrop;
  final void Function(String eventId) onOpen;
  const _ReplyPreview({
    required this.event,
    required this.timeline,
    required this.own,
    required this.colors,
    required this.captionColor,
    required this.captionBackdrop,
    required this.onOpen,
  });

  @override
  State<_ReplyPreview> createState() => _ReplyPreviewState();
}

class _ReplyPreviewState extends State<_ReplyPreview> {
  /// First retry delay for an original that was missing or undecryptable;
  /// doubles per attempt up to [_maxRetry]. Retries only run when the row is
  /// rebuilt (timeline updates), never on a timer.
  static const _firstRetry = Duration(seconds: 5);
  static const _maxRetry = Duration(minutes: 2);

  Event? _original;
  bool _loading = false;
  int _generation = 0;
  int _attempts = 0;
  bool _retryAllowed = true;
  Timer? _retryTimer;

  String? get _replyId =>
      widget.event.inReplyToEventId(includingFallback: false);

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(_ReplyPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event.eventId != widget.event.eventId ||
        oldWidget.event.inReplyToEventId(includingFallback: false) !=
            _replyId ||
        !identical(oldWidget.timeline, widget.timeline)) {
      _generation++;
      _original = null;
      _loading = false;
      _attempts = 0;
      _retryTimer?.cancel();
      _retryAllowed = true;
    }
    _resolve();
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  /// A result that is worth looking up again later.
  static bool _incomplete(Event? event) =>
      event == null || event.type == EventTypes.Encrypted;

  /// Prefers the live timeline copy (decrypted, redacted or replaced in place
  /// by the SDK) synchronously; fetches only when it is not loaded, and
  /// refetches with backoff while the last result is missing or still
  /// encrypted. Edits render through [ReplyContent]'s display event.
  void _resolve() {
    final id = _replyId;
    if (id == null) {
      _original = null;
      return;
    }
    for (final event in widget.timeline.events) {
      if (event.eventId == id) {
        if (_loading) _generation++;
        _loading = false;
        _original = event;
        return;
      }
    }
    if (_loading) return;
    if (_attempts > 0 && !_incomplete(_original)) return;
    if (!_retryAllowed) return;
    _fetch(id);
  }

  void _fetch(String id) {
    final generation = ++_generation;
    final retry = _attempts > 0;
    final delay = _firstRetry * (1 << _attempts.clamp(0, 5));
    _attempts++;
    // The timer only re-arms the next rebuild; it never fetches or rebuilds.
    _retryAllowed = false;
    _retryTimer?.cancel();
    _retryTimer = Timer(
      delay > _maxRetry ? _maxRetry : delay,
      () => _retryAllowed = true,
    );
    _loading = true;
    _lookup(id, retry: retry).then(
      (event) => _settle(generation, event),
      onError: (Object _) => _settle(generation, null),
    );
  }

  Future<Event?> _lookup(String id, {required bool retry}) async {
    final room = widget.event.room;
    // A retry bypasses the timeline's lookup cache, which keeps the first
    // (possibly undecryptable) copy.
    final event = retry
        ? await room.getEventById(id)
        : await widget.timeline.getEventById(id);
    final encryption = room.client.encryption;
    if (event == null ||
        event.type != EventTypes.Encrypted ||
        encryption == null ||
        !room.client.encryptionEnabled) {
      return event;
    }
    try {
      return await encryption.decryptRoomEvent(event);
    } catch (_) {
      return event;
    }
  }

  void _settle(int generation, Event? event) {
    if (!mounted || generation != _generation) return;
    setState(() {
      _loading = false;
      // A failed retry keeps the last copy rather than blanking the preview.
      if (event != null || _original == null) _original = event;
    });
  }

  /// "Anna replied to you", "Replied to Anna", ... in the reader's terms.
  String _caption(L10n l10n, Event? original) {
    final event = widget.event;
    final me = event.room.client.userID;
    final originalName = original?.senderFromMemoryOrFallback.calcDisplayname();
    if (widget.own) {
      if (original == null) return l10n.replyCaptionYouRepliedUnknown;
      if (original.senderId == me) return l10n.replyCaptionYouRepliedSelf;
      return l10n.replyCaptionYouReplied(originalName!);
    }
    final name = event.senderFromMemoryOrFallback.calcDisplayname();
    if (original == null) return l10n.replyCaptionRepliedUnknown(name);
    if (original.senderId == me) return l10n.replyCaptionRepliedToYou(name);
    if (original.senderId == event.senderId) {
      return l10n.replyCaptionRepliedSelf(name);
    }
    return l10n.replyCaptionRepliedOther(name, originalName!);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final original = _original;
    final colors = widget.colors(
      original != null && original.senderId == widget.event.room.client.userID,
    );
    final caption = ConversationReplyCaption(
      label: _caption(l10n, original),
      color: widget.captionColor,
      backdrop: widget.captionBackdrop,
    );
    if (original == null) {
      return ConversationReplyQuote(
        text: _loading ? l10n.replyLoading : l10n.replyOriginalUnavailable,
        fill: colors.fill,
        textColor: colors.text,
        outgoing: widget.own,
        caption: caption,
      );
    }
    return ReplyContent(
      original,
      timeline: widget.timeline,
      fill: colors.fill,
      textColor: colors.text,
      outgoing: widget.own,
      caption: caption,
      onTap: () => widget.onOpen(original.eventId),
    );
  }
}

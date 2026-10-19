// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

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
import 'package:fluffychat/personal/encryption/undecryptable_messages.dart';
import 'package:fluffychat/personal/inbox_projection.dart';
import 'package:fluffychat/personal/message_preview.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/utils/adaptive_bottom_sheet.dart';
import 'package:fluffychat/utils/date_time_extension.dart';
import 'package:fluffychat/utils/file_description.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/member_actions_popup_menu_button.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart' show ChatTheme;
import '../sticker_picker_dialog.dart';
import 'message_content.dart';
import 'message_reactions.dart';
import 'reply_content.dart';
import 'round_video_view.dart';
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
  final bool wallpaperMode;
  final ScrollController scrollController;
  final List<Color> colors;
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
    this.wallpaperMode = false,
    required this.onMention,
    required this.scrollController,
    required this.colors,
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
        : bubbleColors.text;
    final radius = ConversationBubble.radiusFor(
      outgoing: own,
      position: position,
    ).resolve(Directionality.of(context));
    // Time, captions and names sit on the chat background, which a private
    // palette may make light in the dark theme (or the reverse).
    final pageBackground = palette?.backgroundColor is int
        ? Color(palette!.backgroundColor!)
        : context.notion.colors.background;
    // Over a wallpaper, metadata gets a chip of the page colour.
    final metaBackdrop = wallpaperMode ? pageBackground : null;
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
        // Its reply fallback would quote the SDK's decryption error.
        !isUndecryptable(event) &&
        event.status.isSent &&
        event.room.membership == Membership.join &&
        event.room.canSendDefaultMessages &&
        (strictCapabilities
            ? replyCapability.allowed
            : replyCapability.status != CapabilityStatus.unavailable);
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
    final edited = event.hasAggregatedEvents(timeline, RelationshipTypes.edit);
    // Over the circle: always the time, colours inherited from the pill.
    final roundStatus = round
        ? Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              if (edited) Text(L10n.of(context).edited),
              Text(
                selected
                    ? event.originServerTs.localizedDetailedTime(context)
                    : event.originServerTs.localizedTimeOfDay(context),
              ),
              if (display.status.isError)
                Icon(
                  Icons.error_outline,
                  color: theme.colorScheme.error,
                  semanticLabel: L10n.of(context).couldNotBeSent,
                ),
              if (display.status == EventStatus.sending)
                const SizedBox.square(
                  dimension: 10,
                  child: CircularProgressIndicator(
                    strokeWidth: 1,
                    color: roundVideoOnScrim,
                  ),
                ),
            ],
          )
        : null;
    final hasStatus =
        last ||
        selected ||
        edited ||
        display.status.isError ||
        display.status == EventStatus.sending;
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
        if (edited)
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
    final messageContent = MessageContent(
      display,
      textColor: textColor,
      linkColor: custom is int ? textColor : theme.colorScheme.primary,
      onInfoTab: onInfoTab,
      borderRadius: radius,
      timeline: timeline,
      selected: selected,
      bigEmojis: bigEmojis,
      outgoing: own,
      roundStatus: roundStatus,
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
            maxWidth: FluffyThemes.maxTimelineWidth,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConversationBubble(
                outgoing: own,
                groupPosition: position,
                media: media,
                chromeless: round,
                selected: selected || highlightMarker,
                backgroundColor: custom is int ? Color(custom) : null,
                quote: isReply
                    ? _ReplyPreview(
                        event: event,
                        timeline: timeline,
                        own: own,
                        colors: quoteColors,
                        captionColor: statusColor,
                        captionBackdrop: metaBackdrop,
                        onOpen: longPressSelect
                            ? (_) => onSelect(event)
                            : scrollToEventId,
                        onLongPress: longPressSelect
                            ? null
                            : () {
                                NotionHaptics.longPress();
                                onSelect(event);
                              },
                      )
                    : null,
                // Entering selection mode morphs the avatar into a circle,
                // and the circle into a check (rows built later do not).
                avatar: ConversationSlotMorph(
                  child: longPressSelect && !event.redacted
                      ? IconButton(
                          key: ValueKey(selected),
                          tooltip: L10n.of(context).select,
                          onPressed: () => onSelect(event),
                          icon: Icon(
                            selected
                                ? Icons.check_circle
                                : Icons.circle_outlined,
                          ),
                        )
                      : _SenderAvatar(event: event, onMention: onMention),
                ),
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
                    : !own && !isReply && !event.room.isDirectChatForDisplay
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
                      ConversationMetaChip(
                        backdrop: metaBackdrop,
                        child: status,
                      ),
                    ConversationReactionFeedback(event, timeline),
                    if (reactionPicker && _canReact) _reactionPicker(context),
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
                    event.hasAggregatedEvents(
                      timeline,
                      RelationshipTypes.reaction,
                    )
                    ? MessageReactions(
                        event,
                        timeline,
                        strict: strictCapabilities,
                      )
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
                    strict: strictCapabilities,
                  ),
                  // A held bubble sinks a little until the long-press
                  // selects it, then springs back on release.
                  child: ConversationPressScale(
                    enabled: !longPressSelect && !textSelectionActive,
                    alignment: own
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: surface,
                  ),
                ),
                body: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: longPressSelect ? () => onSelect(event) : null,
                  onLongPress: longPressSelect
                      ? null
                      : () {
                          NotionHaptics.longPress();
                          onSelect(event);
                        },
                  child: AbsorbPointer(
                    absorbing: longPressSelect,
                    child: content,
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

  /// Strict sources offer the picker only for a verified reaction feature.
  bool get _canReact =>
      !strictCapabilities ||
      RoomCapabilities.forFeature(
        BridgeFeature.reaction,
        event.room,
        event: event,
      ).allowed;

  Widget _reactionPicker(BuildContext context) => Wrap(
    spacing: 2,
    children: [
      for (final emoji in AppConfig.defaultReactions)
        IconButton(
          tooltip: 'React $emoji',
          onPressed: () {
            onSelect(event);
            ConversationMessageActions.react(
              context,
              event,
              timeline,
              emoji,
              strict: strictCapabilities,
            );
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
    await ConversationMessageActions.react(
      context,
      event,
      timeline,
      emoji,
      strict: strictCapabilities,
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
  final VoidCallback? onLongPress;
  const _ReplyPreview({
    required this.event,
    required this.timeline,
    required this.own,
    required this.colors,
    required this.captionColor,
    required this.captionBackdrop,
    required this.onOpen,
    required this.onLongPress,
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
    final originalName = original?.senderFromMemoryOrFallback
        .calcDisplayname();
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
        onLongPress: widget.onLongPress,
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
      onLongPress: widget.onLongPress,
    );
  }
}

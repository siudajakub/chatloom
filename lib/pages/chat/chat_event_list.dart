// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/conversation_bubble.dart';
import 'package:fluffychat/pages/chat/conversation_grouping.dart';
import 'package:fluffychat/pages/chat/conversation_motion.dart';
import 'package:fluffychat/pages/chat/conversation_source.dart';
import 'package:fluffychat/pages/chat/encryption_info.dart';
import 'package:fluffychat/pages/chat/events/message.dart';
import 'package:fluffychat/pages/chat/seen_by_row.dart';
import 'package:fluffychat/pages/chat/typing_indicators.dart';
import 'package:fluffychat/personal/media/media_prefetcher.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/utils/account_config.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import '../../utils/date_time_extension.dart';

/// The reversed message list of a conversation: one room ([ChatController])
/// or the interleaved source rooms of a merged person chat.
class ChatEventList extends StatefulWidget {
  final ConversationTimelineSource controller;

  const ChatEventList({super.key, required this.controller});

  @override
  State<ChatEventList> createState() => _ChatEventListState();
}

class _ChatEventListState extends State<ChatEventList> {
  ConversationTimelineSource get controller => widget.controller;
  bool _textSelectionActive = false;

  /// Opening a chat builds only what is visible plus a small margin; once the
  /// route has settled the cache widens so rows above the viewport are built
  /// while idle instead of during the user's scroll frames.
  bool _wideCache = false;
  Timer? _wideCacheTimer;

  /// Voice/round prefetch around the rows the list actually builds.
  RoomPrefetchScope? _prefetch;
  Client? _prefetchClient;
  Set<String> _prefetchRooms = const {};
  List<Event> _prefetchEvents = const [];

  /// Private palette of the last build. Private-store notifications rebuild
  /// the rows only when this changes (bubble colours), never per sync.
  PersonalClient? _personal;
  Object? _paletteSignature;

  void _listenPersonal() {
    final personal = PersonalClient.of(controller.room.client);
    if (identical(personal, _personal)) return;
    _personal?.removeListener(_onPersonalChanged);
    _personal = personal..addListener(_onPersonalChanged);
  }

  void _onPersonalChanged() {
    if (!mounted) return;
    final signature = Message.paletteSignature(controller.conversationPalette);
    if (signature != _paletteSignature) setState(() {});
  }

  void _scheduleWideCache() {
    if (_wideCache || _wideCacheTimer != null) return;
    _wideCacheTimer = Timer(const Duration(milliseconds: 600), () {
      _wideCacheTimer = null;
      if (mounted) setState(() => _wideCache = true);
    });
  }

  void _attachPrefetch(List<Event> events) {
    _prefetchEvents = events;
    final client = controller.room.client;
    final rooms = controller.conversationRoomIds;
    if (_prefetch != null &&
        identical(_prefetchClient, client) &&
        const SetEquality<String>().equals(rooms, _prefetchRooms)) {
      return;
    }
    _prefetch?.dispose();
    _prefetchClient = client;
    _prefetchRooms = rooms;
    _prefetch = MediaPrefetcher.of(
      client,
    ).attach(roomIds: rooms, events: () => _prefetchEvents);
  }

  @override
  void dispose() {
    _wideCacheTimer?.cancel();
    _prefetch?.dispose();
    _personal?.removeListener(_onPersonalChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final events = controller.conversationEvents;

    if (events == null) {
      return ConversationTimelineSkeleton(
        bottomInset:
            controller.inputBarHeight ??
            (72 + (FluffyThemes.isColumnMode(context) ? 16 : 0)),
      );
    }
    final theme = Theme.of(context);

    final colors = [theme.secondaryBubbleColor, theme.bubbleColor];

    final horizontalPadding = FluffyThemes.isColumnMode(context) ? 8.0 : 0.0;

    // Map row key --> index so ListView's findChildIndexCallback is O(1). The
    // key must match the AutoScrollTag key below (transaction id first), or
    // own messages lose their element (and media state) on every insert.
    final thisEventsKeyMap = <String, int>{};
    for (var i = 0; i < events.length; i++) {
      final event = events[i];
      thisEventsKeyMap[event.transactionId ?? event.eventId] = i;
    }
    _scheduleWideCache();
    _attachPrefetch(events);
    // One palette lookup per list build instead of one per row.
    _listenPersonal();
    final roomPalette = controller.conversationPalette;
    _paletteSignature = Message.paletteSignature(roomPalette);

    final hasWallpaper =
        controller.room.client.applicationAccountConfig.wallpaperUrl != null;

    return SelectionArea(
      onSelectionChanged: (content) {
        final active = content != null && content.plainText.isNotEmpty;
        if (active != _textSelectionActive) {
          setState(() => _textSelectionActive = active);
        }
      },
      child: _TimelineTextScale(
        // The first screenful of a freshly opened chat staggers in once.
        child: ConversationEntranceScope(
          child: ListView.custom(
            padding: EdgeInsets.only(
              // Clears the glass header drawn over the timeline.
              top: 8 + MediaQuery.paddingOf(context).top,
              bottom:
                  8 +
                  (controller.inputBarHeight ??
                      (72 + (FluffyThemes.isColumnMode(context) ? 16 : 0))),
              left: horizontalPadding,
              right: horizontalPadding,
            ),
            reverse: true,
            scrollCacheExtent: _wideCache
                ? const ScrollCacheExtent.viewport(1.0)
                : const ScrollCacheExtent.pixels(250),
            controller: controller.scrollController,
            keyboardDismissBehavior: PlatformInfos.isIOS
                ? ScrollViewKeyboardDismissBehavior.onDrag
                : ScrollViewKeyboardDismissBehavior.manual,
            childrenDelegate: SliverChildBuilderDelegate(
              (BuildContext context, int i) {
                // Footer to display typing indicator and read receipts:
                if (i == 0) {
                  if (controller.canLoadFuture) {
                    return Center(
                      child: TextButton.icon(
                        onPressed: controller.isLoadingFuture
                            ? null
                            : controller.requestFuture,
                        icon: NotionMorphSwitcher(
                          rotate: false,
                          child: controller.isLoadingFuture
                              ? const NotionDelayedSpinner(
                                  key: ValueKey('loading'),
                                  size: NotionSize.iconSm,
                                )
                              : const Icon(
                                  Icons.arrow_downward_outlined,
                                  key: ValueKey('idle'),
                                ),
                        ),
                        label: Text(
                          controller.historyError ?? L10n.of(context).loadMore,
                        ),
                      ),
                    );
                  }
                  return Column(
                    mainAxisSize: .min,
                    children: [
                      if (events.isNotEmpty) SeenByRow(event: events.first),
                      TypingIndicators(controller),
                      EncryptionInfo(room: controller.room),
                    ],
                  );
                }

                // Request history button or progress indicator:
                if (i == events.length + 1) {
                  if (!controller.canLoadHistory) {
                    return const SizedBox.shrink();
                  }
                  return Builder(
                    builder: (context) {
                      if (controller.autoLoadHistory) {
                        WidgetsBinding.instance.addPostFrameCallback(
                          controller.requestHistory,
                        );
                      }
                      return Center(
                        child: TextButton.icon(
                          onPressed:
                              controller.historyLoading ||
                                  controller.isLoadingHistory
                              ? null
                              : controller.requestHistory,
                          icon: NotionMorphSwitcher(
                            rotate: false,
                            child: controller.isLoadingHistory
                                ? const NotionDelayedSpinner(
                                    key: ValueKey('loading'),
                                    size: NotionSize.iconSm,
                                  )
                                : const Icon(
                                    Icons.arrow_upward_outlined,
                                    key: ValueKey('idle'),
                                  ),
                          ),
                          label: Text(
                            controller.historyError ??
                                L10n.of(context).loadMore,
                          ),
                        ),
                      );
                    },
                  );
                }
                i--;

                // The message at this index:
                _prefetch?.noteBuilt(i);
                final event = events[i];
                final animateIn =
                    (event.transactionId ?? event.eventId) ==
                    controller.animateInEventId;

                final nextEvent = i + 1 < events.length ? events[i + 1] : null;
                final previousEvent = i > 0 ? events[i - 1] : null;

                // Collapsed state event
                final canExpand =
                    event.isCollapsedState &&
                    nextEvent?.isCollapsedState == true &&
                    previousEvent?.isCollapsedState != true;
                final isCollapsed =
                    event.isCollapsedState &&
                    previousEvent?.isCollapsedState == true &&
                    !controller.expandedEventIds.contains(event.eventId);

                final displayDate =
                    event.type == EventTypes.RoomCreate ||
                    nextEvent == null ||
                    !event.originServerTs.sameDay(nextEvent.originServerTs);

                return AutoScrollTag(
                  key: ValueKey(event.transactionId ?? event.eventId),
                  index: i,
                  controller: controller.scrollController,
                  child: ConversationMessageEntrance(
                    identity: event.transactionId ?? event.eventId,
                    animate: animateIn,
                    outgoing: event.senderId == event.room.client.userID,
                    child: Column(
                      mainAxisSize: .min,
                      children: [
                        if (!isCollapsed && displayDate)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                NotionTokens.inset,
                                8,
                                NotionTokens.inset,
                                8,
                              ),
                              child: Text(
                                event.originServerTs.localizedDate(context),
                                style: TextStyle(
                                  fontSize: 13,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        Message(
                          event,
                          bigEmojis: controller.bigEmojis,
                          onSwipe: () => controller.replyAction(replyTo: event),
                          onInfoTab: controller.showEventInfo,
                          onMention: () => controller.mentionSender(event),
                          highlightMarker:
                              controller.scrollToEventIdMarker == event.eventId,
                          onSelect: controller.onSelectMessage,
                          scrollToEventId: controller.scrollToEventId,
                          longPressSelect: controller.selectedEvents.isNotEmpty,
                          readMarkerEventId: controller.readMarkerEventId,
                          textSelectionActive: _textSelectionActive,
                          selected: controller.selectedEvents.any(
                            (e) => e.eventId == event.eventId,
                          ),
                          singleSelected:
                              controller.selectedEvents.singleOrNull?.eventId ==
                              event.eventId,
                          onEdit: controller.editSelectedEventAction,
                          timeline: controller.timelineFor(event)!,
                          sourceLabel: controller.sourceLabelFor(event),
                          seriesBoundary: controller.seriesBoundary,
                          strictCapabilities: controller.strictCapabilities,
                          displayReadMarker:
                              i > 0 &&
                              controller.readMarkerEventId == event.eventId,
                          nextEvent: nextEvent,
                          previousEvent: previousEvent,
                          wallpaperMode: hasWallpaper,
                          scrollController: controller.scrollController,
                          colors: colors,
                          isCollapsed: isCollapsed,
                          roomPalette: roomPalette,
                          enterThread: controller.threadOpener,
                          onExpand: canExpand
                              ? () => controller.expandEventsFrom(
                                  event,
                                  !controller.expandedEventIds.contains(
                                    event.eventId,
                                  ),
                                )
                              : null,
                        ),
                      ],
                    ),
                  ),
                );
              },
              childCount: events.length + 2,
              findChildIndexCallback: (key) =>
                  controller.findChildIndexCallback(key, thisEventsKeyMap),
            ),
          ),
        ),
      ),
    );
  }
}

/// Placeholder of a conversation whose timeline is still loading: a few
/// shimmering bubbles on alternating sides, anchored above the composer
/// like the real (reversed) list. It only appears when loading takes longer
/// than [NotionMotion.loaderGrace], so a fast open never flashes it.
class ConversationTimelineSkeleton extends StatelessWidget {
  final double bottomInset;

  const ConversationTimelineSkeleton({super.key, this.bottomInset = 72});

  static const _bubbles = <(bool, String)>[
    (false, 'Placeholder message text'),
    (false, 'Short reply'),
    (true, 'A longer outgoing placeholder message'),
    (false, 'Another incoming placeholder line here'),
    (true, 'Okay'),
    (true, 'One more outgoing message'),
  ];

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading messages',
    child: ExcludeSemantics(
      child: NotionDelayedReveal(
        child: NotionSkeleton(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: SingleChildScrollView(
              reverse: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.only(
                top: NotionSpace.xs + MediaQuery.paddingOf(context).top,
                bottom: NotionSpace.xs + bottomInset,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: FluffyThemes.maxTimelineWidth,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: NotionSpace.md,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final (outgoing, text) in _bubbles)
                          ConversationBubble(
                            outgoing: outgoing,
                            groupPosition: ConversationGroupPosition.single,
                            body: Text(text),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Applies the user's font-size factor below the timeline. Kept out of
/// [_ChatEventListState.build] so the list does not depend on the whole
/// [MediaQuery]: keyboard insets change on every frame of the keyboard
/// animation and would otherwise rebuild every visible message per frame.
class _TimelineTextScale extends StatelessWidget {
  final Widget child;

  const _TimelineTextScale({required this.child});

  @override
  Widget build(BuildContext context) {
    final data = MediaQuery.of(context);
    return MediaQuery(
      data: data.copyWith(
        textScaler: TextScaler.linear(
          data.textScaler.scale(AppSettings.fontSizeFactor.value),
        ),
      ),
      child: child,
    );
  }
}

/// The "jump to the newest message" button over a conversation. It stays
/// mounted and springs in and out (instead of the Scaffold's default FAB
/// swap); [count] new messages that arrived while scrolled up roll in a
/// badge.
class ConversationJumpButton extends StatelessWidget {
  final bool visible;
  final VoidCallback onPressed;
  final int count;
  final String tooltip;

  const ConversationJumpButton({
    super.key,
    required this.visible,
    required this.onPressed,
    this.count = 0,
    this.tooltip = 'Latest messages',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExcludeSemantics(
      excluding: !visible,
      child: NotionPop(
        visible: visible,
        playOnMount: false,
        bounce: false,
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: theme.appBarTheme.toolbarHeight ?? kToolbarHeight,
          ),
          child: Badge(
            isLabelVisible: count > 0,
            backgroundColor: theme.colorScheme.onSurface,
            textColor: theme.colorScheme.surface,
            label: NotionAnimatedCount(
              count: count,
              format: (n) => n > 99 ? '99+' : '$n',
            ),
            child: NotionPressable(
              scale: NotionMotion.pressIcon,
              child: FloatingActionButton(
                onPressed: onPressed,
                tooltip: tooltip,
                heroTag: null,
                mini: true,
                backgroundColor: theme.colorScheme.surface,
                foregroundColor: theme.colorScheme.onSurface,
                child: const Icon(Icons.arrow_downward_outlined),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The composer card of a conversation: its fill tweens (selection mode
/// tint) instead of snapping.
class ConversationTint extends StatelessWidget {
  final Color color;
  final BorderRadiusGeometry borderRadius;
  final Widget child;

  const ConversationTint({
    super.key,
    required this.color,
    required this.borderRadius,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<Color?>(
    tween: ColorTween(end: color),
    duration: NotionMotion.of(context, NotionMotion.quick),
    curve: NotionMotion.standard,
    child: child,
    builder: (context, color, child) => Material(
      clipBehavior: Clip.hardEdge,
      color: color,
      borderRadius: borderRadius,
      child: child,
    ),
  );
}

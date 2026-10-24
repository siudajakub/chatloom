// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatloom/config/themes.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/conversation_grouping.dart';
import 'package:chatloom/pages/chat/conversation_motion.dart';
import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/pages/chat/encryption_info.dart';
import 'package:chatloom/pages/chat/events/message.dart';
import 'package:chatloom/pages/chat/media_album.dart';
import 'package:chatloom/pages/chat/seen_by_row.dart';
import 'package:chatloom/pages/chat/typing_indicators.dart';
import 'package:chatloom/personal/media/media_prefetcher.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/account_config.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/rendering.dart' show ScrollCacheExtent, ScrollDirection;
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import '../../utils/date_time_extension.dart';

/// The reversed message list of a conversation: one room ([ChatController])
/// or the interleaved source rooms of a merged person chat.
///
/// The rows of a freshly opened chat render with the page (no per-row
/// entrance; Telegram shows the messages during the slide). A list that
/// replaces the loading placeholder, or is released by [hold], fades in once
/// as a whole. While the user scrolls, a floating date pill under the header
/// names the day of the topmost message.
class ChatEventList extends StatefulWidget {
  final ConversationTimelineSource controller;

  /// While true the list is laid out but invisible (the chat positions it at
  /// the first unread message first); when it turns false the list fades in.
  final ValueListenable<bool>? hold;

  const ChatEventList({super.key, required this.controller, this.hold});

  @override
  State<ChatEventList> createState() => _ChatEventListState();
}

class _ChatEventListState extends State<ChatEventList>
    with TickerProviderStateMixin {
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

  /// Whole-list appearance: one opacity for every row, never per row. It
  /// stays at rest (no controller) when the rows were there on the first
  /// frame.
  final ProxyAnimation _opacity = ProxyAnimation(kAlwaysCompleteAnimation);
  AnimationController? _appear;
  CurvedAnimation? _appearCurve;
  bool _placeholderShown = false;
  ValueListenable<bool>? _hold;

  /// Rows of the last build and the indexes that carry a day separator, for
  /// the floating date pill.
  List<Event> _rows = const [];
  Set<int> _dayStarts = const {};

  final ValueNotifier<String?> _pillLabel = ValueNotifier(null);

  /// The timeline the user last scrolled by hand. Newer messages load by
  /// themselves only after that (reading down), never while the chat
  /// positions itself after a jump or on opening.
  Timeline? _userScrolled;

  /// The day of the pill's label, for its tap (jump to date).
  DateTime? _pillDay;

  /// The pill takes taps from its fade-in until it has faded out; flipped
  /// at those two moments only, never per frame.
  final ValueNotifier<bool> _pillTappable = ValueNotifier(false);
  final ProxyAnimation _pillOpacity = ProxyAnimation(kAlwaysDismissedAnimation);
  AnimationController? _pillShow, _pillHide;
  CurvedAnimation? _pillFadeOut;
  bool? _pillReduced;
  bool _pillScanScheduled = false;

  @override
  void initState() {
    super.initState();
    _listenHold();
  }

  @override
  void didUpdateWidget(ChatEventList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.hold, widget.hold)) _listenHold();
  }

  void _listenHold() {
    _hold?.removeListener(_holdChanged);
    _hold = widget.hold?..addListener(_holdChanged);
    if (_hold?.value ?? false) _hide();
  }

  bool get _held => _hold?.value ?? false;

  AnimationController _appearController(double from) {
    var controller = _appear;
    if (controller == null) {
      controller = _appear = AnimationController(
        vsync: this,
        duration: NotionMotion.short,
      );
      _opacity.parent = _appearCurve = CurvedAnimation(
        parent: controller,
        curve: NotionMotion.standard,
      );
    }
    controller.value = from;
    return controller;
  }

  void _hide() => _appearController(0);

  /// Fades the whole list in from [from] (instant under reduced motion).
  void _reveal({double? from}) {
    final controller = from == null ? _appear : _appearController(from);
    if (controller == null) return;
    if (NotionMotion.reduced(context)) {
      controller.value = 1;
    } else {
      controller.forward();
    }
  }

  void _holdChanged() {
    if (!mounted) return;
    if (_held) {
      _hide();
    } else {
      _reveal();
    }
  }

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

  /// A message whose reactions or thread replies must stay visible under it
  /// is never hidden inside another message's album.
  bool _hasFooterContent(Event event) {
    final timeline = controller.timelineFor(event);
    if (timeline == null) return true;
    return event.hasAggregatedEvents(timeline, RelationshipTypes.reaction) ||
        event.hasAggregatedEvents(timeline, RelationshipTypes.thread) ||
        event.hasAggregatedEvents(timeline, RelationshipTypes.edit);
  }

  // ---------------------------------------------------------------------
  // Floating date pill (Telegram's `floatingDateView`).

  /// Shows the pill while the user scrolls; it stays for
  /// [ConversationMotion.dateHold] once the list is idle, then fades. One
  /// visibility pass per frame, after layout; nothing is laid out for it.
  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is UserScrollNotification) {
      if (_rows.isNotEmpty && notification.direction != ScrollDirection.idle) {
        _userScrolled = controller.timelineFor(_rows.first);
      }
      if (notification.direction == ScrollDirection.idle) {
        _hidePill();
      } else {
        _showPill();
      }
    } else if (notification is ScrollEndNotification) {
      _hidePill();
    }
    if (notification is ScrollUpdateNotification &&
        (_pillShow?.value ?? 0) > 0) {
      _schedulePillScan();
    }
    return false;
  }

  void _showPill() {
    final reduced = NotionMotion.reduced(context);
    final show = _pillShow ??= AnimationController(
      vsync: this,
      duration: NotionMotion.quick,
    );
    var hide = _pillHide;
    if (hide == null) {
      hide = _pillHide = AnimationController(vsync: this);
      hide.addStatusListener((status) {
        if (status != AnimationStatus.completed) return;
        // Faded out: the next scroll fades the pill in again.
        _pillShow?.value = 0;
        _pillHide?.value = 0;
        _pillTappable.value = false;
      });
    }
    hide
      ..stop()
      ..value = 0;
    if (_pillReduced != reduced) {
      // Built once per motion mode, not per scroll.
      _pillReduced = reduced;
      hide.duration = reduced
          ? ConversationMotion.dateHold
          : ConversationMotion.dateHold + NotionMotion.quick;
      final holdShare =
          ConversationMotion.dateHold.inMicroseconds /
          hide.duration!.inMicroseconds;
      _pillFadeOut?.dispose();
      final fadeOut = _pillFadeOut = CurvedAnimation(
        parent: hide,
        curve: reduced
            ? const Threshold(1)
            : Interval(holdShare, 1, curve: NotionMotion.standard),
      );
      _pillOpacity.parent = AnimationMin<double>(
        show,
        ReverseAnimation(fadeOut),
      );
    }
    if (reduced) {
      show.value = 1;
    } else {
      show.forward();
    }
    _pillTappable.value = true;
    _schedulePillScan();
  }

  void _hidePill() {
    final hide = _pillHide;
    if (hide == null || (_pillShow?.value ?? 0) == 0 || hide.isAnimating) {
      return;
    }
    hide.forward(from: 0);
  }

  void _schedulePillScan() {
    if (_pillScanScheduled) return;
    _pillScanScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pillScanScheduled = false;
      if (mounted) _scanPill();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// The day of the topmost visible message, or null while that day's own
  /// separator is right under the header (the pill would cover it).
  void _scanPill() {
    final scroll = controller.scrollController;
    if (!scroll.hasClients) return;
    final viewport = scroll.position.context.storageContext.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize || !viewport.attached) {
      return;
    }
    final top =
        viewport.localToGlobal(Offset.zero).dy +
        MediaQuery.paddingOf(context).top;
    final bottom =
        viewport.localToGlobal(Offset.zero).dy + viewport.size.height;
    int? topmost;
    var topmostY = double.infinity;
    var separatorNearTop = false;
    for (final entry in scroll.tagMap.entries) {
      final index = entry.key;
      if (index < 0 || index >= _rows.length) continue;
      final box = entry.value.context.findRenderObject();
      if (box is! RenderBox || !box.hasSize || !box.attached) continue;
      final rowTop = box.localToGlobal(Offset.zero).dy;
      final rowBottom = rowTop + box.size.height;
      if (rowBottom <= top || rowTop >= bottom) continue;
      if (_dayStarts.contains(index) &&
          rowTop > top - NotionSpace.xxl &&
          rowTop < top + NotionSpace.xxl) {
        separatorNearTop = true;
      }
      if (rowTop < topmostY) {
        topmostY = rowTop;
        topmost = index;
      }
    }
    _pillDay = topmost == null ? null : _rows[topmost].originServerTs;
    _pillLabel.value = topmost == null || separatorNearTop
        ? null
        : _rows[topmost].originServerTs.localizedDate(context);
  }

  @override
  void dispose() {
    _wideCacheTimer?.cancel();
    _prefetch?.dispose();
    _personal?.removeListener(_onPersonalChanged);
    _hold?.removeListener(_holdChanged);
    _appearCurve?.dispose();
    _appear?.dispose();
    _pillFadeOut?.dispose();
    _pillShow?.dispose();
    _pillHide?.dispose();
    _pillLabel.dispose();
    _pillTappable.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final events = controller.conversationEvents;

    final defaultInset =
        72.0 + (ChatLoomThemes.isColumnMode(context) ? 16.0 : 0.0);
    if (events == null) {
      _placeholderShown = true;
      return ConversationTimelineSkeleton(
        bottomInset: controller.composerInset.value ?? defaultInset,
      );
    }
    if (_placeholderShown) {
      // The rows replace the placeholder: the list fades in once, from the
      // refresh opacity (never from an empty frame).
      _placeholderShown = false;
      if (_held) {
        _hide();
      } else {
        _reveal(from: NotionMotion.refreshFrom);
      }
    }

    final horizontalPadding = ChatLoomThemes.isColumnMode(context) ? 8.0 : 0.0;

    // Map row key --> index so ListView's findChildIndexCallback is O(1). The
    // key must match the AutoScrollTag key below (transaction id first), or
    // own messages lose their element (and media state) on every insert.
    final thisEventsKeyMap = <String, int>{};
    final dayStarts = <int>{};
    for (var i = 0; i < events.length; i++) {
      final event = events[i];
      thisEventsKeyMap[event.transactionId ?? event.eventId] = i;
      final older = i + 1 < events.length ? events[i + 1] : null;
      if (event.type == EventTypes.RoomCreate ||
          older == null ||
          !event.originServerTs.sameDay(older.originServerTs)) {
        dayStarts.add(i);
      }
    }
    _rows = events;
    _dayStarts = dayStarts;
    _scheduleWideCache();
    _attachPrefetch(events);
    // Photo/video albums (media-render lane): one O(n) pass per list build.
    final albums = MediaAlbums.of(
      events,
      standalone: (event) =>
          event.eventId == controller.readMarkerEventId ||
          _hasFooterContent(event),
    );
    // One palette lookup per list build instead of one per row.
    _listenPersonal();
    final roomPalette = controller.conversationPalette;
    _paletteSignature = Message.paletteSignature(roomPalette);

    final hasWallpaper =
        controller.room.client.applicationAccountConfig.wallpaperUrl != null;

    // The unread divider sits above the oldest unread row: just newer than
    // the row that shows the read marker (or the nearest older row when the
    // marker is on a hidden event).
    final markerRow = events.isEmpty
        ? -1
        : conversationReadMarkerRow(
            events,
            controller.readMarkerEventId,
            timelineEvents: controller.timelineFor(events.first)?.events,
          );
    final unread = conversationUnreadCount(events, markerRow);
    final firstUnread = unread > 0 ? markerRow - 1 : -1;
    final readMarkerRowId = markerRow < 0
        ? controller.readMarkerEventId
        : events[markerRow].eventId;

    final list = SelectionArea(
      onSelectionChanged: (content) {
        final active = content != null && content.plainText.isNotEmpty;
        if (active != _textSelectionActive) {
          setState(() => _textSelectionActive = active);
        }
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: ListView.custom(
          // The composer's height is a spacer under the newest row
          // ([_ComposerSpacer]), not padding: when the reply preview or
          // the field grows, only the spacer rebuilds, never the rows.
          padding: EdgeInsets.only(
            // Clears the glass header drawn over the timeline.
            top: 8 + MediaQuery.paddingOf(context).top,
            bottom: 8,
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
                final spacer = _ComposerSpacer(
                  inset: controller.composerInset,
                  fallback: defaultInset,
                );
                if (controller.canLoadFuture) {
                  final timeline = events.isEmpty
                      ? null
                      : controller.timelineFor(events.first);
                  if (controller.autoLoadFuture &&
                      timeline != null &&
                      identical(timeline, _userScrolled)) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted && controller.autoLoadFuture) {
                        controller.requestFuture(quiet: true);
                      }
                    });
                  }
                  return Column(
                    mainAxisSize: .min,
                    children: [
                      Center(
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
                            controller.historyError ??
                                L10n.of(context).loadMore,
                          ),
                        ),
                      ),
                      spacer,
                    ],
                  );
                }
                return Column(
                  mainAxisSize: .min,
                  children: [
                    if (events.isNotEmpty) SeenByRow(event: events.first),
                    TypingIndicators(controller),
                    EncryptionInfo(room: controller.room),
                    spacer,
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
                          controller.historyError ?? L10n.of(context).loadMore,
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

              final album = albums[i];
              // A lead draws the whole album and groups with the message
              // older than it; hidden members keep an empty row.
              final nextEvent = i + 1 < events.length ? events[i + 1] : null;
              final olderIndex = album != null && album.lead
                  ? i + album.olderIndexOffset
                  : i + 1;
              final groupOlder = olderIndex < events.length
                  ? events[olderIndex]
                  : null;
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

              final displayDate = dayStarts.contains(i);

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
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: NotionSpace.xs,
                          ),
                          child: ConversationDayChip(
                            label: event.originServerTs.localizedDate(context),
                            onTap: () =>
                                controller.pickJumpDate(event.originServerTs),
                          ),
                        ),
                      if (i == firstUnread)
                        ConversationUnreadDivider(count: unread),
                      Message(
                        event,
                        album: album,
                        bigEmojis: controller.bigEmojis,
                        onSwipe: () => controller.replyAction(replyTo: event),
                        onInfoTab: controller.showEventInfo,
                        onMention: () => controller.mentionSender(event),
                        highlightMarker:
                            controller.scrollToEventIdMarker == event.eventId,
                        scrollToEventId: controller.scrollToEventId,
                        readMarkerEventId: readMarkerRowId,
                        textSelectionActive: _textSelectionActive,
                        menuActions: (event) =>
                            controller.messageActions(context, event),
                        timeline: controller.timelineFor(event)!,
                        sourceLabel: controller.sourceLabelFor(event),
                        seriesBoundary: controller.seriesBoundary,
                        strictCapabilities: controller.strictCapabilities,
                        displayReadMarker: firstUnread >= 0 && i == markerRow,
                        nextEvent: groupOlder,
                        previousEvent: previousEvent,
                        wallpaperMode: hasWallpaper,
                        scrollController: controller.scrollController,
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
    );

    return Stack(
      fit: StackFit.passthrough,
      children: [
        FadeTransition(opacity: _opacity, child: list),
        // Under the glass header, still while the rows move beneath it; it
        // fades (opacity only), so it is opaque rather than glass.
        Positioned(
          top: MediaQuery.paddingOf(context).top + NotionSpace.xs,
          left: 0,
          right: 0,
          child: ValueListenableBuilder<bool>(
            valueListenable: _pillTappable,
            builder: (context, tappable, child) =>
                IgnorePointer(ignoring: !tappable, child: child),
            child: ExcludeSemantics(
              child: FadeTransition(
                opacity: _pillOpacity,
                child: Center(
                  child: ValueListenableBuilder<String?>(
                    valueListenable: _pillLabel,
                    builder: (context, label, _) => label == null
                        ? const SizedBox.shrink()
                        : ConversationDayChip(
                            key: const ValueKey('conversation-date-pill'),
                            label: label,
                            // Telegram: the floating date opens the calendar.
                            onTap: () => controller.pickJumpDate(_pillDay),
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Index of the row that shows the read marker [marker] in [rows] (newest
/// first), or -1. A marker on an event without a row (reaction, edit, hidden
/// state) maps to the nearest older row through [timelineEvents].
int conversationReadMarkerRow(
  List<Event> rows,
  String? marker, {
  List<Event>? timelineEvents,
}) {
  if (marker == null || marker.isEmpty) return -1;
  final direct = rows.indexWhere((event) => event.eventId == marker);
  if (direct >= 0 || timelineEvents == null) return direct;
  final at = timelineEvents.indexWhere((event) => event.eventId == marker);
  if (at < 0) return -1;
  final rowOf = Map<Event, int>.identity();
  for (var i = 0; i < rows.length; i++) {
    rowOf[rows[i]] = i;
  }
  for (var i = at; i < timelineEvents.length; i++) {
    final row = rowOf[timelineEvents[i]];
    if (row != null) return row;
  }
  return -1;
}

/// Messages from others newer than the read marker row [markerRow] (rows are
/// newest first): what "N unread messages" counts.
int conversationUnreadCount(List<Event> rows, int markerRow) {
  if (markerRow <= 0) return 0;
  var count = 0;
  for (var i = 0; i < markerRow && i < rows.length; i++) {
    final event = rows[i];
    if (event.senderId == event.room.client.userID) continue;
    if (const {
      EventTypes.Message,
      EventTypes.Sticker,
      EventTypes.Encrypted,
      PollEventContent.startType,
    }.contains(event.type)) {
      count++;
    }
  }
  return count;
}

/// Returns its first child until [revision] changes. Parent rebuilds that do
/// not affect the rows (composer keystrokes, send state, the jump button,
/// notices) get the identical widget back, so Flutter skips the whole list
/// subtree. The list still rebuilds itself for its own inherited
/// dependencies (theme, insets) and private palette changes.
class ConversationListGate extends StatefulWidget {
  final Object revision;
  final Widget child;
  const ConversationListGate({
    super.key,
    required this.revision,
    required this.child,
  });

  @override
  State<ConversationListGate> createState() => _ConversationListGateState();
}

class _ConversationListGateState extends State<ConversationListGate> {
  late Widget _child = widget.child;

  @override
  void didUpdateWidget(ConversationListGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) _child = widget.child;
  }

  @override
  Widget build(BuildContext context) => _child;
}

/// A centred day pill (Telegram, Messenger): between days in the timeline
/// and, floating under the header, while the user scrolls. Opaque `surface`
/// with secondary text, so it reads over wallpapers and private palettes.
class ConversationDayChip extends StatelessWidget {
  final String label;

  /// Jump to date (Telegram): the chip opens the calendar.
  final VoidCallback? onTap;
  const ConversationDayChip({super.key, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final notion = context.notion;
    final chip = DecoratedBox(
      decoration: BoxDecoration(
        color: notion.colors.surface,
        borderRadius: NotionRadius.pillAll,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: NotionSpace.sm,
          vertical: NotionSpace.xxs,
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: notion.typography.captionMuted,
        ),
      ),
    );
    final onTap = this.onTap;
    return Center(
      child: onTap == null
          ? chip
          : Semantics(
              button: true,
              hint: 'Jump to date',
              child: NotionPressable(
                scale: NotionMotion.pressButton,
                onTap: onTap,
                child: chip,
              ),
            ),
    );
  }
}

/// "N unread messages" above the oldest unread message (Telegram, Signal):
/// a day-style pill between hairlines.
class ConversationUnreadDivider extends StatelessWidget {
  final int count;
  const ConversationUnreadDivider({super.key, required this.count});

  static String labelFor(int count) =>
      count == 1 ? '1 unread message' : '$count unread messages';

  @override
  Widget build(BuildContext context) {
    final notion = context.notion;
    final line = Expanded(
      child: Divider(height: 1, thickness: 1, color: notion.colors.border),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: NotionSpace.md,
        vertical: NotionSpace.xs,
      ),
      child: Row(
        children: [
          line,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: NotionSpace.xs),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: notion.colors.surface,
                borderRadius: NotionRadius.pillAll,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: NotionSpace.sm,
                  vertical: NotionSpace.xxs,
                ),
                child: Text(
                  labelFor(count),
                  style: notion.typography.captionMuted.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          line,
        ],
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
                    maxWidth: ChatLoomThemes.maxTimelineWidth,
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

/// Room under the newest message for the composer drawn over the list. It
/// listens to the measured composer height itself, so a growing reply
/// preview or field relayouts the list without rebuilding its rows.
class _ComposerSpacer extends StatelessWidget {
  final ValueListenable<double?> inset;
  final double fallback;

  const _ComposerSpacer({required this.inset, required this.fallback});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double?>(
    valueListenable: inset,
    builder: (context, height, _) => SizedBox(height: height ?? fallback),
  );
}

/// The "jump to the newest message" button over a conversation. It stays
/// mounted and springs in and out (instead of the Scaffold's default FAB
/// swap); [count] new messages that arrived while scrolled up roll in a
/// badge. A round dock-style pill (Telegram's translucent arrow).
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
    final colors = context.notion.colors;
    return ExcludeSemantics(
      excluding: !visible,
      child: IgnorePointer(
        ignoring: !visible,
        child: NotionPop(
          visible: visible,
          playOnMount: false,
          bounce: false,
          alignment: Alignment.bottomCenter,
          child: Badge(
            isLabelVisible: count > 0,
            backgroundColor: colors.text,
            textColor: colors.background,
            label: NotionAnimatedCount(
              count: count,
              format: (n) => n > 99 ? '99+' : '$n',
            ),
            // No blur: the button scales in and out (glass never animates).
            child: NotionGlassPill(
              key: const ValueKey('conversation-jump'),
              icon: Icons.keyboard_arrow_down,
              tooltip: tooltip,
              onPressed: onPressed,
            ),
          ),
        ),
      ),
    );
  }
}

/// Places the jump button at the end edge just above the measured composer
/// (reply/edit preview, action tray and emoji picker included), so it never
/// covers the composer's controls such as the reply close button. Only this
/// slot follows the composer's height; the page does not rebuild.
class ConversationJumpButtonSlot extends StatelessWidget {
  final ValueListenable<double?> composerInset;
  final Widget child;
  final double endInset;

  const ConversationJumpButtonSlot({
    super.key,
    required this.composerInset,
    required this.child,
    this.endInset = NotionSpace.md,
  });

  /// Composer height before the first measurement.
  static const double fallbackInset = 72;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double?>(
    valueListenable: composerInset,
    child: child,
    builder: (context, inset, child) => Padding(
      padding: EdgeInsetsDirectional.only(
        end: endInset,
        bottom: (inset ?? fallbackInset) + NotionSpace.xs,
      ),
      child: child,
    ),
  );
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

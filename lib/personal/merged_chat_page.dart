// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/config/themes.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat.dart';
import 'package:chatloom/pages/chat/chat_app_bar_list_tile.dart';
import 'package:chatloom/pages/chat/chat_emoji_picker.dart';
import 'package:chatloom/pages/chat/chat_event_list.dart';
import 'package:chatloom/pages/chat/chat_input_row.dart';
import 'package:chatloom/pages/chat/chat_message_actions.dart';
import 'package:chatloom/pages/chat/chat_wallpaper.dart';
import 'package:chatloom/pages/chat/compact_composer.dart';
import 'package:chatloom/pages/chat/composer_keyboard.dart';
import 'package:chatloom/pages/chat/composer_send_later.dart';
import 'package:chatloom/pages/chat/conversation_drop_target.dart';
import 'package:chatloom/pages/chat/conversation_message_actions.dart';
import 'package:chatloom/pages/chat/conversation_message_menu.dart';
import 'package:chatloom/pages/chat/conversation_motion.dart';
import 'package:chatloom/pages/chat/conversation_navigation.dart';
import 'package:chatloom/pages/chat/conversation_read_button.dart';
import 'package:chatloom/pages/chat/conversation_search.dart';
import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/pages/chat/conversation_source_picker.dart';
import 'package:chatloom/pages/chat/event_info_dialog.dart';
import 'package:chatloom/pages/chat/events/message_delivery_status.dart';
import 'package:chatloom/pages/chat/message_deletion.dart';
import 'package:chatloom/pages/chat/message_link_actions.dart';
import 'package:chatloom/pages/chat/notion_conversation.dart';
import 'package:chatloom/pages/chat/reply_display.dart';
import 'package:chatloom/pages/chat/send_file_dialog.dart';
import 'package:chatloom/pages/chat/send_location_dialog.dart';
import 'package:chatloom/pages/chat/start_poll_bottom_sheet.dart';
import 'package:chatloom/pages/chat/trust_user_key_dialog.dart';
import 'package:chatloom/pages/chat/undecryptable_chat_hint.dart';
import 'package:chatloom/pages/chat/undecryptable_fix_sheet.dart';
import 'package:chatloom/pages/chat/voice_message_sender.dart';
import 'package:chatloom/pages/chat_list/chat_list_item.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/conversation_mute.dart';
import 'package:chatloom/personal/developer_options.dart';
import 'package:chatloom/personal/copy_notice.dart';
import 'package:chatloom/personal/encryption/undecryptable_messages.dart';
import 'package:chatloom/personal/immediate_outbox.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/personal/media/media_export_actions.dart';
import 'package:chatloom/personal/message_bookmarks.dart';
import 'package:chatloom/personal/network_chat_actions.dart';
import 'package:chatloom/personal/network_rejections.dart';
import 'package:chatloom/personal/performance_probe.dart';
import 'package:chatloom/personal/person_group_identity.dart';
import 'package:chatloom/personal/person_location.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/personal_hub.dart'
    show conversationQuickActions, requestConversationReminder;
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/read_targets.dart';
import 'package:chatloom/personal/round_video/round_availability.dart';
import 'package:chatloom/personal/round_video/round_capture_controller.dart';
import 'package:chatloom/personal/round_video/telegram_room_binding.dart';
import 'package:chatloom/personal/round_video/telegram_round_service.dart';
import 'package:chatloom/personal/scheduled_composer.dart';
import 'package:chatloom/personal/seen_chat_notifications.dart';
import 'package:chatloom/personal/send_warmup.dart';
import 'package:chatloom/personal/text_split.dart';
import 'package:chatloom/personal/ui/forward_sheet.dart';
import 'package:chatloom/personal/stickers/sticker_message_actions.dart';
import 'package:chatloom/personal/ui/health_status_widgets.dart';
import 'package:chatloom/personal/ui/conversation_activity_widgets.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart'
    show notionNetworkLabel;
import 'package:chatloom/personal/ui/person_page.dart';
import 'package:chatloom/personal/ui/person_sheets.dart'
    show personSourceActivity;
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/account_config.dart';
import 'package:chatloom/utils/error_reporter.dart';
import 'package:chatloom/utils/file_selector.dart';
import 'package:chatloom/utils/macos_desktop.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/app_lock.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:chatloom/widgets/share_scaffold_dialog.dart';
import 'package:collection/collection.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import 'merged_attachments.dart';
import 'send_later.dart' show runSendLater;

class SourceChatPage extends StatelessWidget {
  final SourceEventRef source;
  const SourceChatPage({super.key, required this.source});
  @override
  Widget build(BuildContext context) {
    final matrix = Matrix.of(context);
    final active = matrix.client;
    final correct = matrix.widget.clients
        .where((c) => c.userID == source.conversation.accountId)
        .firstOrNull;
    if (active.userID == source.conversation.accountId &&
        active.getRoomById(source.conversation.roomId) != null) {
      return ChatPage(
        roomId: source.conversation.roomId,
        eventId: source.eventId,
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Source message')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'The source conversation is unavailable in the current account.',
              ),
              if (correct != null &&
                  correct.getRoomById(source.conversation.roomId) != null)
                TextButton(
                  onPressed: () {
                    matrix.setActiveClient(correct);
                    context.go(
                      '/rooms/${source.conversation.roomId}?event=${Uri.encodeComponent(source.eventId)}',
                    );
                  },
                  child: const Text('Open in the source account'),
                ),
              TextButton(
                onPressed: () => Navigator.maybePop(context),
                child: const Text('Back'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One conversation with a person across their source chats (networks). It
/// renders through the ordinary chat timeline ([ChatEventList], [Message])
/// and composer ([ChatInputRow]); only the source routing differs.
class MergedChatPage extends StatelessWidget {
  final PersonalClient personal;
  final PersonGroup group;

  /// Source preselected for sending when no draft owns one (notification).
  final String? initialSourceRoomId;

  /// Source event to scroll to after loading (notification, reminder).
  final String? initialEventId;

  const MergedChatPage({
    super.key,
    required this.personal,
    required this.group,
    this.initialSourceRoomId,
    this.initialEventId,
  });
  @override
  Widget build(BuildContext context) => _MergedChatView(
    key: ValueKey((personal, group.id)),
    personal: personal,
    group: group,
    initialSourceRoomId: initialSourceRoomId,
    initialEventId: initialEventId,
  );
}

class _MergedChatView extends StatefulWidget {
  final PersonalClient personal;
  final PersonGroup group;
  final String? initialSourceRoomId;
  final String? initialEventId;
  const _MergedChatView({
    super.key,
    required this.personal,
    required this.group,
    this.initialSourceRoomId,
    this.initialEventId,
  });
  @override
  State<_MergedChatView> createState() => _MergedChatPageState();
}

class _MergedChatPageState extends State<_MergedChatView>
    with WidgetsBindingObserver
    implements
        ConversationTimelineSource,
        ConversationComposerHost,
        ConversationSourceHintHost,
        ComposerSendLaterHost {
  late final PersonalClient personal = widget.personal;
  PersonGroup get group => widget.group;

  final timelines = <String, Timeline>{};
  @override
  final TextEditingController sendController = TextEditingController();
  @override
  late final FocusNode inputFocus = FocusNode(
    onKeyEvent: (_, event) => conversationComposerKeyResult(
      event,
      value: sendController.value,
      sendOnEnter: AppSettings.sendOnEnter.value,
      shiftPressed: HardwareKeyboard.instance.isShiftPressed,
      metaPressed:
          !PlatformInfos.isMobile && HardwareKeyboard.instance.isMetaPressed,
      onSend: send,
      // Desktop parity with ordinary chats: ↑ edits the last own message.
      onEditLast:
          PlatformInfos.isMobile || replyEvent != null || editEvent != null
          ? null
          : _editLastOwnMessage,
    ),
  );
  @override
  final AutoScrollController scrollController = AutoScrollController();
  final GlobalKey inputBarKey = GlobalKey();
  @override
  final ValueNotifier<double?> composerInset = ValueNotifier(null);

  int _generation = 0;
  final viewed = <String, Event>{};

  // Merged rows and per-row derivatives, computed once per source change
  // (never in build, getters or row builders).
  List<Event> _rows = const [];

  /// Rows still waiting for a room key (header "couldn't be decrypted").
  List<Event> _locked = const [];
  final _boundaries = <String, bool>{};
  bool _hasMore = false;
  MergedEvent<Object?>? _recentRoutable;
  final _mergedOf = Expando<MergedEvent<Event>>();
  final _keyRequests = <String, (DateTime, int)>{};
  bool _timelineChangeScheduled = false;
  bool _visibilityScanScheduled = false;
  Timer? _scrollScanTimer;
  bool _scrolledUp = false;

  /// New messages that arrived while the list was scrolled up; shown on the
  /// jump button and reset once the newest message is in view again.
  int _newBelow = 0;

  /// Bumped whenever the list must rebuild; composer-only changes keep it.
  int _listRevision = 0;
  String? _personalSignature;
  bool _liveUpdatePending = false;
  final _seenRows = <String>{};
  DateTime? _latestSeen;
  bool _readMarkerResolved = false;
  String? _pendingEvent;

  @override
  String? animateInEventId;
  @override
  String? readMarkerEventId;
  @override
  String? scrollToEventIdMarker;
  @override
  final Set<String> expandedEventIds = const {};
  @override
  bool historyLoading = false;
  @override
  String? historyError;

  ConversationRef? selectedNetwork;
  SendTarget? _draftTarget;
  MergedEvent<Object?>? _confirmedOutgoing;
  bool _needsNetworkChoice = false;
  String? _savedDraftText;
  bool _draftRestored = false;
  final unavailable = <String>{};

  /// Sources that are not part of the conversation right now (left,
  /// deleted, only invited, or shown by another person): not loaded, never
  /// routed to; the notice links to the person page.
  final _inactive = <String>{};

  /// Members that can receive the next message and the person's routing
  /// mode, cached between store changes (see [_routing]).
  (Set<ConversationRef>, bool)? _routingCache;
  @override
  Event? replyEvent;
  @override
  Event? editEvent;
  String _pendingText = '';
  @override
  bool showEmojiPicker = false;
  bool loading = true, sending = false;

  /// Over-long texts go as several messages once the user agrees (BR-05).
  final _longText = LongMessageSplitter();
  Timer? _draftTimer;

  /// Persistent state shown under the header (unavailable sources, a draft
  /// without a source). Transient failures use a snackbar instead.
  String? problem;
  bool _inputEmpty = true;
  Timer? _typingCoolDown, _typingTimeout;
  Room? _typingRoom;
  final _voiceSender = VoiceMessageSender();

  @override
  void initState() {
    super.initState();
    _personalSignature = _computePersonalSignature();
    personal.addListener(_personalChanged);
    scrollController.addListener(_onScroll);
    inputFocus.addListener(_inputFocusChanged);
    WidgetsBinding.instance.addObserver(this);
    _pendingEvent = widget.initialEventId;
    // A network refusing a reaction, edit or deletion is said here.
    _rejections = NetworkRejectionWatcher(
      personal.client,
      rooms: () => conversationRoomIds,
      notify: _notify,
    );
    if (PlatformInfos.isMacOS) {
      MacDesktopCommands.bindChat(
        this,
        MacChatCommands(
          searchInChat: _openSearch,
          scrollToTop: () {
            if (!scrollController.hasClients) return;
            scrollController.jumpTo(scrollController.position.maxScrollExtent);
          },
          scrollToBottom: () => unawaited(_jumpToLatest()),
          typeIntoComposer: (text) => typeIntoComposer(this, text),
          // Esc = Back: PopScope cancels a reply, edit or panel first.
          escape: () {
            if (!mounted) return false;
            unawaited(Navigator.maybePop(context));
            return true;
          },
        ),
      );
    }
    // A search hit in the person's details comes back here.
    ConversationJumpTargets.register(
      this,
      covers: (room) =>
          identical(room.client, personal.client) &&
          group.members.any((m) => m.roomId == room.id),
      jump: _jumpToHit,
    );
    // A busy source opens at its first unread message: keep the list
    // invisible until it is positioned (as the ordinary chat does).
    _hold.value = group.members.any((member) {
      final room = personal.client.getRoomById(member.roomId);
      return room != null &&
          room.hasNewMessages &&
          room.notificationCount >= _holdUnreadRows;
    });
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _openProbe.mark('first_frame');
        NotionMotion.afterRouteSettled(context, () => _openProbe.mark('route'));
      }
      // The first send must not wait for the member list (trust check);
      // loaded once the opening slide has finished.
      final room = mounted ? _targetRoom : null;
      if (room != null) {
        warmUpSendPath(room, route: ModalRoute.of(context)?.animation);
      }
    });
  }

  @override
  void didUpdateWidget(_MergedChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The store hands out a new group object on every read; only a change of
    // the sources is worth re-merging the history (and rebuilding the rows).
    _routingCache = null;
    if (!samePersonMembers(oldWidget.group, widget.group)) {
      final members = {for (final m in widget.group.members) m.roomId};
      for (final roomId in timelines.keys.toList()) {
        if (!members.contains(roomId)) {
          timelines.remove(roomId)?.cancelSubscriptions();
        }
      }
      _dropRemovedSources();
      _recomputeMerged();
      _markSeen();
      // A source added to the person loads like the first ones.
      if (members.any((id) => !timelines.containsKey(id)) && !loading) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !loading) unawaited(_load());
        });
      }
    }
    if (widget.initialSourceRoomId != oldWidget.initialSourceRoomId) {
      // build follows didUpdateWidget; no setState needed.
      _applyInitialSource();
    }
    if (widget.initialEventId != oldWidget.initialEventId &&
        widget.initialEventId != null) {
      _pendingEvent = widget.initialEventId;
      if (!loading) unawaited(_revealPendingEvent());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _scheduleVisibilityScan();
    if (state != AppLifecycleState.resumed) _stopTyping();
  }

  // ---------------------------------------------------------------------
  // Private store and derived rows.

  /// Everything this page renders from the personal store: the person's
  /// name, photo, routing and palettes. Draft saves, heartbeats and unrelated metadata
  /// leave it unchanged and therefore do not rebuild the conversation.
  String _computePersonalSignature() {
    final projection = InboxProjection.snapshot(personal);
    final person = projection.metadataForEntity('person:${group.id}');
    return jsonEncode([
      projection.personName(group),
      person.avatarAsset,
      // "Send messages via" changes the composer's network.
      projection.preferencesFor(group.id).routing.name,
      person.theme?.toJson(),
      for (final member in group.members)
        switch (personal.client.getRoomById(member.roomId)) {
          final Room room => projection.metadataFor(room).theme?.toJson(),
          null => null,
        },
    ]);
  }

  void _personalChanged() {
    if (!mounted) return;
    _routingCache = null;
    final signature = _computePersonalSignature();
    if (signature == _personalSignature) return;
    _personalSignature = signature;
    setState(() => _listRevision++);
  }

  static const _rowTypes = {
    EventTypes.Message,
    EventTypes.Sticker,
    EventTypes.Encrypted,
    PollEventContent.startType,
  };

  static const _seriesTypes = {..._rowTypes, EventTypes.Reaction};

  static bool _isRow(Event e) =>
      _rowTypes.contains(e.type) &&
      e.relationshipType != RelationshipTypes.edit &&
      // A message the user just deleted disappears at once.
      !MessageDeletions.hides(e);

  static String _rowKey(Event e) => '${e.room.id}\u0000${e.eventId}';

  /// Reuses the merged wrapper of an unchanged event object.
  MergedEvent<Event> _mergedFor(Event e, ConversationRef member) {
    final cached = _mergedOf[e];
    if (cached != null &&
        cached.source.eventId == e.eventId &&
        cached.timestamp == e.originServerTs) {
      return cached;
    }
    return _mergedOf[e] = MergedEvent(
      source: SourceEventRef(conversation: member, eventId: e.eventId),
      timestamp: e.originServerTs,
      isOutgoing: e.senderId == personal.client.userID,
      value: e,
    );
  }

  /// Source-local series breaks: hidden state events still split a visual
  /// series on either side. One linear pass per source timeline.
  static void _sourceBoundaries(List<Event> events, Map<String, bool> into) {
    final significant = <Event>[
      for (final e in events)
        if (e.type != EventTypes.Reaction &&
            e.relationshipType != RelationshipTypes.edit)
          e,
    ];
    bool separator(Event e) => !_seriesTypes.contains(e.type);
    for (var i = 0; i < significant.length; i++) {
      final e = significant[i];
      if (!_rowTypes.contains(e.type)) continue;
      into[_rowKey(e)] =
          (i > 0 && separator(significant[i - 1])) ||
          (i + 1 < significant.length && separator(significant[i + 1]));
    }
  }

  void _recomputeMerged() {
    final buffer = MergedTimelineBuffer<Event>(group.members);
    _boundaries.clear();
    for (final member in group.members) {
      final t = timelines[member.roomId];
      if (t == null) {
        buffer.addPage(member: member, events: const [], hasMore: false);
        continue;
      }
      buffer.addPage(
        member: member,
        events: t.events.where(_isRow).map((e) => _mergedFor(e, member)),
        hasMore: t.canRequestHistory,
        cursor: t.canRequestHistory
            ? t.events.lastOrNull?.eventId ?? 'initial'
            : null,
      );
      _sourceBoundaries(t.events, _boundaries);
    }
    _rows = [for (final merged in buffer.coveredEvents.reversed) merged.value];
    _locked = [
      for (final row in _rows)
        if (isUndecryptable(row)) row,
    ];
    _hasMore = buffer.hasMore;
    _recentRoutable = buffer.events.lastWhereOrNull(
      (event) => !event.isOutgoing || event.value.status.isSent,
    );
    _listRevision++;
  }

  /// Bookkeeping for live arrivals: only rows newer than everything seen
  /// before animate in.
  void _markSeen() {
    for (final row in _rows) {
      _seenRows.add(_rowKey(row));
      if (_latestSeen == null || row.originServerTs.isAfter(_latestSeen!)) {
        _latestSeen = row.originServerTs;
      }
    }
  }

  /// Ask key backup and own devices for missing room keys, as the ordinary
  /// chat does after loading. Throttled per room: an unchanged timeline is not
  /// re-scanned within 10 seconds.
  void _requestKeys(Timeline timeline) {
    final roomId = timeline.room.id;
    final now = DateTime.now();
    final length = timeline.events.length;
    final last = _keyRequests[roomId];
    if (last != null &&
        last.$2 == length &&
        now.difference(last.$1) < const Duration(seconds: 10)) {
      return;
    }
    _keyRequests[roomId] = (now, length);
    try {
      timeline.requestKeys(onlineKeyBackupOnly: false);
    } catch (_) {
      // Key requests are best effort; undecryptable rows stay visible.
    }
  }

  /// The unread divider sits under the newest read row: just older than the
  /// oldest row that follows its own source's read marker (as the ordinary
  /// chat places it under that source's marker). Frozen once loaded.
  void _resolveReadMarker() {
    if (_readMarkerResolved) return;
    _readMarkerResolved = true;
    Event? oldestUnread;
    for (final t in timelines.values) {
      final room = t.room;
      if (!room.hasNewMessages || room.fullyRead.isEmpty) continue;
      final readIndex = t.events.indexWhere((e) => e.eventId == room.fullyRead);
      if (readIndex <= 0) continue;
      for (var i = readIndex - 1; i >= 0; i--) {
        final e = t.events[i];
        if (!_isRow(e)) continue;
        if (oldestUnread == null ||
            e.originServerTs.isBefore(oldestUnread.originServerTs)) {
          oldestUnread = e;
        }
        break;
      }
    }
    if (oldestUnread == null) return;
    final key = _rowKey(oldestUnread);
    final index = _rows.indexWhere((e) => _rowKey(e) == key);
    if (index < 0 || index + 1 >= _rows.length) return;
    readMarkerEventId = _rows[index + 1].eventId;
    _listRevision++;
  }

  Future<void> _load() async {
    _generation++;
    if (!loading) setState(() => loading = true);
    unavailable.clear();
    _inactive.clear();
    _routingCache = null;
    problem = null;
    try {
      // Journal network synchronization must not block source conversations.
      unawaited(personal.load().catchError((Object _) {}));
      try {
        await personal.loadLocal();
      } catch (_) {
        problem =
            'Private storage is unavailable. Conversation history remains accessible.';
      }
      try {
        await personal.client.roomsLoading?.timeout(
          const Duration(seconds: 15),
        );
      } on TimeoutException {
        // Cached rooms can still provide history; missing sources remain retryable.
      }
      if (!mounted) return;
      final sources = InboxProjection.snapshot(personal).sourcesOf(group);
      for (final source in sources) {
        if (!source.sendable) _inactive.add(source.member.roomId);
      }
      await Future.wait(
        group.members.map((member) async {
          if (timelines.containsKey(member.roomId)) return;
          // Left, deleted or only invited, or shown by another person.
          if (_inactive.contains(member.roomId)) return;
          final room = personal.client.getRoomById(member.roomId);
          if (room == null || member.accountId != personal.client.userID) {
            unavailable.add(member.roomId);
            return;
          }
          try {
            final timeline = await room.getTimeline(
              onNewEvent: () => _liveUpdatePending = true,
              onUpdate: _timelineChanged,
            );
            if (!mounted) {
              timeline.cancelSubscriptions();
              return;
            }
            timelines[member.roomId] = timeline;
            _requestKeys(timeline);
            _recomputeMerged();
            _markSeen();
            setState(() {});
          } catch (_) {
            unavailable.add(member.roomId);
          }
        }),
      );
      if (!mounted) return;
      _restoreDraft();
      _draftRestored = true;
      if (unavailable.isNotEmpty) {
        problem =
            'Some sources are unavailable. History from available networks is shown.';
      } else if (_inactive.isNotEmpty && problem == null) {
        final networks = {
          for (final member in group.members)
            if (_inactive.contains(member.roomId))
              notionNetworkLabel(member.network),
        }.join(', ');
        problem = _inactive.length == 1
            ? 'The $networks chat is no longer part of this conversation. The other networks keep working.'
            : 'Some chats ($networks) are no longer part of this conversation. The other networks keep working.';
      }
    } catch (_) {
      problem =
          'A source could not be opened. The send network remains unchanged.';
    }
    if (!mounted) return;
    final firstLoad = !_readMarkerResolved;
    _resolveReadMarker();
    _applyInitialSource();
    setState(() => loading = false);
    _openProbe
      ..mark('timeline')
      ..markAfterFrame('rows');
    _scheduleVisibilityScan();
    if (firstLoad && _pendingEvent == null) {
      unawaited(_openAtUnread());
    } else {
      _hold.value = false;
    }
    unawaited(_revealPendingEvent());
  }

  // ---------------------------------------------------------------------
  // Opening position, mentions, dates and search (FX-03, FX-10, FX-11).

  /// Unread rows from which the list is positioned while invisible.
  static const int _holdUnreadRows = 6;

  /// True while the list is laid out but invisible (see [ChatEventList]).
  final ValueNotifier<bool> _hold = ValueNotifier(false);

  /// Telegram: a conversation with unread messages opens with the "N unread
  /// messages" divider right under the header; the jump button counts them.
  Future<void> _openAtUnread() async {
    try {
      final marker = readMarkerEventId;
      if (marker == null) return;
      final markerRow = _rows.indexWhere((e) => e.eventId == marker);
      final unread = conversationUnreadCount(_rows, markerRow);
      // A short run fits on the first screen: stay at the newest message.
      if (unread <= 0 || markerRow < 1) return;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      if (!await conversationRevealRow(
        context,
        scrollController,
        markerRow - 1,
        animate: false,
      )) {
        return;
      }
      if (!mounted || !scrollController.hasClients) return;
      if (scrollController.offset > 0) {
        setState(() {
          _scrolledUp = scrollController.offset > 120;
          _newBelow = unread;
        });
      }
    } finally {
      if (mounted) _hold.value = false;
    }
  }

  final Set<String> _handledMentions = {};
  final ValueNotifier<int> _mentionsHandled = ValueNotifier(0);

  /// The "@" button: the oldest unread mention across the sources.
  Future<void> _jumpToMention() async {
    int markerRow() {
      final marker = readMarkerEventId;
      return marker == null ? -1 : _rows.indexWhere((e) => e.eventId == marker);
    }

    for (var page = 0; page < 3 && markerRow() < 0; page++) {
      if (readMarkerEventId == null || !_hasMore || historyError != null) {
        break;
      }
      await requestHistory();
      if (!mounted) return;
    }
    final mentions = conversationUnreadMentions(
      _rows,
      markerRow(),
      highlighted: conversationHighlights,
      handled: _handledMentions,
    );
    if (mentions.isEmpty) {
      _mentionsHandled.value = math.max(
        _mentionsHandled.value,
        _readSources.fold<int>(0, (sum, room) => sum + room.highlightCount),
      );
      return;
    }
    final target = mentions.first;
    _handledMentions.add(target.eventId);
    _mentionsHandled.value = _handledMentions.length;
    await scrollToEventId(target.eventId);
  }

  @override
  Future<void> pickJumpDate([DateTime? around]) async {
    final day = await pickConversationDay(context, around ?? DateTime.now());
    if (day == null || !mounted) return;
    // Merged history pages per source; a day further back than ten pages
    // is said instead of loading without end.
    for (var page = 0; page <= 10; page++) {
      if (conversationRowsReachDay(_rows, day) || !_hasMore) {
        final index = conversationRowForDay(_rows, day);
        if (index < 0) {
          await _jumpToLatest();
        } else {
          await WidgetsBinding.instance.endOfFrame;
          if (!mounted) return;
          await conversationRevealRow(
            context,
            scrollController,
            index,
            animate: true,
          );
        }
        return;
      }
      if (historyError != null) break;
      await requestHistory();
      if (!mounted) return;
    }
    _notify('Couldn’t load messages from that day.');
  }

  ConversationSearchController? _search;
  bool _searchShown = false;

  ConversationSearchController get _searchController =>
      _search ??= ConversationSearchController(
        rooms: () => [for (final t in timelines.values) t.room],
        loaded: () => [for (final t in timelines.values) ...t.events],
        jump: _jumpToHit,
      )..addListener(_searchChanged);

  bool get _searching => _search?.active ?? false;

  void _searchChanged() {
    final shown = _searching;
    if (shown == _searchShown || !mounted) return;
    _searchShown = shown;
    setState(() {});
  }

  void _openSearch() {
    if (!mounted || timelines.isEmpty) return;
    if (showEmojiPicker) hideEmojiPicker();
    inputFocus.unfocus();
    _searchController.open();
  }

  /// A search hit: scrolls to it, paging the merged history back while it
  /// is older than what is loaded; further back, its source chat offers it.
  Future<void> _jumpToHit(Event event) async {
    for (var page = 0; page < 8; page++) {
      if (_rows.any((e) => e.eventId == event.eventId)) {
        await WidgetsBinding.instance.endOfFrame;
        if (mounted) await scrollToEventId(event.eventId);
        return;
      }
      if (!_hasMore || historyError != null) break;
      await requestHistory();
      if (!mounted) return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('This message is older than the loaded history.'),
        action: SnackBarAction(
          label: 'Open',
          onPressed: () => context.go(
            personSourceChatLocation(
              group.id,
              event.room.id,
              eventId: event.eventId,
            ),
          ),
        ),
      ),
    );
  }

  /// `merged_open.*` probe points, from this page's creation (the tap).
  final _openProbe = PersonalPerformanceProbe.span('merged_open');

  void _restoreDraft() {
    final draft = personal.values['draft:person:${group.id}'];
    if (_draftRestored ||
        sendController.text.isNotEmpty ||
        draft?['text'] is! String) {
      return;
    }
    sendController.text = draft!['text'] as String;
    _inputEmpty = sendController.text.isEmpty;
    final target = draft['target'];
    if (target is Map) {
      try {
        final restored = SendTarget.fromJson(Map<String, dynamic>.from(target));
        if (group.members.contains(restored.conversation)) {
          _draftTarget = restored;
          selectedNetwork = restored.conversation;
        } else {
          _needsNetworkChoice = true;
          problem =
              'This draft belongs to a source outside this person. Choose a network before sending.';
        }
      } catch (_) {
        _needsNetworkChoice = true;
        problem =
            'The draft source could not be read. Choose a network before sending.';
      }
    } else if (sendController.text.isNotEmpty) {
      _needsNetworkChoice = true;
      problem =
          'This draft has no saved source. Choose a network before sending.';
    }
    _savedDraftText = sendController.text;
  }

  /// A notification's source becomes the send source unless a draft, reply
  /// or edit already owns one.
  void _applyInitialSource() {
    final roomId = widget.initialSourceRoomId;
    if (roomId == null ||
        _draftTarget != null ||
        _needsNetworkChoice ||
        replyEvent != null ||
        editEvent != null) {
      return;
    }
    final member = group.members.firstWhereOrNull((m) => m.roomId == roomId);
    if (member == null || member.accountId != personal.client.userID) return;
    selectedNetwork = member;
  }

  /// Scrolls to the event a notification or reminder pointed at. An event
  /// older than the loaded history opens in its source chat instead.
  Future<void> _revealPendingEvent() async {
    final eventId = _pendingEvent;
    if (eventId == null || !mounted) return;
    _pendingEvent = null;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (_rows.any((e) => e.eventId == eventId)) {
        await WidgetsBinding.instance.endOfFrame;
        if (mounted) await scrollToEventId(eventId);
        return;
      }
      if (!_hasMore || historyError != null) break;
      await requestHistory();
      if (!mounted) return;
    }
    final source = widget.initialSourceRoomId;
    if (source == null || !mounted) return;
    context.go(personSourceChatLocation(group.id, source, eventId: eventId));
  }

  // ---------------------------------------------------------------------
  // Live updates, scroll anchor and read observation.

  /// Source timelines report many updates per sync batch; apply them once
  /// per frame (before layout, so the anchor is read from the old layout).
  void _timelineChanged() {
    // A membership change of a source arrives through its timeline.
    _routingCache = null;
    if (!mounted || _timelineChangeScheduled) return;
    _timelineChangeScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _timelineChangeScheduled = false;
      _applyTimelineChange();
    });
  }

  /// The topmost visible row and its screen position, from the mounted
  /// scroll tags of the current rows.
  (String, double)? _visibleAnchor() {
    if (!scrollController.hasClients) return null;
    final viewport = scrollController.position.context.storageContext
        .findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return null;
    final visible = viewport.localToGlobal(Offset.zero) & viewport.size;
    (String, double)? result;
    for (final entry in scrollController.tagMap.entries) {
      if (entry.key < 0 || entry.key >= _rows.length) continue;
      final box = entry.value.context.findRenderObject();
      if (box is! RenderBox || !box.hasSize || !box.attached) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (!visible.overlaps(rect)) continue;
      if (result == null || rect.top < result.$2) {
        result = (_rowKey(_rows[entry.key]), rect.top);
      }
    }
    return result;
  }

  double? _rowTop(String key) {
    final index = _rows.indexWhere((e) => _rowKey(e) == key);
    if (index < 0) return null;
    final box = scrollController.tagMap[index]?.context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    return box.localToGlobal(Offset.zero).dy;
  }

  void _applyTimelineChange() {
    if (!mounted) return;
    final anchor = scrollController.hasClients && scrollController.offset > 80
        ? _visibleAnchor()
        : null;
    _recomputeMerged();
    // Only the update that brought a message animates it; any later update
    // (status, decryption, edits) must not replay it on a rebuilt row.
    animateInEventId = null;
    if (_liveUpdatePending && !loading && !historyLoading && anchor != null) {
      final previousLatest = _latestSeen;
      _newBelow += _rows
          .where(
            (row) =>
                !_seenRows.contains(_rowKey(row)) &&
                previousLatest != null &&
                !row.originServerTs.isBefore(previousLatest),
          )
          .length;
    }
    if (_liveUpdatePending && !loading && !historyLoading && anchor == null) {
      final previousLatest = _latestSeen;
      final fresh = _rows.firstWhereOrNull(
        (row) =>
            !_seenRows.contains(_rowKey(row)) &&
            previousLatest != null &&
            !row.originServerTs.isBefore(previousLatest),
      );
      if (fresh != null) {
        animateInEventId = fresh.transactionId ?? fresh.eventId;
      }
    }
    _markSeen();
    _liveUpdatePending = false;
    for (final t in timelines.values) {
      _requestKeys(t);
    }
    setState(() {});
    _scheduleVisibilityScan();
    if (anchor == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scrollController.hasClients) return;
      final after = _rowTop(anchor.$1);
      if (after == null) return;
      final restored = notionRestoredScrollOffset(
        scrollController.offset,
        anchor.$2,
        after,
        reverse: true,
      );
      scrollController.jumpTo(
        restored.clamp(
          scrollController.position.minScrollExtent,
          scrollController.position.maxScrollExtent,
        ),
      );
    });
  }

  void _onScroll() {
    final up = scrollController.hasClients && scrollController.offset > 120;
    if (mounted && up != _scrolledUp) {
      setState(() {
        _scrolledUp = up;
        if (!up) _newBelow = 0;
      });
    }
    _scrollScanTimer ??= Timer(const Duration(milliseconds: 200), () {
      _scrollScanTimer = null;
      _observeVisibleRows();
    });
  }

  /// One visibility pass after the frame in which rows were (re)built.
  void _scheduleVisibilityScan() {
    if (_visibilityScanScheduled) return;
    _visibilityScanScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityScanScheduled = false;
      _observeVisibleRows();
    });
  }

  /// Observes (and, when policy allows, marks read) the newest visible source
  /// event per room. Rows built ahead in the cache extent are not visible
  /// and are picked up by the scroll-driven pass once they appear.
  void _observeVisibleRows() {
    // Local only: clears every member's notification at the newest message.
    if (mounted) {
      SeenChatNotifications.seen(
        context,
        [for (final timeline in timelines.values) timeline.room],
        atBottom: () =>
            scrollController.hasClients && scrollController.offset <= 1,
      );
    }
    if (!mounted ||
        !PersonalPrivacy.surfaceUnlocked ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
        ModalRoute.of(context)?.isCurrent == false ||
        !scrollController.hasClients) {
      return;
    }
    final viewport = scrollController.position.context.storageContext
        .findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return;
    final visible = viewport.localToGlobal(Offset.zero) & viewport.size;
    final newest = <String, Event>{};
    for (final entry in scrollController.tagMap.entries) {
      if (entry.key < 0 || entry.key >= _rows.length) continue;
      final event = _rows[entry.key];
      if (!event.eventId.startsWith(r'$')) continue;
      final box = entry.value.context.findRenderObject();
      if (box is! RenderBox || !box.hasSize || !box.attached) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (!visible.overlaps(rect)) continue;
      final current = newest[event.room.id];
      if (current == null ||
          event.originServerTs.isAfter(current.originServerTs)) {
        newest[event.room.id] = event;
      }
    }
    for (final event in newest.values) {
      final old = viewed[event.room.id];
      if (old == null || event.originServerTs.isAfter(old.originServerTs)) {
        viewed[event.room.id] = event;
        PersonalPrivacy.observe(event.room, event.eventId);
        if (PersonalPrivacy.policy.allowAutomaticRead) {
          unawaited(PersonalPrivacy.markRead(event.room, event.eventId));
        }
      }
    }
  }

  // ---------------------------------------------------------------------
  // Send routing.

  SendTarget get target {
    final edit = editEvent;
    if (edit != null) {
      return SendTarget(
        conversation: personal.ref(edit.room),
        readUpToEventId: viewed[edit.room.id]?.eventId,
      );
    }
    if (replyEvent == null && _draftTarget != null) return _draftTarget!;
    var recent = _recentRoutable;
    final confirmed = _confirmedOutgoing;
    if (confirmed != null &&
        (recent == null || confirmed.timestamp.isAfter(recent.timestamp))) {
      recent = confirmed;
    }
    final (available, automatic) = _routing;
    final routed = MergedSendRouter.resolve(
      group: group,
      now: DateTime.now(),
      recentEvent: recent,
      override: replyEvent == null ? selectedNetwork : null,
      replyTo: replyEvent == null ? null : personal.source(replyEvent!),
      automatic: automatic,
      available: available,
    );
    return SendTarget(
      conversation: routed.conversation,
      readUpToEventId: viewed[routed.conversation.roomId]?.eventId,
    );
  }

  /// Members that can receive messages now (joined, not shown by another
  /// person) and whether the person routes automatically ("Send messages
  /// via" on the person page). Cached between store and timeline changes;
  /// a cached source that was left meanwhile recomputes it.
  (Set<ConversationRef>, bool) get _routing {
    final cached = _routingCache;
    if (cached != null &&
        cached.$1.every(
          (ref) =>
              personal.client.getRoomById(ref.roomId)?.membership ==
              Membership.join,
        )) {
      return cached;
    }
    final projection = InboxProjection.snapshot(personal);
    return _routingCache = (
      {
        for (final source in projection.sourcesOf(group))
          if (source.sendable) source.member,
      },
      projection.preferencesFor(group.id).routing == PersonRouting.automatic,
    );
  }

  /// The send target room; null when the source is unavailable here.
  Room? get _targetRoom {
    final conversation = target.conversation;
    if (conversation.accountId != personal.client.userID) return null;
    return personal.client.getRoomById(conversation.roomId);
  }

  /// Any loaded or known member room, for chrome when the target is gone.
  Room? get _anyRoom =>
      _targetRoom ??
      timelines.values.firstOrNull?.room ??
      group.members
          .map((m) => personal.client.getRoomById(m.roomId))
          .whereType<Room>()
          .firstOrNull;

  /// A source removed from the person must not stay the send target: the
  /// router refuses non-members (an exception in every build) and a saved
  /// draft target would send outside the person.
  void _dropRemovedSources() {
    final members = group.members;
    if (selectedNetwork != null && !members.contains(selectedNetwork)) {
      selectedNetwork = null;
    }
    final confirmed = _confirmedOutgoing;
    if (confirmed != null && !members.contains(confirmed.source.conversation)) {
      _confirmedOutgoing = null;
    }
    final reply = replyEvent;
    if (reply != null && !members.contains(personal.ref(reply.room))) {
      replyEvent = null;
    }
    final draft = _draftTarget;
    if (draft != null && !members.contains(draft.conversation)) {
      _draftTarget = null;
      if (sendController.text.isNotEmpty) {
        _needsNetworkChoice = true;
        problem =
            'This draft belongs to a source outside this person. Choose a network before sending.';
      }
    }
  }

  void _rememberAccepted(SendTarget target, String eventId, DateTime at) {
    if (!eventId.startsWith(r'$')) return;
    _confirmedOutgoing = MergedEvent<Object?>(
      source: SourceEventRef(
        conversation: target.conversation,
        eventId: eventId,
      ),
      timestamp: at,
      isOutgoing: true,
      value: null,
    );
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  bool _stillHere() =>
      mounted && identical(Matrix.of(context).client, personal.client);

  Future<void> _draft() async {
    if (_needsNetworkChoice || editEvent != null) return;
    final text = sendController.text;
    final frozen = _draftTarget ??= target;
    try {
      await personal.savePersonalDraft(
        'draft:person:${group.id}',
        frozen,
        text,
      );
      _savedDraftText = text;
    } catch (_) {
      _notify('The draft was not synced. Your text remains in the editor.');
    }
  }

  // ---------------------------------------------------------------------
  // ConversationTimelineSource.

  @override
  List<Event>? get conversationEvents =>
      timelines.isEmpty && loading ? null : _rows;

  @override
  Timeline? timelineFor(Event event) => timelines[event.room.id];

  @override
  Room get room => _anyRoom!;

  @override
  Set<String> get conversationRoomIds => timelines.keys.toSet();

  @override
  List<Room> get typingRooms => [for (final t in timelines.values) t.room];

  @override
  ({ChatTheme? theme}) get conversationPalette {
    final projection = InboxProjection.snapshot(personal);
    final person = projection.metadataForEntity('person:${group.id}').theme;
    if (person != null) return (theme: person);
    final room = _anyRoom;
    return (theme: room == null ? null : projection.metadataFor(room).theme);
  }

  @override
  String? get activeThreadId => null;

  @override
  String? get threadLastEventId => null;

  @override
  Set<String> get bigEmojis => ChatController.defaultBigEmojis;

  @override
  bool get canLoadHistory => _hasMore;

  @override
  bool get isLoadingHistory => historyLoading;

  @override
  bool get autoLoadHistory =>
      historyError == null &&
      !historyLoading &&
      PersonalPrivacy.surfaceUnlocked;

  /// Pages only the sources that limit the merged history (the newest
  /// "oldest loaded" event), in parallel, so one long source does not hold
  /// the others back.
  @override
  Future<void> requestHistory([dynamic _]) async {
    if (historyLoading ||
        !PersonalPrivacy.surfaceUnlocked ||
        !_stillHere() ||
        !_hasMore) {
      return;
    }
    final privacyGeneration = PersonalPrivacy.surfaceGeneration;
    final generation = _generation;
    // The merged history is complete only down to the newest "oldest loaded
    // row" of a source with more history; that source (or one without any
    // row yet) is the one to page.
    DateTime? oldestRow(Timeline t) =>
        t.events.lastWhereOrNull(_isRow)?.originServerTs;
    final pageable = [
      for (final t in timelines.values)
        if (t.canRequestHistory) t,
    ];
    DateTime? frontier;
    for (final t in pageable) {
      final oldest = oldestRow(t);
      if (oldest != null && (frontier == null || oldest.isAfter(frontier))) {
        frontier = oldest;
      }
    }
    final sources = [
      for (final t in pageable)
        if (oldestRow(t) == null ||
            frontier == null ||
            !oldestRow(t)!.isBefore(frontier))
          t,
    ];
    if (sources.isEmpty) return;
    setState(() {
      historyLoading = true;
      historyError = null;
      _listRevision++;
    });
    var stalled = false, failed = false;
    await Future.wait(
      sources.map((t) async {
        final before = (
          t.events.length,
          t.room.prev_batch,
          t.events.lastOrNull?.eventId,
        );
        try {
          await t.requestHistory(historyCount: 50);
          _requestKeys(t);
          if (t.canRequestHistory &&
              before ==
                  (
                    t.events.length,
                    t.room.prev_batch,
                    t.events.lastOrNull?.eventId,
                  )) {
            stalled = true;
          }
        } catch (_) {
          failed = true;
        }
      }),
    );
    if (!mounted) return;
    final current =
        generation == _generation &&
        PersonalPrivacy.surfaceGeneration == privacyGeneration &&
        _stillHere();
    setState(() {
      historyLoading = false;
      if (current) {
        historyError = failed
            ? 'Some older history could not load. Retry.'
            : stalled
            ? 'One source did not advance. Retry loading older messages.'
            : null;
      }
      _recomputeMerged();
      _markSeen();
    });
  }

  @override
  bool get canLoadFuture => false;

  @override
  bool get autoLoadFuture => false;

  @override
  bool get isLoadingFuture => false;

  @override
  Future<void> requestFuture({bool quiet = false}) async {}

  @override
  void mentionSender(Event event) =>
      sendController.text += '${event.senderFromMemoryOrFallback.mention} ';

  /// Raw message source: developer options only (CS-23), also when a
  /// deleted or unknown message row is tapped.
  @override
  void showEventInfo(Event event) {
    if (DeveloperOptions.enabled) event.showInfoDialog(context);
  }

  @override
  Future<void> scrollToEventId(
    String eventId, {
    bool highlightEvent = true,
  }) async {
    if (!mounted) return;
    final index = _rows.indexWhere((e) => e.eventId == eventId);
    if (index < 0) {
      // Only reply previews ask for unloaded events; the original lives in
      // the replying message's source, which opens at that event.
      final room = _rows
          .firstWhereOrNull(
            (e) => e.inReplyToEventId(includingFallback: false) == eventId,
          )
          ?.room;
      if (room != null) {
        context.go(
          personSourceChatLocation(group.id, room.id, eventId: eventId),
        );
      }
      return;
    }
    if (highlightEvent) {
      setState(() {
        scrollToEventIdMarker = eventId;
        _listRevision++;
      });
    }
    // Scroll tags carry the row index (the footer is not tagged).
    await scrollController.scrollToIndex(
      index,
      duration: ChatLoomThemes.animationDuration,
      preferPosition: AutoScrollPosition.middle,
    );
    // The landed-on message flashes once (its bubble finishes the flash by
    // itself); clearing the marker keeps later rebuilds from replaying it.
    if (mounted && highlightEvent && scrollToEventIdMarker == eventId) {
      setState(() {
        scrollToEventIdMarker = null;
        _listRevision++;
      });
    }
  }

  @override
  void expandEventsFrom(Event event, bool expand) {}

  @override
  int? findChildIndexCallback(Key key, Map<String, int> thisEventsKeyMap) {
    if (key is! ValueKey) return null;
    final eventId = key.value;
    if (eventId is! String) return null;
    final index = thisEventsKeyMap[eventId];
    // +1: index 0 is the typing/seen footer at the bottom.
    return index == null ? null : index + 1;
  }

  @override
  void Function(String eventId)? get threadOpener => null;

  @override
  String? sourceLabelFor(Event event) =>
      'via ${notionNetworkLabel(PersonalClient.networkOf(event.room))}';

  @override
  bool seriesBoundary(Event event) => _boundaries[_rowKey(event)] ?? false;

  @override
  bool get strictCapabilities => true;

  // ---------------------------------------------------------------------
  // Message actions (reply, edit, delete, copy, forward, retry), one message
  // at a time from its long-press menu.

  void _lockTo(Room room) {
    _draftTarget = SendTarget(
      conversation: personal.ref(room),
      readUpToEventId: viewed[room.id]?.eventId,
    );
  }

  @override
  void replyAction({Event? replyTo}) {
    final event = replyTo;
    if (event == null) return;
    final room = personal.client.getRoomById(event.room.id);
    if (room == null ||
        event.room.client != personal.client ||
        event.redacted ||
        !RoomCapabilities.forFeature(
          BridgeFeature.reply,
          room,
          event: event,
        ).allowed) {
      _notify('Replies are not available for this message in its network.');
      return;
    }
    setState(() {
      if (editEvent != null) {
        sendController.text = _pendingText;
        _pendingText = '';
        editEvent = null;
      }
      replyEvent = event;
      _lockTo(room);
    });
    inputFocus.requestFocus();
    unawaited(_draft());
  }

  bool _canEdit(Event event) =>
      event.senderId == personal.client.userID &&
      ConversationMessageActions.canEditContent(
        event,
        timelineFor(event),
        strict: true,
      );

  /// Own messages the source network can delete for everyone; a sending
  /// one is deleted as soon as it goes through (never a ghost delivery).
  bool _canRedact(Event event) =>
      !event.redacted &&
      event.senderId == personal.client.userID &&
      (event.status.isSending ||
          (event.status.isSent &&
              event.canRedact &&
              ConversationMessageActions.canDeleteForEveryone(
                event,
                strict: true,
              )));

  /// Sent media only: an unsent file is still on this device.
  bool _canSave(Event event) =>
      !event.redacted &&
      event.status.isSent &&
      {
        MessageTypes.Video,
        MessageTypes.Image,
        MessageTypes.Sticker,
        MessageTypes.Audio,
        MessageTypes.File,
      }.contains(event.messageType);

  void editEventAction(Event event) {
    if (!_canEdit(event)) return;
    final timeline = timelineFor(event);
    if (timeline == null) return;
    setState(() {
      _pendingText = sendController.text;
      editEvent = event;
      replyEvent = null;
      sendController.text = event
          .getDisplayEvent(timeline)
          .calcLocalizedBodyFallback(
            MatrixLocals(L10n.of(context)),
            withSenderNamePrefix: false,
            hideReply: true,
          );
      _inputEmpty = sendController.text.isEmpty;
    });
    inputFocus.requestFocus();
  }

  /// ↑ in the empty composer (desktop): the newest own text message that
  /// its network can still edit.
  void _editLastOwnMessage() {
    final last = _rows.firstWhereOrNull(
      (event) =>
          event.type == EventTypes.Message &&
          event.messageType == MessageTypes.Text &&
          event.status.isSent &&
          !event.redacted &&
          _canEdit(event),
    );
    if (last != null) editEventAction(last);
  }

  @override
  void cancelReplyEventAction() {
    setState(() {
      if (editEvent != null) {
        sendController.text = _pendingText;
        _pendingText = '';
        _inputEmpty = sendController.text.isEmpty;
      }
      replyEvent = null;
      editEvent = null;
    });
    unawaited(_draft());
  }

  Event _display(Event event) {
    final timeline = timelineFor(event);
    return timeline == null ? event : event.getDisplayEvent(timeline);
  }

  void _copy(Event event) {
    Clipboard.setData(ClipboardData(text: _display(event).body));
    unawaited(showCopiedNotice(context, L10n.of(context).copiedToClipboard));
  }

  Future<void> _redact(Event event) => MessageDeletions.delete(
    context,
    event,
    timeline: timelineFor(event),
    refresh: () {
      if (mounted) setState(_recomputeMerged);
    },
  );

  /// Removes a message that failed to send.
  Future<void> deleteErrorEventAction(Event event) async {
    if (event.status != EventStatus.error) return;
    try {
      await event.cancelSend();
    } catch (_) {
      _notify('The unsent message could not be removed.');
    }
    if (mounted) setState(() => _listRevision++);
  }

  Future<void> _forward(Event event) async {
    final forward = _display(event);
    if (!RoundMediaPolicy.fromContent(forward.content).canForward) {
      _notify('This message cannot be forwarded.');
      return;
    }
    if (RoundVideoDescriptor.fromContent(forward.content) != null) {
      await TelegramRoundService.of(
        forward.room.client,
      ).showForwardPicker(context, forward);
      return;
    }
    await showForwardSheet(
      context,
      items: [ContentShareItem(forward.content.copy())],
    );
  }

  /// Sends a failed message (and its failed edits) again.
  void sendAgainAction(Event event) {
    if (RoundVideoDescriptor.fromContent(event.content) != null) {
      final txid =
          event.unsigned?.tryGet<String>('transaction_id') ?? event.eventId;
      final match = RegExp(r'^round-([A-Za-z0-9_-]{1,128})$').firstMatch(txid);
      if (match != null) {
        unawaited(
          TelegramRoundService.of(event.room.client)
              .retry(match[1]!, stillCurrent: _stillHere)
              .then<void>((_) {}, onError: (Object _) {}),
        );
      }
      return;
    }
    if (event.status.isError) {
      // Files go through the outgoing media queue (upload shown again).
      unawaited(
        MessageDeliveryActions.sendAgain(event).catchError((Object _) {}),
      );
    }
    final timeline = timelineFor(event);
    if (timeline != null) {
      for (final edit
          in event
              .aggregatedEvents(timeline, RelationshipTypes.edit)
              .where((e) => e.status.isError)) {
        // Outbox edits retry in the outbox; the SDK rethrows only a
        // refusal. Explain it.
        unawaited(
          MessageDeliveryActions.sendAgain(edit).then<void>(
            (_) {},
            onError: (Object error, StackTrace stack) => ErrorReporter.action(
              mounted ? context : null,
              action: ErrorAction.send,
            ).onErrorCallback(error, stack),
          ),
        );
      }
    }
    setState(() => _listRevision++);
  }

  Future<void> _bookmark(Event event) =>
      MessageBookmarks.toggle(context, personal, event);

  void _openSource(Event event) => context.go(
    personSourceChatLocation(group.id, event.room.id, eventId: event.eventId),
  );

  /// The long-press menu of one merged row: the actions its own source
  /// network allows (strict capabilities), plus open-in-source and bookmark.
  @override
  List<ConversationMessageAction> messageActions(
    BuildContext context,
    Event event,
  ) {
    final l10n = L10n.of(context);
    final display = _display(event);
    final failed = event.status.isError || display.status.isError;
    final sent = event.status.isSent;
    return [
      if (failed) ...[
        ConversationMessageAction(
          icon: Icons.send_outlined,
          label: l10n.tryToSendAgain,
          // Through the outbox attempt (same transaction ID), like the
          // bubble's own failure line.
          onSelected: () {
            final timeline = timelineFor(event);
            if (timeline == null) return sendAgainAction(event);
            unawaited(MessageDeliveryActions.retry(context, event, timeline));
          },
        ),
        ConversationMessageAction(
          icon: Icons.delete_forever_outlined,
          label: l10n.delete,
          destructive: true,
          onSelected: () {
            final timeline = timelineFor(event);
            if (timeline == null) {
              unawaited(deleteErrorEventAction(event));
              return;
            }
            unawaited(MessageDeliveryActions.delete(context, event, timeline));
          },
        ),
      ],
      if (ConversationMessageActions.canReply(event, strict: true))
        ConversationMessageAction(
          icon: Icons.reply_rounded,
          label: l10n.reply,
          onSelected: () => replyAction(replyTo: event),
        ),
      if (_canEdit(event))
        ConversationMessageAction(
          icon: Icons.edit_outlined,
          label: l10n.edit,
          onSelected: () => editEventAction(event),
        ),
      if (conversationMessageHasText(display))
        ConversationMessageAction(
          icon: Icons.copy_outlined,
          label: l10n.copy,
          onSelected: () => _copy(event),
        ),
      // FX-20: Telegram's link sheet "Copy link".
      ...messageLinkActions(this.context, display),
      if (conversationMessageSelectable(display))
        ConversationMessageAction(
          icon: Icons.text_fields_rounded,
          label: 'Select text',
          onSelected: () =>
              showConversationTextSelection(this.context, display.body),
        ),
      if (sent &&
          !event.redacted &&
          RoundMediaPolicy.fromContent(display.content).canForward)
        ConversationMessageAction(
          icon: Icons.forward_outlined,
          label: l10n.forward,
          onSelected: () => _forward(event),
        ),
      if (sent)
        ConversationMessageAction(
          icon: Icons.open_in_new_outlined,
          label: 'Open in source chat',
          onSelected: () => _openSource(event),
        ),
      if (MessageBookmarks.canBookmark(event))
        ConversationMessageAction(
          icon: MessageBookmarks.isBookmarked(personal, event)
              ? Icons.bookmark
              : Icons.bookmark_outline,
          label: MessageBookmarks.isBookmarked(personal, event)
              ? 'Remove bookmark'
              : 'Bookmark',
          onSelected: () => _bookmark(event),
        ),
      // Stickers: favourite, view pack; GIFs: save (Telegram).
      ...stickerMessageActions(context, display),
      // Save (gallery/Downloads on Android), Save as…, Copy image (macOS).
      ...mediaExportMenuActions(
        this.context,
        display,
        // View-once media is never saved from ChatLoom (BR-10).
        canSave: _canSave(display) && !isViewLimited(display),
      ),
      // Raw message source: developer options only (CS-23).
      if (DeveloperOptions.enabled)
        ConversationMessageAction(
          icon: Icons.info_outlined,
          label: l10n.messageInfo,
          onSelected: () => showEventInfo(event),
        ),
      if (!failed && _canRedact(event))
        ConversationMessageAction(
          icon: Icons.delete_outlined,
          label: l10n.delete,
          destructive: true,
          onSelected: () => _redact(event),
        ),
    ];
  }

  // ---------------------------------------------------------------------
  // ConversationComposerHost.

  @override
  Client get sendingClient => personal.client;

  @override
  bool get composerEnabled =>
      !sending && !loading && !_needsNetworkChoice && _targetRoom != null;

  @override
  bool get composerBusy => sending;

  @override
  bool get allowsAccountSwitch => false;

  @override
  List<Client?> get currentRoomBundle => [personal.client];

  @override
  void setSendingClient(Client client) {}

  @override
  Widget buildComposerSource(BuildContext context) {
    final channel = target.conversation;
    final missing = _targetRoom == null;
    final locked = replyEvent != null || editEvent != null;
    return ConversationSourceChip(
      network: channel.network,
      label: _needsNetworkChoice
          ? 'Choose source'
          : missing
          ? '${notionNetworkLabel(channel.network)} · unavailable'
          : null,
      hint: _needsNetworkChoice
          ? ConversationSourceHint.choose
          : missing
          ? ConversationSourceHint.unavailable
          : ConversationSourceHint.none,
      locked: locked,
      onPressed: group.members.length > 1 && !sending && !locked
          ? _chooseSource
          : null,
    );
  }

  /// One picker at a time: a second tap before the sheet is up is ignored.
  bool _choosingSource = false;

  Future<void> _chooseSource() async {
    if (_choosingSource || replyEvent != null || editEvent != null || sending) {
      return;
    }
    final frozenGroup = group;
    final frozenReply = replyEvent;
    final wasFocused = inputFocus.hasFocus;
    _choosingSource = true;
    final value = await showConversationSourcePicker(
      context,
      selected: _needsNetworkChoice ? null : target.conversation,
      sources: [
        for (final member in frozenGroup.members)
          if (personal.client.getRoomById(member.roomId) case final room?)
            ConversationSourceOption(
              conversation: member,
              title: room.getLocalizedDisplayname(),
              // Telegram-like: what the choice means, never "Source 2".
              subtitle: [
                if (member.roomId == frozenGroup.defaultRoomId) 'Default',
                ?personSourceActivity(context, room),
              ].join(' · ').nullIfEmpty,
              available:
                  member.accountId == personal.client.userID &&
                  _routing.$1.contains(member) &&
                  room.canSendDefaultMessages,
              unavailableReason: _routing.$1.contains(member)
                  ? 'Sending is not available on this network right now'
                  : 'This chat is no longer part of this conversation',
            )
          else
            ConversationSourceOption(
              conversation: member,
              title: 'Chat no longer available',
              available: false,
              unavailableReason: 'Left or deleted',
            ),
      ],
    ).whenComplete(() => _choosingSource = false);
    // The keyboard stays up across the switch (Telegram, Messenger).
    if (wasFocused && mounted && !inputFocus.hasFocus) {
      inputFocus.requestFocus();
    }
    // Store notifications re-read the person while the picker is open (a new
    // object for the same group); only a change of its sources voids the
    // choice. Dropping it on identity made a tap on a network do nothing.
    if (value == null ||
        !mounted ||
        widget.group.id != frozenGroup.id ||
        !samePersonMembers(widget.group, frozenGroup) ||
        !identical(widget.personal, personal) ||
        !identical(Matrix.of(context).client, personal.client) ||
        replyEvent != frozenReply ||
        replyEvent != null ||
        editEvent != null ||
        sending ||
        !group.members.contains(value) ||
        value.accountId != personal.client.userID) {
      return;
    }
    final room = personal.client.getRoomById(value.roomId);
    if (room == null ||
        room.membership != Membership.join ||
        !room.canSendDefaultMessages) {
      return;
    }
    // Choosing the network already in use changes nothing: no rebuild, no
    // private-store write, no journal publication.
    if (!_needsNetworkChoice &&
        selectedNetwork == value &&
        _draftTarget?.conversation == value) {
      return;
    }
    setState(() {
      selectedNetwork = value;
      _draftTarget = SendTarget(
        conversation: value,
        readUpToEventId: viewed[value.roomId]?.eventId,
      );
      if (_needsNetworkChoice) problem = null;
      _needsNetworkChoice = false;
    });
    // The previous network must not keep showing "typing…".
    if (_typingRoom != null && _typingRoom!.id != value.roomId) _stopTyping();
    await _draft();
  }

  /// The editor hint names the network the next message goes to, so a
  /// switch is confirmed where the user is about to type.
  @override
  String get composerHint {
    if (_needsNetworkChoice || _targetRoom == null) return 'Message…';
    return 'Message via ${notionNetworkLabel(target.conversation.network)}';
  }

  @override
  void emojiPickerAction() {
    if (showEmojiPicker) {
      inputFocus.requestFocus();
    } else {
      inputFocus.unfocus();
    }
    setState(() => showEmojiPicker = !showEmojiPicker);
  }

  @override
  void hideEmojiPicker() => setState(() => showEmojiPicker = false);

  void _inputFocusChanged() {
    if (showEmojiPicker && inputFocus.hasFocus) {
      setState(() => showEmojiPicker = false);
    }
  }

  @override
  void onEmojiSelected(Category? category, Emoji? emoji) {
    if (emoji == null) return;
    final text = sendController.text;
    final selection = sendController.selection;
    final start = selection.baseOffset == -1 ? 0 : selection.baseOffset;
    final newText = text.isEmpty
        ? emoji.emoji
        : text.replaceRange(selection.start, selection.end, emoji.emoji);
    sendController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + emoji.emoji.length),
    );
    onInputBarChanged(sendController.text);
  }

  @override
  void emojiPickerBackspace() {
    sendController
      ..text = sendController.text.characters.skipLast(1).toString()
      ..selection = TextSelection.fromPosition(
        TextPosition(offset: sendController.text.length),
      );
    onInputBarChanged(sendController.text);
  }

  /// Typing rebuilds only the composer, and only when the field flips
  /// between empty and non-empty (send vs. record button).
  @override
  void onInputBarChanged(String text) {
    if (_inputEmpty != text.isEmpty) {
      setState(() => _inputEmpty = text.isEmpty);
    }
    if (editEvent == null) {
      _draftTarget ??= target;
      _draftTimer?.cancel();
      _draftTimer = Timer(const Duration(milliseconds: 500), _draft);
    }
    _typing(text.isNotEmpty);
  }

  /// Typing notifications follow the private policy, like ordinary chats.
  void _typing(bool typing) {
    final room = _targetRoom;
    if (!PersonalPrivacy.policy.allowTyping || room == null) return;
    if (!typing) {
      _stopTyping();
      return;
    }
    final sameRoom = identical(_typingRoom, room);
    if (!sameRoom) _stopTyping();
    _typingCoolDown?.cancel();
    _typingCoolDown = Timer(const Duration(seconds: 2), _stopTyping);
    if (sameRoom) return;
    _typingRoom = room;
    _typingTimeout = Timer(const Duration(seconds: 30), () {
      _typingTimeout = null;
      _typingRoom = null;
    });
    PersonalPrivacy.setTyping(
      room,
      true,
      timeout: const Duration(seconds: 30).inMilliseconds,
    );
  }

  void _stopTyping() {
    _typingCoolDown?.cancel();
    _typingCoolDown = null;
    _typingTimeout?.cancel();
    _typingTimeout = null;
    final room = _typingRoom;
    _typingRoom = null;
    if (room != null) PersonalPrivacy.setTyping(room, false);
  }

  @override
  void onInputBarSubmitted(String _) {
    final value = sendController.value;
    if (value.composing.isValid && !value.composing.isCollapsed) return;
    send();
    inputFocus.requestFocus();
  }

  /// Telegram/Messenger send (see `ChatController._sendPersonal`): the
  /// composer empties once the outbox persisted the message, before any
  /// network I/O, and is free for the next message; the source's local echo
  /// shows the network result with Retry. Text stays only when the outbox
  /// could not persist it.
  @override
  Future<void> send() async {
    if (!composerEnabled ||
        sendController.text.trim().isEmpty ||
        !PersonalPrivacy.surfaceUnlocked)
      return;
    final frozen = target;
    final text = sendController.text;
    final replyAtSend = replyEvent;
    final editAtSend = editEvent;
    final privacyGeneration = PersonalPrivacy.surfaceGeneration;
    final draftKey = 'draft:person:${group.id}';
    final sourceRoom = personal.client.getRoomById(frozen.conversation.roomId);
    // Longer than the source network takes: offered as several messages
    // (BR-05).
    final toSend = sourceRoom == null
        ? text
        : _longText.prepare(
            context,
            sourceRoom,
            text,
            editing: editAtSend != null,
            command: false,
            resend: () => unawaited(send()),
          );
    if (toSend == null) return;
    final sent = _MergedSent(
      target: frozen,
      draftKey: draftKey,
      text: toSend,
      reply: replyAtSend,
      edit: editAtSend,
      pendingText: _pendingText,
    );
    bool activeAccount() =>
        _stillHere() && draftKey == 'draft:person:${group.id}';
    // The text, not the whole editing value: an IME that finishes its
    // composing region on the tap does not change the message.
    bool consumeOriginal() =>
        activeAccount() &&
        PersonalPrivacy.surfaceUnlocked &&
        PersonalPrivacy.surfaceGeneration == privacyGeneration &&
        sendController.text == text &&
        identical(replyEvent, replyAtSend) &&
        identical(editEvent, editAtSend) &&
        target.conversation == frozen.conversation;
    _draftTimer?.cancel();
    final room = personal.client.getRoomById(frozen.conversation.roomId);
    if (room == null || !room.canSendDefaultMessages) {
      _notify('The selected source is unavailable. Choose a network manually.');
      return;
    }
    if (editAtSend != null && !_canEdit(editAtSend)) {
      _notify('Editing is not available for this message in its network.');
      return;
    }
    setState(() => sending = true);
    // Tap → durable → bubble → server ack (`send.*` probe points).
    final probe = PersonalPerformanceProbe.span('send');
    final durable = Completer<void>();
    Future<bool>? draft;
    Future<ImmediateSendResult>? outcome;
    try {
      final proceed = await showTrustUserInRoomDialog(context, room);
      if (!proceed || !consumeOriginal()) return;
      _stopTyping();
      outcome = PersonalPerformanceProbe.runInSpan<Future<ImmediateSendResult>>(
        probe,
        () => personal.sendImmediate(
          room,
          toSend,
          replyTo: replyAtSend,
          editEventId: editAtSend?.eventId,
          onDurable: (attempt) {
            probe.mark('durable');
            final saved = draft = _consumeSent(sent);
            // The draft no longer holds the text: an identical message typed
            // later is a new one, never this attempt resumed.
            unawaited(
              saved.then((stored) async {
                if (stored) {
                  await personal.markImmediateConsumed(attempt.actionId);
                }
              }),
            );
            if (!durable.isCompleted) durable.complete();
          },
        ),
      );
      unawaited(
        outcome.then((result) {
          if (result.state == ImmediateSendState.accepted) {
            probe.finish('acked');
          }
        }, onError: (Object _) {}),
      );
      // Free the composer as soon as the message is durable.
      await Future.any<void>([
        durable.future,
        outcome.then<void>((_) {}, onError: (Object _) {}),
      ]);
    } catch (_) {
      _notify(
        'Sending was not confirmed. Your draft is preserved. Check the source before retrying.',
      );
    } finally {
      if (mounted && sending) setState(() => sending = false);
    }
    final pending = outcome;
    if (pending != null) {
      unawaited(_finishSend(sent, pending, () => draft));
    }
    // The next part of a split text, once this one is durable.
    _longText.continueWith(sendController.text, (rest) {
      if (!_stillHere() || target.conversation != frozen.conversation) return;
      setState(() {
        sendController.value = TextEditingValue(
          text: rest,
          selection: TextSelection.collapsed(offset: rest.length),
        );
        _inputEmpty = rest.isEmpty;
      });
      unawaited(send());
    });
  }

  /// Empties the composer after the outbox persisted [sent] (keeping only
  /// text typed after the tap), ends its reply/edit, frees the send button
  /// and saves the remaining draft. Returns whether the draft was saved.
  Future<bool> _consumeSent(_MergedSent sent) {
    _draftTimer?.cancel();
    if (_stillHere() && sent.draftKey == 'draft:person:${group.id}') {
      final current = sendController.text;
      final edit = sent.edit;
      final remaining = current == sent.text
          ? (edit != null ? sent.pendingText : '')
          : edit == null && current.startsWith(sent.text)
          ? current.substring(sent.text.length)
          : null;
      setState(() {
        if (remaining != null) {
          sendController.value = TextEditingValue(
            text: remaining,
            selection: TextSelection.collapsed(offset: remaining.length),
          );
        }
        if (identical(replyEvent, sent.reply)) replyEvent = null;
        if (edit != null && identical(editEvent, edit)) {
          editEvent = null;
          _pendingText = '';
        }
        _inputEmpty = sendController.text.isEmpty;
        if (sendController.text.isEmpty) _draftTarget = null;
        sending = false;
      });
      // Telegram: sending brings you to your message.
      if (_scrolledUp && scrollController.hasClients) {
        unawaited(_jumpToLatest());
      }
    }
    return _persistSentDraft(sent.draftKey);
  }

  /// Saves the editor's text as the person's draft until it is stable.
  Future<bool> _persistSentDraft(String draftKey) async {
    bool here() => _stillHere() && draftKey == 'draft:person:${group.id}';
    String current() => editEvent != null ? _pendingText : sendController.text;
    try {
      while (here()) {
        final text = current();
        await personal.savePersonalDraft(
          draftKey,
          _draftTarget ?? target,
          text,
        );
        _savedDraftText = text;
        if (!here() || current() == text) break;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _finishSend(
    _MergedSent sent,
    Future<ImmediateSendResult> outcome,
    Future<bool>? Function() draft,
  ) async {
    ImmediateSendResult? result;
    try {
      result = await outcome;
    } catch (_) {}
    var drafted = draft();
    if (drafted == null) {
      if (result?.state != ImmediateSendState.accepted) {
        // Never durable: nothing was sent and the text never left.
        _notify(
          result == null
              ? 'Sending was not confirmed. Your draft is preserved. Check the source before retrying.'
              : 'The message could not be saved for sending, so it was not sent. Your text is kept.',
        );
        return;
      }
      // An attempt of an earlier session had already delivered it.
      drafted = _consumeSent(sent);
    }
    final stored = await drafted;
    if (result == null) return;
    if (result.state == ImmediateSendState.accepted) {
      if (mounted && result.eventId != null && sent.edit == null) {
        _rememberAccepted(sent.target, result.eventId!, DateTime.now());
      }
      // The bubble already shows "Sent"; local bookkeeping the user cannot
      // act on is logged, not shown (CS-12).
      if (!stored) {
        Logs().w('[Chat] sent_draft_not_updated');
        return;
      }
      try {
        await personal.completeImmediate(result.actionId);
      } catch (error) {
        logBackgroundError('send_state_retained', error);
        // Still never resumed by an identical later message.
        await personal.markImmediateConsumed(result.actionId);
      }
      return;
    }
    // The source's bubble shows "Not sent · Tap to retry".
    if (personal.localEchoShown(result.transactionId)) return;
    // Rejected before it reached a timeline: nothing was sent.
    unawaited(
      personal.discardImmediate(result.actionId).catchError((Object _) {}),
    );
    _giveBack(sent, switch (result.errorCode) {
      'bridge_unavailable' =>
        'This network does not accept this message right now.',
      'replyUnavailable' => 'The message you replied to is unavailable.',
      'sourceUnavailable' => 'This source is unavailable.',
      _ => 'The message did not reach the server.',
    });
  }

  /// A message that failed before it had a bubble returns to an empty
  /// composer; text the user is typing is never overwritten silently.
  void _giveBack(_MergedSent sent, String reason) {
    if (!_stillHere() || sent.draftKey != 'draft:person:${group.id}') return;
    bool quiet() {
      final current = sendController.text;
      return (current.isEmpty ||
              (sent.edit != null && current == sent.pendingText)) &&
          replyEvent == null &&
          editEvent == null;
    }

    void restore() {
      if (!_stillHere()) return;
      final calm = quiet();
      final current = sendController.text;
      setState(() {
        final value = calm || current.isEmpty
            ? sent.text
            : '${sent.text}\n$current';
        if (calm) {
          replyEvent = sent.reply;
          if (sent.edit != null) {
            _pendingText = current;
            editEvent = sent.edit;
          } else if (sent.reply == null) {
            _draftTarget = sent.target;
          }
        }
        sendController.value = TextEditingValue(
          text: value,
          selection: TextSelection.collapsed(offset: value.length),
        );
        _inputEmpty = sendController.text.isEmpty;
      });
      unawaited(_persistSentDraft(sent.draftKey));
    }

    if (quiet()) {
      restore();
      _notify('Not sent: $reason It is back in the composer.');
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Not sent: $reason'),
        action: SnackBarAction(label: 'Restore', onPressed: restore),
      ),
    );
  }

  /// Attachments use the same dialog as every other chat ([SendFileDialog]:
  /// preview, caption, editing, compression, a bubble per file), bound to
  /// the frozen source: the bridge's media limits are checked first and a
  /// reply stays with a message of the same source. [pick] runs after the
  /// draft is saved (a picker may take the app to the background).
  Future<void> _attachMedia(
    Future<List<XFile>> Function() pick, {
    bool asFiles = false,
  }) async {
    if (sending || loading || _needsNetworkChoice) return;
    final frozen = target;
    final room = personal.client.getRoomById(frozen.conversation.roomId);
    final oldText = sendController.text;
    final sourceReply = replyEvent;
    _draftTimer?.cancel();
    final key = 'draft:person:${group.id}';
    var mediaAccepted = false;
    setState(() => sending = true);
    try {
      if (room == null ||
          frozen.conversation.accountId != personal.client.userID ||
          !room.canSendDefaultMessages) {
        throw const PersonalCapabilityUnavailable(
          'The selected source is unavailable. Choose a network before attaching a file.',
        );
      }
      if (sourceReply != null &&
          (sourceReply.room.id != room.id ||
              sourceReply.room.client != personal.client ||
              sourceReply.redacted)) {
        throw const PersonalCapabilityUnavailable(
          'An attachment can only reply to a message in the selected network.',
        );
      }
      if (_savedDraftText != oldText &&
          (_savedDraftText != null || oldText.isNotEmpty)) {
        await personal.savePersonalDraft(key, frozen, oldText);
        _savedDraftText = oldText;
      }
      final current = personal.values[key];
      final baseline = current == null ? null : jsonDecode(jsonEncode(current));
      bool isCurrent() =>
          _stillHere() &&
          target.conversation == frozen.conversation &&
          identical(replyEvent, sourceReply);
      final files = await pick();
      if (!mounted || files.isEmpty || !isCurrent()) return;
      final result = await showSendFileDialog(
        context,
        SendFileDialog(
          files: files,
          room: room,
          outerContext: context,
          threadRootEventId: null,
          threadLastEventId: null,
          replyTo: sourceReply,
          initialCaption: oldText,
          initialCompress: !asFiles,
          composeContext: FrozenAttachmentContext(
            room: room,
            replyTo: sourceReply,
            isCurrent: isCurrent,
          ),
          preflight: (context, files, caption) => mergedAttachmentPreflight(
            context,
            room: room,
            replyTo: sourceReply,
            files: files,
            caption: caption,
          ),
          onAccepted: (id, at) {
            if (mounted) _rememberAccepted(frozen, id, at);
          },
        ),
      );
      if (!mounted || result == null) return;
      mediaAccepted = true;
      // A later draft or a changed caption belongs to the user. Clear only the
      // exact captured text after all file sends were accepted.
      if (result.caption == oldText.trim() &&
          sendController.text == oldText &&
          baseline is Map &&
          baseline['text'] == oldText &&
          const DeepCollectionEquality().equals(
            personal.values[key],
            baseline,
          ) &&
          !personal.conflicts.containsKey(key)) {
        await personal.savePersonalDraft(key, frozen, '');
        if (sendController.text == oldText) {
          sendController.clear();
          _inputEmpty = true;
          _savedDraftText = '';
          _draftTarget = null;
        } else {
          await personal.savePersonalDraft(key, frozen, sendController.text);
        }
      }
      if (replyEvent == sourceReply) replyEvent = null;
    } on PersonalCapabilityUnavailable catch (error) {
      _notify(error.reason);
    } catch (error) {
      // Accepted attachments show their own bubbles (CS-12).
      if (mediaAccepted) {
        logBackgroundError('attachment_draft_retained', error);
      } else {
        _notify('Couldn’t send the attachments. Your draft is kept.');
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  /// ⌘V (desktop): files or an image open the attachment dialog for the
  /// selected source, like an ordinary chat; text is pasted at the caret
  /// (also while a send is in flight).
  Future<void> _pasteFromClipboard() async {
    final editorValue = sendController.value;
    final media = composerEnabled ? await readClipboardMedia() : null;
    if (!mounted) return;
    if (media != null) {
      await _attachMedia(() async => media);
      return;
    }
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || !mounted || sendController.value != editorValue) {
      return;
    }
    onInputBarChanged(insertComposerText(sendController, text));
  }

  /// Keeps the app lock from treating a system picker as leaving the app.
  Future<T> _picking<T>(Future<T> picker) =>
      AppLock.of(context).pauseWhile(picker);

  @override
  Future<void> sendImageFromClipBoard(Uint8List? image) async {
    if (image == null || !composerEnabled) return;
    await _attachMedia(
      () async => [
        XFile.fromData(
          image,
          name: 'pasted-image.png',
          path: 'pasted-image.png',
          mimeType: 'image/png',
        ),
      ],
    );
  }

  @override
  void onAddPopupMenuButtonSelected(AddPopupMenuActions choice) {
    final room = _targetRoom;
    if (room == null || !composerEnabled) return;
    switch (choice) {
      case AddPopupMenuActions.gallery:
        unawaited(
          // The system photo picker on phones, media files elsewhere.
          _attachMedia(() => selectPhotosOrVideos(context)),
        );
      case AddPopupMenuActions.file:
        unawaited(
          // "File" sends photos and videos as the original file (MD-02).
          _attachMedia(
            () => selectFiles(context, allowMultiple: true),
            asFiles: true,
          ),
        );
      case AddPopupMenuActions.poll:
        unawaited(StartPollBottomSheet.show(context, room));
      case AddPopupMenuActions.photoCamera:
        inputFocus.unfocus();
        unawaited(
          _attachMedia(() async {
            final file = await _picking(
              ImagePicker().pickImage(source: ImageSource.camera),
            );
            return [?file];
          }),
        );
      case AddPopupMenuActions.videoCamera:
        inputFocus.unfocus();
        unawaited(
          _attachMedia(() async {
            final file = await _picking(
              ImagePicker().pickVideo(
                source: ImageSource.camera,
                maxDuration: const Duration(minutes: 1),
              ),
            );
            return [?file];
          }),
        );
      case AddPopupMenuActions.location:
        showNotionCustomDialog<void>(
          context: context,
          builder: (c) => SendLocationDialog(room: room),
        );
      case AddPopupMenuActions.roundVideoSilent:
        final gesture = RoundCaptureGestureController(held: true)..lock();
        recordRound(gesture, silent: true).whenComplete(gesture.dispose);
    }
  }

  @override
  Future<bool> onVoiceMessageSend(
    String path,
    int duration,
    List<int> waveform,
    String fileName, {
    Future<bool> Function(Room)? confirmTrust,
    Future<Uint8List?> Function(String)? readRecording,
  }) {
    final frozen = target;
    final target0 = personal.client.getRoomById(frozen.conversation.roomId);
    if (target0 == null || _needsNetworkChoice || editEvent != null) {
      return Future.value(false);
    }
    final reply = replyEvent;
    return _voiceSender.send(
      context: context,
      target: target0,
      reply: reply,
      thread: null,
      lastThreadEvent: null,
      composerUnchanged: () =>
          mounted &&
          identical(Matrix.of(context).client, personal.client) &&
          target.conversation == frozen.conversation &&
          identical(replyEvent, reply) &&
          editEvent == null,
      path: path,
      duration: duration,
      waveform: waveform,
      fileName: fileName,
      confirmTrust: confirmTrust,
      readRecording: readRecording,
      onAccepted: () => setState(() {
        if (identical(replyEvent, reply)) replyEvent = null;
      }),
    );
  }

  @override
  RoundAvailability get roundAvailability {
    final room = _targetRoom;
    if (room == null || !PlatformInfos.supportsRoundCapture) {
      return RoundAvailability.fromReport(
        const RoundGateReport(RoundGateCode.notJoined),
      );
    }
    return RoundAvailability.of(room);
  }

  @override
  bool get canRecordRoundSilently {
    final room = _targetRoom;
    return room != null &&
        PlatformInfos.supportsRoundCapture &&
        roundAvailability.canRecord &&
        TelegramRoomBinding.of(
              room,
            )?.capabilities(room).extension.operation('silent_send').allowed ==
            true;
  }

  @override
  Future<void> recordRound(
    RoundCaptureGestureController gesture, {
    bool silent = false,
  }) async {
    if (sending || loading || _needsNetworkChoice || editEvent != null) return;
    final frozen = target;
    final sourceRoom = personal.client.getRoomById(frozen.conversation.roomId);
    final sourceReply = replyEvent;
    if (sourceRoom == null) return;
    final availability = RoundAvailability.of(sourceRoom);
    if (!availability.canRecord) {
      _notify(availability.message);
      return;
    }
    try {
      final result = await TelegramRoundService.of(personal.client)
          .captureAndSend(
            context,
            sourceRoom,
            reply: sourceReply,
            readUpToEventId: frozen.readUpToEventId,
            gesture: gesture,
            silent: silent,
            stillCurrent: () =>
                mounted &&
                target.conversation == frozen.conversation &&
                identical(Matrix.of(context).client, personal.client),
            onAccepted: (eventId) {
              if (mounted) _rememberAccepted(frozen, eventId, DateTime.now());
            },
          );
      if (!mounted || result == null) return;
      // The round's bubble is in the chat and shows its own delivery
      // (sending, sent, or "Not sent · Tap to retry"); no notice.
      if (identical(replyEvent, sourceReply)) {
        setState(() => replyEvent = null);
      }
    } catch (error) {
      _notify(roundFailureMessage(error));
    }
  }

  // ---------------------------------------------------------------------
  // Header actions.

  Future<void> _quickAction(String action, {BuildContext? anchor}) async {
    if (action == 'mute' || action == 'unmute') {
      await runConversationMute(
        anchor != null && anchor.mounted ? anchor : context,
        personal,
        'person:${group.id}',
        unmute: action == 'unmute',
        isCurrent: _stillHere,
      );
      return;
    }
    if (action == 'read') {
      await _allRead();
      return;
    }
    if (action == 'source.details') {
      await showPersonPage(context, personal: personal, group: group);
      return;
    }
    if (action == 'source.search') {
      // Telegram: the conversation searches in place.
      _openSearch();
      return;
    }
    if (action == 'schedule') {
      await _schedule();
      return;
    }
    if (action == 'reminder') {
      // A reminder is source-bound; the user must choose, even for a person.
      final source = await showNotionSheet<Room>(
        context: context,
        title: 'Choose reminder source',
        builder: (context) => ListView(
          shrinkWrap: true,
          children: [
            for (final timeline in timelines.values)
              NotionListRow(
                title: timeline.room.getLocalizedDisplayname(),
                subtitle: notionNetworkLabel(
                  PersonalClient.networkOf(timeline.room),
                ),
                onTap: () => Navigator.pop(context, timeline.room),
              ),
          ],
        ),
      );
      if (source == null || !_stillHere() || !mounted) return;
      try {
        await requestConversationReminder(
          context,
          personal,
          source,
          isCurrent: () =>
              _stillHere() && group.members.any((m) => m.roomId == source.id),
        );
      } catch (_) {
        _notify('The reminder could not be saved. Retry from this source.');
      }
    }
  }

  /// The person's chats a read marker can go to: joined and part of this
  /// conversation. A left or claimed chat (FT-01) is skipped, so it never
  /// turns "Mark as read" into a failure.
  List<Room> get _readSources => [
    for (final member in group.members)
      if (!_inactive.contains(member.roomId))
        if (personal.client.getRoomById(member.roomId) case final Room room
            when room.membership == Membership.join)
          room,
  ];

  Future<void> _allRead() async {
    // Same targets as the read button (never a local echo); a source with
    // nothing to mark is skipped. The receipt follows the receipt setting.
    final targets = conversationReadTargets(
      _readSources,
      loaded: (room) => timelines[room.id]?.events ?? const [],
    );
    // The user asked for this: say so and offer the retry (CS-13).
    if (await markConversationRead(targets) > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Couldn’t mark every source as read.'),
          action: SnackBarAction(label: 'Retry', onPressed: _allRead),
        ),
      );
    }
  }

  /// Send later through the frozen source (the shared sheet: time presets,
  /// inline validation, then the text or an attachment).
  Future<void> _schedule() async {
    if (sending || _needsNetworkChoice || editEvent != null) return;
    final frozen = target;
    final text = sendController.text;
    final frozenReply = replyEvent;
    final privacyGeneration = PersonalPrivacy.surfaceGeneration;
    bool sameComposerContext() =>
        _stillHere() &&
        target.conversation == frozen.conversation &&
        identical(replyEvent, frozenReply);
    setState(() => sending = true);
    try {
      await runSendLater(
        context,
        personal: personal,
        text: text,
        chatName:
            InboxProjection.snapshot(
              personal,
            ).metadataForEntity('person:${group.id}').nickname ??
            group.name,
        freeze: () {
          final room = personal.client.getRoomById(frozen.conversation.roomId);
          if (room == null) {
            throw SendLaterProblem('The selected source is unavailable.');
          }
          return FrozenScheduledComposer.capture(
            room: room,
            target: frozen,
            reply: frozenReply,
            isCurrent: () =>
                _stillHere() &&
                PersonalPrivacy.surfaceUnlocked &&
                PersonalPrivacy.surfaceGeneration == privacyGeneration &&
                target.conversation == frozen.conversation &&
                identical(replyEvent, frozenReply),
          );
        },
        onTextScheduled: () async {
          if (sendController.text != text || !sameComposerContext()) return;
          await personal.savePersonalDraft(
            'draft:person:${group.id}',
            frozen,
            '',
          );
          if (sendController.text == text && sameComposerContext()) {
            sendController.clear();
            _inputEmpty = true;
            replyEvent = null;
            _draftTarget = null;
          } else if (mounted) {
            await _draft();
          }
        },
      );
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Future<void> composerSendLater() => _schedule();

  @override
  Future<void> composerRemindMe() => _quickAction('reminder');

  /// Only the list's spacer and the jump button follow the composer's
  /// height; the page and the rows do not rebuild while it animates.
  void _updateInputBarHeight() {
    if (!mounted) return;
    final box = inputBarKey.currentContext?.findRenderObject();
    // Not laid out yet (loading): measure again on the next build.
    if (box is RenderBox && box.hasSize) composerInset.value = box.size.height;
  }

  /// The jump button and sending: glide when near, otherwise jump to one
  /// screen above the newest message and glide from there.
  Future<void> _jumpToLatest() async {
    if (!scrollController.hasClients) return;
    final position = scrollController.position;
    if (position.pixels <= 0 || ConversationMotion.reduced(context)) {
      scrollController.jumpTo(0);
      return;
    }
    final viewport = position.viewportDimension;
    if (position.pixels > 2 * viewport) scrollController.jumpTo(viewport);
    await scrollController.animateTo(
      0,
      duration: NotionMotion.long,
      curve: NotionMotion.emphasized,
    );
  }

  NetworkRejectionWatcher? _rejections;

  @override
  void dispose() {
    _rejections?.dispose();
    MacDesktopCommands.unbindChat(this);
    ConversationJumpTargets.unregister(this);
    _search?.removeListener(_searchChanged);
    _search?.dispose();
    _hold.dispose();
    _mentionsHandled.dispose();
    _generation++;
    if (_savedDraftText != sendController.text && editEvent == null) {
      try {
        final frozen = _draftTarget ?? target;
        unawaited(
          personal
              .savePersonalDraft(
                'draft:person:${group.id}',
                frozen,
                sendController.text,
              )
              .catchError((Object _) {}),
        );
      } catch (_) {}
    }
    _stopTyping();
    for (final t in timelines.values) {
      t.cancelSubscriptions();
    }
    _draftTimer?.cancel();
    _scrollScanTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    personal.removeListener(_personalChanged);
    inputFocus.removeListener(_inputFocusChanged);
    inputFocus.dispose();
    sendController.dispose();
    scrollController.dispose();
    composerInset.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Build.

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Size notifications report changes only: measure the first layout.
    if (composerInset.value == null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _updateInputBarHeight(),
      );
    }
    final columns = ChatLoomThemes.isColumnMode(context);
    final projection = InboxProjection.snapshot(personal);
    // One name everywhere (inbox, header, person page, People settings).
    final displayName = projection.personName(group);
    final anyRoom = _anyRoom;
    final background = conversationPalette.theme?.backgroundColor;
    final notice = problem;
    final wallpaper = personal.client.applicationAccountConfig;
    final retry = unavailable.isNotEmpty || timelines.isEmpty;
    final manage = !retry && _inactive.isNotEmpty;
    // Brand-new undecryptable rows get a moment for a key on its way, as in
    // ordinary chats; the fix sheet retries each row in its own source.
    final lockedCount = UndecryptableMessages.settledCount(_locked);
    final hintHeight = lockedCount > 0
        ? UndecryptableChatHint.heightFor(MediaQuery.textScalerOf(context))
        : 0.0;
    final bottomHeight =
        (notice == null ? 0.0 : ChatAppBarListTile.fixedHeight) + hintHeight;
    final searching = _searching;
    final page = PopScope(
      canPop:
          !searching &&
          !showEmojiPicker &&
          // Telegram: back cancels a reply or edit before leaving the chat.
          replyEvent == null &&
          editEvent == null,
      onPopInvokedWithResult: (pop, _) {
        if (pop) return;
        if (searching) {
          _search?.close();
        } else if (showEmojiPicker) {
          // Telegram: back closes the panel without opening the keyboard.
          hideEmojiPicker();
        } else if (replyEvent != null || editEvent != null) {
          cancelReplyEventAction();
        }
      },
      child: Scaffold(
        backgroundColor: background == null ? null : Color(background),
        // Messages scroll under the glass header (DESIGN.md "Glass").
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          flexibleSpace: const NotionGlassBar(hairlineBottom: true),
          toolbarHeight: NotionTokens.headerHeight,
          elevation: 0,
          scrolledUnderElevation: 0,
          // UI-20: the glass bar draws its own translucent hairline (like
          // the dock) instead of an opaque AppBar border.
          automaticallyImplyLeading: false,
          leading: searching
              ? IconButton(
                  icon: const Icon(Icons.chevron_left),
                  tooltip: 'Close search',
                  onPressed: () => _search?.close(),
                )
              : columns
              ? null
              : NotionIconButton(
                  icon: Icons.chevron_left,
                  label: 'Back',
                  onPressed: () => Navigator.maybePop(context),
                ),
          titleSpacing: columns && !searching ? NotionSpace.xl : 0,
          title: searching
              ? ConversationSearchField(search: _searchController)
              : ConversationActivityBuilder(
                  client: personal.client,
                  rooms: typingRooms,
                  builder: (context, activity) => NotionCompactChatHeader(
                    avatar: ConversationActivityAvatar(
                      activity: activity,
                      child: personalConversationAvatar(
                        personal,
                        entityId: 'person:${group.id}',
                        avatar: projection.avatarForGroup(group),
                        name: displayName,
                        size: NotionSize.avatarSm,
                      ),
                    ),
                    name: displayName,
                    status: ConversationActivityStatus(
                      client: personal.client,
                      rooms: typingRooms,
                      activity: activity,
                      sourceLabels: true,
                    ),
                    onDetails: () => showPersonPage(
                      context,
                      personal: personal,
                      group: group,
                    ),
                  ),
                ),
          actions: [
            if (!searching)
              Builder(
                builder: (anchor) => NotionMenuButton<String>(
                  label: 'Conversation actions',
                  icon: Icons.more_horiz,
                  alignEnd: true,
                  entries: () => conversationQuickActions(
                    merged: true,
                    editing: editEvent != null,
                    mute: conversationMuteState(
                      context,
                      personal,
                      'person:${group.id}',
                    ),
                  ),
                  onSelected: (action) => _quickAction(action, anchor: anchor),
                ),
              ),
          ],
          bottom: bottomHeight == 0
              ? null
              : PreferredSize(
                  preferredSize: Size.fromHeight(bottomHeight),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (notice != null)
                        ChatAppBarListTile(
                          leading: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: NotionSpace.md,
                            ),
                            child: Icon(
                              Icons.info_outline,
                              size: NotionSize.iconSm,
                            ),
                          ),
                          title: notice,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (retry)
                                TextButton(
                                  onPressed: loading ? null : _load,
                                  child: const Text('Retry loading'),
                                ),
                              if (manage)
                                TextButton(
                                  onPressed: () => showPersonPage(
                                    context,
                                    personal: personal,
                                    group: group,
                                  ),
                                  child: const Text('Manage'),
                                ),
                              IconButton(
                                icon: const Icon(Icons.close),
                                tooltip: L10n.of(context).close,
                                onPressed: () => setState(() => problem = null),
                              ),
                            ],
                          ),
                        ),
                      if (lockedCount > 0)
                        UndecryptableChatHint(
                          count: lockedCount,
                          onFix: () => showUndecryptableFixSheet(
                            context,
                            client: personal.client,
                            events: _locked,
                          ),
                        ),
                    ],
                  ),
                ),
        ),
        body: anyRoom == null
            ? loading
                  ? const ConversationTimelineSkeleton()
                  : _inactive.length == group.members.length
                  ? NotionEmptyState(
                      icon: Icons.link_off,
                      title: 'None of these chats is available',
                      message:
                          'They were left or deleted. Replace them with the new chats of this person, or unmerge.',
                      action: NotionButton(
                        label: 'Manage chats',
                        onPressed: () => showPersonPage(
                          context,
                          personal: personal,
                          group: group,
                        ),
                      ),
                    )
                  : NotionEmptyState(
                      icon: Icons.cloud_off_outlined,
                      title: 'No source of this conversation is available',
                      message:
                          'The source chats may still be syncing or belong to another account.',
                      action: NotionButton(
                        label: 'Retry loading',
                        onPressed: _load,
                      ),
                    )
            : NotificationListener<SizeChangedLayoutNotification>(
                onNotification: (_) {
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => _updateInputBarHeight(),
                  );
                  return true;
                },
                child: SafeArea(
                  top: false,
                  child: Stack(
                    children: [
                      if (wallpaper.wallpaperUrl != null)
                        ChatWallpaper(
                          uri: wallpaper.wallpaperUrl!,
                          opacity: wallpaper.wallpaperOpacity ?? 0.5,
                          blur: wallpaper.wallpaperBlur ?? 0.0,
                        ),
                      // Composer keystrokes, notices and send state rebuild
                      // this page; the gate hands back the previous list
                      // subtree unless something the rows render changed.
                      _MergedListGate(
                        revision: (_listRevision, anyRoom.id, theme),
                        child: ChatEventList(controller: this, hold: _hold),
                      ),
                      // The send target's bridge (merged chats send per source).
                      ChatBridgeNotice(room: room),
                      if (searching)
                        Positioned.fill(
                          child: ConversationSearchResults(
                            search: _searchController,
                            bottomInset: composerInset,
                            sourceLabel: sourceLabelFor,
                          ),
                        ),
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: SizeChangedLayoutNotifier(
                          child: NotionGlassBar(
                            key: inputBarKey,
                            alignment: Alignment.center,
                            child: Container(
                              margin: EdgeInsets.all(
                                columns ? NotionSpace.lg : NotionSpace.md,
                              ),
                              constraints: const BoxConstraints(
                                maxWidth: ChatLoomThemes.maxTimelineWidth,
                              ),
                              child: ConversationSearchComposerSwitch(
                                searching: searching,
                                bar: (context) => ConversationSearchBar(
                                  search: _searchController,
                                  onPickDate: pickJumpDate,
                                ),
                                composer: ConversationTint(
                                  color: theme.colorScheme.surfaceContainer,
                                  borderRadius: NotionRadius.mdAll,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ReplyDisplay(this),
                                      ChatInputRow(this),
                                      ChatEmojiPicker(this),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      // Above the measured composer (reply preview
                      // included), never over its close button.
                      PositionedDirectional(
                        end: 0,
                        bottom: 0,
                        child: ConversationJumpButtonSlot(
                          composerInset: composerInset,
                          endInset:
                              (columns ? NotionSpace.lg : NotionSpace.md) +
                              NotionSpace.xs,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              ConversationMentionButton(
                                rooms: _readSources,
                                handled: _mentionsHandled,
                                onPressed: () => unawaited(_jumpToMention()),
                              ),
                              ConversationJumpButton(
                                visible: _scrolledUp,
                                count: _newBelow,
                                onPressed: _jumpToLatest,
                              ),
                              if (AppSettings.personalIncognito.value) ...[
                                ConversationReadButton(
                                  rooms: _readSources,
                                  loadedEvents: (room) =>
                                      timelines[room.id]?.events ?? const [],
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
    // One backdrop read for the glass header and composer (DESIGN.md "Glass").
    // Desktop parity with ordinary chats: files dropped on the conversation
    // and ⌘V media open the attachment dialog for the selected source.
    return ConversationSearchScope(
      open: _openSearch,
      child: BackdropGroup(
        child: Actions(
          actions: PlatformInfos.isWeb
              ? const {}
              : <Type, Action<Intent>>{
                  PasteTextIntent: CallbackAction<PasteTextIntent>(
                    onInvoke: (_) => _pasteFromClipboard(),
                  ),
                  // Mac: Esc in the composer, nothing left to cancel, is Back.
                  DismissIntent: ComposerBackAction(
                    composer: inputFocus,
                    enabled: PlatformInfos.isMacOS,
                    onBack: () => unawaited(Navigator.maybePop(context)),
                  ),
                },
          child: ConversationDropTarget(
            enabled: composerEnabled && anyRoom != null,
            onFiles: (files) => unawaited(_attachMedia(() async => files)),
            child: page,
          ),
        ),
      ),
    );
  }
}

/// Returns its first child until [revision] changes. Parent rebuilds that do
/// not affect the rows (composer keystrokes, send state, notices) get the
/// identical widget back, so Flutter skips the whole list subtree.
class _MergedListGate extends StatefulWidget {
  final Object revision;
  final Widget child;
  const _MergedListGate({required this.revision, required this.child});

  @override
  State<_MergedListGate> createState() => _MergedListGateState();
}

class _MergedListGateState extends State<_MergedListGate> {
  late Widget _child = widget.child;

  @override
  void didUpdateWidget(_MergedListGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) _child = widget.child;
  }

  @override
  Widget build(BuildContext context) => _child;
}

/// What one merged send took from the composer (see `_MergedChatPageState`).
class _MergedSent {
  final SendTarget target;
  final String draftKey;
  final String text;
  final Event? reply;
  final Event? edit;

  /// The draft an edit replaced (restored when the edit is sent).
  final String pendingText;

  const _MergedSent({
    required this.target,
    required this.draftKey,
    required this.text,
    required this.reply,
    required this.edit,
    required this.pendingText,
  });
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}

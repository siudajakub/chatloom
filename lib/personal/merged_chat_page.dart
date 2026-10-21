// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

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
import 'package:chatloom/pages/chat/conversation_message_actions.dart';
import 'package:chatloom/pages/chat/conversation_message_menu.dart';
import 'package:chatloom/pages/chat/conversation_motion.dart';
import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/pages/chat/conversation_source_picker.dart';
import 'package:chatloom/pages/chat/event_info_dialog.dart';
import 'package:chatloom/pages/chat/events/message_delivery_status.dart';
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
import 'package:chatloom/personal/encryption/undecryptable_messages.dart';
import 'package:chatloom/personal/immediate_outbox.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/media/immediate_media_outbox.dart';
import 'package:chatloom/personal/person_group_identity.dart';
import 'package:chatloom/personal/person_location.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/personal_hub.dart'
    show
        conversationQuickActions,
        personalDate,
        requestConversationReminder,
        schedulePersonalAttachment;
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/round_video/round_availability.dart';
import 'package:chatloom/personal/round_video/round_capture_controller.dart';
import 'package:chatloom/personal/round_video/telegram_room_binding.dart';
import 'package:chatloom/personal/round_video/telegram_round_service.dart';
import 'package:chatloom/personal/scheduled_composer.dart';
import 'package:chatloom/personal/seen_chat_notifications.dart';
import 'package:chatloom/personal/ui/health_status_widgets.dart';
import 'package:chatloom/personal/ui/notion_chat_details_adapter.dart';
import 'package:chatloom/personal/ui/notion_chat_details_content.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart'
    show notionNetworkLabel;
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/account_config.dart';
import 'package:chatloom/utils/adaptive_bottom_sheet.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/utils/show_scaffold_dialog.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:chatloom/widgets/future_loading_dialog.dart';
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
import 'package:uuid/uuid.dart';

import 'merged_media_dialog.dart';

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
        ConversationSourceHintHost {
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
      onSend: send,
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
  @override
  Event? replyEvent;
  @override
  Event? editEvent;
  String _pendingText = '';
  @override
  bool showEmojiPicker = false;
  bool loading = true, sending = false;
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
    _load();
  }

  @override
  void didUpdateWidget(_MergedChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The store hands out a new group object on every read; only a change of
    // the sources is worth re-merging the history (and rebuilding the rows).
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
  }

  // ---------------------------------------------------------------------
  // Private store and derived rows.

  /// Everything this page renders from the personal store: the person's
  /// nickname and palettes. Draft saves, heartbeats and unrelated metadata
  /// leave it unchanged and therefore do not rebuild the conversation.
  String _computePersonalSignature() {
    final projection = InboxProjection.snapshot(personal);
    final person = projection.metadataForEntity('person:${group.id}');
    return jsonEncode([
      person.nickname,
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
      e.relationshipType != RelationshipTypes.edit;

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
      await Future.wait(
        group.members.map((member) async {
          if (timelines.containsKey(member.roomId)) return;
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
      }
    } catch (_) {
      problem =
          'A source could not be opened. The send network remains unchanged.';
    }
    if (!mounted) return;
    _resolveReadMarker();
    _applyInitialSource();
    setState(() => loading = false);
    _scheduleVisibilityScan();
    unawaited(_revealPendingEvent());
  }

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
    final routed = MergedSendRouter.resolve(
      group: group,
      now: DateTime.now(),
      recentEvent: recent,
      override: replyEvent == null ? selectedNetwork : null,
      replyTo: replyEvent == null ? null : personal.source(replyEvent!),
    );
    return SendTarget(
      conversation: routed.conversation,
      readUpToEventId: viewed[routed.conversation.roomId]?.eventId,
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
  bool get isLoadingFuture => false;

  @override
  Future<void> requestFuture() async {}

  @override
  void mentionSender(Event event) =>
      sendController.text += '${event.senderFromMemoryOrFallback.mention} ';

  @override
  void showEventInfo(Event event) => event.showInfoDialog(context);

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
    await scrollController.scrollToIndex(
      index + 1,
      duration: ChatLoomThemes.animationDuration,
      preferPosition: AutoScrollPosition.middle,
    );
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

  int _editCount(Event event) {
    final timeline = timelineFor(event);
    return timeline == null
        ? 0
        : event.aggregatedEvents(timeline, RelationshipTypes.edit).length;
  }

  bool _canEdit(Event event) =>
      event.senderId == personal.client.userID &&
      event.status.isSent &&
      !event.redacted &&
      RoundVideoDescriptor.fromContent(event.content) == null &&
      {
        MessageTypes.Text,
        MessageTypes.Emote,
        MessageTypes.Notice,
      }.contains(event.messageType) &&
      RoomCapabilities.forFeature(
        BridgeFeature.edit,
        event.room,
        event: event,
        editCount: _editCount(event),
      ).allowed;

  bool _canRedact(Event event) =>
      !event.redacted &&
      event.senderId == personal.client.userID &&
      (!event.status.isSent ||
          (event.canRedact &&
              RoomCapabilities.forFeature(
                BridgeFeature.delete,
                event.room,
                event: event,
              ).allowed));

  bool _canSave(Event event) =>
      !event.redacted &&
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
    _notify(L10n.of(context).copiedToClipboard);
  }

  Future<void> _redact(Event event) async {
    final l10n = L10n.of(context);
    final reasonInput = event.status.isSent
        ? await showTextInputDialog(
            context: context,
            title: l10n.redactMessage,
            message: l10n.redactMessageDescription,
            isDestructive: true,
            hintText: l10n.optionalRedactReason,
            maxLength: 255,
            maxLines: 3,
            minLines: 1,
            okLabel: l10n.remove,
            cancelLabel: l10n.cancel,
          )
        : '';
    if (reasonInput == null || !_stillHere() || !mounted) return;
    final reason = reasonInput.isEmpty ? null : reasonInput;
    await showFutureLoadingDialog(
      context: context,
      future: () async {
        if (event.status.isSent) {
          await event.redactEvent(reason: reason);
        } else {
          await event.cancelSend();
        }
      },
    );
  }

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
    await showScaffoldDialog(
      context: context,
      builder: (context) => ShareScaffoldDialog(
        items: [ContentShareItem(forward.content.copy())],
      ),
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
    if (event.status.isError) event.sendAgain();
    final timeline = timelineFor(event);
    if (timeline != null) {
      for (final edit
          in event
              .aggregatedEvents(timeline, RelationshipTypes.edit)
              .where((e) => e.status.isError)) {
        edit.sendAgain();
      }
    }
    setState(() => _listRevision++);
  }

  Future<void> _bookmark(Event event) async {
    try {
      await personal.put('bookmark:${personal.transcriptId(event)}', {
        'source': personal.source(event).toJson(),
        'network': PersonalClient.networkOf(event.room),
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      });
      _notify('Bookmarked.');
    } catch (_) {
      _notify('The bookmark was not saved.');
    }
  }

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
      if (sent && !event.redacted)
        ConversationMessageAction(
          icon: Icons.bookmark_outline,
          label: 'Bookmark',
          onSelected: () => _bookmark(event),
        ),
      if (_canSave(display))
        ConversationMessageAction(
          icon: Icons.download_outlined,
          label: l10n.downloadFile,
          onSelected: () => display.saveFile(this.context),
        ),
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
          ConversationSourceOption(
            conversation: member,
            title:
                personal.client
                    .getRoomById(member.roomId)
                    ?.getLocalizedDisplayname() ??
                'Unavailable source',
            subtitle: personal.client.userID == member.accountId
                ? 'Current account · Source ${frozenGroup.members.indexOf(member) + 1}'
                : 'Different account · Source ${frozenGroup.members.indexOf(member) + 1}',
            available:
                member.accountId == personal.client.userID &&
                personal.client.getRoomById(member.roomId)?.membership ==
                    Membership.join &&
                personal.client
                        .getRoomById(member.roomId)
                        ?.canSendDefaultMessages ==
                    true,
            unavailableReason: 'Source disconnected or sending unavailable',
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
    _typingCoolDown?.cancel();
    _typingCoolDown = Timer(const Duration(seconds: 2), _stopTyping);
    if (_typingRoom?.id == room.id) return;
    _stopTyping();
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
    final sent = _MergedSent(
      target: frozen,
      draftKey: draftKey,
      text: text,
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
    final durable = Completer<void>();
    Future<bool>? draft;
    Future<ImmediateSendResult>? outcome;
    try {
      final proceed = await showTrustUserInRoomDialog(context, room);
      if (!proceed || !consumeOriginal()) return;
      _stopTyping();
      outcome = personal.sendImmediate(
        room,
        text,
        replyTo: replyAtSend,
        editEventId: editAtSend?.eventId,
        onDurable: (_) {
          draft = _consumeSent(sent);
          if (!durable.isCompleted) durable.complete();
        },
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
      if (!stored) {
        _notify(
          'Message accepted. Your draft and send state are retained until saving is confirmed.',
        );
        return;
      }
      try {
        await personal.completeImmediate(result.actionId);
      } catch (_) {
        _notify(
          'Message accepted. Its send state is retained until local storage is ready.',
        );
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

  /// Files go through the source-bound media dialog: it checks the bridge's
  /// media limits and keeps a reply to a message of the same source.
  Future<void> _attachMedia() async {
    if (sending || loading || _needsNetworkChoice) return;
    final frozen = target;
    final oldText = sendController.text;
    final sourceReply = replyEvent;
    _draftTimer?.cancel();
    final key = 'draft:person:${group.id}';
    var mediaAccepted = false;
    setState(() => sending = true);
    try {
      if (_savedDraftText != oldText &&
          (_savedDraftText != null || oldText.isNotEmpty)) {
        await personal.savePersonalDraft(key, frozen, oldText);
        _savedDraftText = oldText;
      }
      final current = personal.values[key];
      final baseline = current == null ? null : jsonDecode(jsonEncode(current));
      if (!mounted) return;
      final result = await showMergedMediaDialog(
        context,
        personal,
        frozen,
        replyTo: sourceReply,
        caption: oldText,
        onAccepted: (id, at) {
          if (mounted) _rememberAccepted(frozen, id, at);
        },
      );
      if (!mounted) return;
      mediaAccepted = result.accepted;
      // A later draft or a changed caption belongs to the user. Clear only the
      // exact captured text after all file sends were accepted.
      if (result.accepted &&
          result.caption == oldText.trim() &&
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
      if (result.accepted && replyEvent == sourceReply) replyEvent = null;
    } on PersonalCapabilityUnavailable catch (error) {
      _notify(error.reason);
    } catch (_) {
      _notify(
        mediaAccepted
            ? 'Attachments accepted. Your draft is retained until saving is confirmed.'
            : 'Attachments could not be prepared. Your draft is preserved.',
      );
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> _sendFiles(List<XFile> files) async {
    final room = _targetRoom;
    if (files.isEmpty || room == null || !mounted) return;
    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: files,
        room: room,
        outerContext: context,
        threadRootEventId: null,
        threadLastEventId: null,
      ),
    );
  }

  @override
  Future<void> sendImageFromClipBoard(Uint8List? image) async {
    if (image == null || !composerEnabled) return;
    await _sendFiles([XFile.fromData(image)]);
  }

  @override
  void onAddPopupMenuButtonSelected(AddPopupMenuActions choice) {
    final room = _targetRoom;
    if (room == null || !composerEnabled) return;
    switch (choice) {
      case AddPopupMenuActions.file:
      case AddPopupMenuActions.image:
      case AddPopupMenuActions.video:
        unawaited(_attachMedia());
      case AddPopupMenuActions.poll:
        showAdaptiveBottomSheet(
          context: context,
          builder: (context) => StartPollBottomSheet(room: room),
        );
      case AddPopupMenuActions.photoCamera:
        unawaited(() async {
          inputFocus.unfocus();
          final file = await ImagePicker().pickImage(
            source: ImageSource.camera,
          );
          if (file != null) await _sendFiles([file]);
        }());
      case AddPopupMenuActions.videoCamera:
        unawaited(() async {
          inputFocus.unfocus();
          final file = await ImagePicker().pickVideo(
            source: ImageSource.camera,
            maxDuration: const Duration(minutes: 1),
          );
          if (file != null) await _sendFiles([file]);
        }());
      case AddPopupMenuActions.location:
        showAdaptiveDialog(
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
    if (room == null || !PlatformInfos.isAndroid) {
      return RoundAvailability.fromReport(
        const RoundGateReport(RoundGateCode.notJoined),
      );
    }
    return RoundAvailability.of(room);
  }

  @override
  bool get roundRecordingMode {
    final room = _targetRoom;
    return room != null &&
        PlatformInfos.isAndroid &&
        PersonalClient.networkOf(room) == 'telegram' &&
        AppSettings.personalRoundRecordingMode.value &&
        roundAvailability.canRecord;
  }

  @override
  Future<void> toggleRoundRecordingMode() async {
    await AppSettings.personalRoundRecordingMode.setItem(
      !AppSettings.personalRoundRecordingMode.value,
    );
    if (mounted) setState(() {});
  }

  @override
  bool get canRecordRoundSilently {
    final room = _targetRoom;
    return room != null &&
        PlatformInfos.isAndroid &&
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
          );
      if (!mounted || result == null) return;
      if (result.state == ImmediateMediaState.matrixAccepted) {
        if (result.eventId != null) {
          _rememberAccepted(frozen, result.eventId!, DateTime.now());
        }
        if (identical(replyEvent, sourceReply)) {
          setState(() => replyEvent = null);
        }
        // The row itself shows delivery; no notice on success.
        return;
      }
      _notify(switch (result.state) {
        ImmediateMediaState.unknown =>
          'The send result is unknown. The recording and the same attempt remain queued.',
        ImmediateMediaState.staged =>
          'Recording saved locally. Send it from the original conversation.',
        _ => 'Recording awaits saving or retry in the round video queue.',
      });
    } catch (error) {
      _notify(roundFailureMessage(error));
    }
  }

  // ---------------------------------------------------------------------
  // Header actions.

  Future<void> _quickAction(String action) async {
    if (action == 'read') {
      await _allRead();
      return;
    }
    if (action == 'source.details') {
      await showNotionMergedChatDetails(
        context,
        personal: personal,
        group: group,
      );
      return;
    }
    if (action == 'source.search') {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => NotionConversationContentPage(
            rooms: timelines.values.map((t) => t.room).toList(),
            name: group.name,
          ),
        ),
      );
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

  Future<void> _allRead() async {
    var failed = false;
    for (final member in group.members) {
      final room = personal.client.getRoomById(member.roomId);
      final id = room?.lastEvent?.eventId;
      if (room == null || id == null) {
        failed = true;
        continue;
      }
      try {
        await PersonalPrivacy.markRead(room, id, manual: true);
      } catch (_) {
        failed = true;
      }
    }
    if (failed) _notify('Some sources did not confirm the read marker.');
  }

  Future<void> _schedule() async {
    if (sending || _needsNetworkChoice || editEvent != null) return;
    final frozen = target;
    final text = sendController.text;
    final frozenReply = replyEvent;
    final privacyGeneration = PersonalPrivacy.surfaceGeneration;

    setState(() => sending = true);
    try {
      final room = personal.client.getRoomById(frozen.conversation.roomId);
      if (room == null) throw StateError('The selected source is unavailable.');
      final composer = FrozenScheduledComposer.capture(
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
      bool sameComposerContext() =>
          _stillHere() &&
          target.conversation == frozen.conversation &&
          identical(replyEvent, frozenReply);
      final attachment = await showNotionCustomDialog<bool>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Send later'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Text'),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Attachment'),
            ),
          ],
        ),
      );
      if (attachment == null || !mounted) return;
      composer.validateCurrent();
      if (!attachment && text.trim().isEmpty) {
        _notify(
          'Write a message before scheduling text. Your draft is preserved.',
        );
        return;
      }
      if (attachment) {
        await schedulePersonalAttachment(
          context,
          personal,
          frozen,
          composeContext: composer,
        );
      } else {
        final due = await personalDate(context);
        if (due == null || !mounted) return;
        composer.validateCurrent();
        if (!due.isAfter(DateTime.now())) throw StateError('Invalid date');
        final id = const Uuid().v4();
        await personal.schedule(
          ScheduledSend(
            id: id,
            target: frozen,
            dueAt: due,
            content: composer.content({'msgtype': 'm.text', 'body': text}),
            transactionId: 'schedule-$id',
          ),
        );
        if (sendController.text == text && sameComposerContext()) {
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
        }
      }
    } catch (_) {
      _notify(
        'The message could not be scheduled in the selected source. Your draft is preserved.',
      );
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

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

  @override
  void dispose() {
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
    final person = projection.metadataForEntity('person:${group.id}');
    final displayName = person.nickname ?? group.name;
    final anyRoom = _anyRoom;
    final background = conversationPalette.theme?.backgroundColor;
    final notice = problem;
    final wallpaper = personal.client.applicationAccountConfig;
    final retry = unavailable.isNotEmpty || timelines.isEmpty;
    // Brand-new undecryptable rows get a moment for a key on its way, as in
    // ordinary chats; the fix sheet retries each row in its own source.
    final lockedCount = UndecryptableMessages.settledCount(_locked);
    final hintHeight = lockedCount > 0
        ? UndecryptableChatHint.heightFor(MediaQuery.textScalerOf(context))
        : 0.0;
    final bottomHeight =
        (notice == null ? 0.0 : ChatAppBarListTile.fixedHeight) + hintHeight;
    final page = PopScope(
      canPop:
          !showEmojiPicker &&
          // Telegram: back cancels a reply or edit before leaving the chat.
          replyEvent == null &&
          editEvent == null,
      onPopInvokedWithResult: (pop, _) {
        if (pop) return;
        if (showEmojiPicker) {
          emojiPickerAction();
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
          flexibleSpace: const NotionGlassBar(),
          toolbarHeight: NotionTokens.headerHeight,
          elevation: 0,
          scrolledUnderElevation: 0,
          shape: Border(
            bottom: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
          automaticallyImplyLeading: false,
          leading: columns
              ? null
              : IconButton(
                  icon: const Icon(Icons.chevron_left),
                  tooltip: 'Back',
                  onPressed: () => Navigator.maybePop(context),
                ),
          titleSpacing: columns ? NotionSpace.xl : 0,
          title: NotionCompactChatHeader(
            avatar: personalConversationAvatar(
              personal,
              entityId: 'person:${group.id}',
              avatar: projection.avatarForGroup(group),
              name: displayName,
              size: NotionSize.avatarSm,
            ),
            name: displayName,
            status: ConnectionStatusLine(client: personal.client),
            onDetails: () => showNotionMergedChatDetails(
              context,
              personal: personal,
              group: group,
            ),
          ),
          actions: [
            PopupMenuButton<String>(
              tooltip: 'Conversation actions',
              icon: const Icon(Icons.more_horiz),
              onSelected: _quickAction,
              itemBuilder: (_) => conversationQuickActions(
                merged: true,
                editing: editEvent != null,
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
                        ),
                      // Composer keystrokes, notices and send state rebuild
                      // this page; the gate hands back the previous list
                      // subtree unless something the rows render changed.
                      _MergedListGate(
                        revision: (_listRevision, anyRoom.id, theme),
                        child: ChatEventList(controller: this),
                      ),
                      // The send target's bridge (merged chats send per source).
                      ChatBridgeNotice(room: room),
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
                              child: ConversationTint(
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
                      // Above the measured composer (reply preview
                      // included), never over its close button.
                      PositionedDirectional(
                        end: 0,
                        bottom: 0,
                        child: ConversationJumpButtonSlot(
                          composerInset: composerInset,
                          child: ConversationJumpButton(
                            visible: _scrolledUp,
                            count: _newBelow,
                            onPressed: _jumpToLatest,
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
    return BackdropGroup(child: page);
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

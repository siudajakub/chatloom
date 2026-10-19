// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/chat.dart';
import 'package:fluffychat/pages/chat/chat_app_bar_list_tile.dart';
import 'package:fluffychat/pages/chat/chat_emoji_picker.dart';
import 'package:fluffychat/pages/chat/chat_event_list.dart';
import 'package:fluffychat/pages/chat/chat_input_row.dart';
import 'package:fluffychat/pages/chat/compact_composer.dart';
import 'package:fluffychat/pages/chat/conversation_source.dart';
import 'package:fluffychat/pages/chat/composer_keyboard.dart';
import 'package:fluffychat/pages/chat/conversation_source_picker.dart';
import 'package:fluffychat/pages/chat/event_info_dialog.dart';
import 'package:fluffychat/pages/chat/notion_conversation.dart';
import 'package:fluffychat/pages/chat/reply_display.dart';
import 'package:fluffychat/pages/chat/send_file_dialog.dart';
import 'package:fluffychat/pages/chat/send_location_dialog.dart';
import 'package:fluffychat/pages/chat/start_poll_bottom_sheet.dart';
import 'package:fluffychat/pages/chat/trust_user_key_dialog.dart';
import 'package:fluffychat/pages/chat/undecryptable_chat_hint.dart';
import 'package:fluffychat/pages/chat/undecryptable_fix_sheet.dart';
import 'package:fluffychat/pages/chat/voice_message_sender.dart';
import 'package:fluffychat/pages/chat_list/chat_list_item.dart';
import 'package:fluffychat/personal/capabilities.dart';
import 'package:fluffychat/personal/encryption/undecryptable_messages.dart';
import 'package:fluffychat/personal/immediate_outbox.dart';
import 'package:fluffychat/personal/inbox_projection.dart';
import 'package:fluffychat/personal/media/immediate_media_outbox.dart';
import 'package:fluffychat/personal/person_location.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/personal_hub.dart'
    show
        conversationQuickActions,
        personalDate,
        requestConversationReminder,
        schedulePersonalAttachment;
import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/personal/round_video/round_availability.dart';
import 'package:fluffychat/personal/round_video/round_capture_controller.dart';
import 'package:fluffychat/personal/round_video/telegram_room_binding.dart';
import 'package:fluffychat/personal/round_video/telegram_round_service.dart';
import 'package:fluffychat/personal/scheduled_composer.dart';
import 'package:fluffychat/personal/ui/notion_chat_details_adapter.dart';
import 'package:fluffychat/personal/ui/notion_chat_details_content.dart';
import 'package:fluffychat/personal/ui/notion_network_filter.dart'
    show notionNetworkLabel;
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/utils/account_config.dart';
import 'package:fluffychat/utils/adaptive_bottom_sheet.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/show_scaffold_dialog.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/mxc_image.dart';
import 'package:fluffychat/widgets/share_scaffold_dialog.dart';
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
    implements ConversationTimelineSource, ConversationComposerHost {
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
  double? inputBarHeight;

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
  final List<Event> selectedEvents = [];
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
    if (!identical(oldWidget.group, widget.group)) {
      final members = {for (final m in widget.group.members) m.roomId};
      for (final roomId in timelines.keys.toList()) {
        if (!members.contains(roomId)) {
          timelines.remove(roomId)?.cancelSubscriptions();
        }
      }
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
  void onSelectMessage(Event event) {
    if (event.redacted) return;
    setState(() {
      if (selectedEvents.contains(event)) {
        selectedEvents.remove(event);
      } else {
        selectedEvents.add(event);
      }
      selectedEvents.sort(
        (a, b) => a.originServerTs.compareTo(b.originServerTs),
      );
      _listRevision++;
    });
  }

  void clearSelectedEvents() => setState(() {
    selectedEvents.clear();
    showEmojiPicker = false;
    _listRevision++;
  });

  void clearSingleSelectedEvent() {
    if (selectedEvents.length <= 1 && selectedEvents.isNotEmpty) {
      clearSelectedEvents();
    }
  }

  @override
  void showEventInfo([Event? event]) =>
      (event ?? selectedEvents.single).showInfoDialog(context);

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
      duration: FluffyThemes.animationDuration,
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
  // Selection actions (reply, edit, delete, copy, forward, retry).

  void _lockTo(Room room) {
    _draftTarget = SendTarget(
      conversation: personal.ref(room),
      readUpToEventId: viewed[room.id]?.eventId,
    );
  }

  @override
  void replyAction({Event? replyTo}) {
    final event = replyTo ?? selectedEvents.firstOrNull;
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
      selectedEvents.clear();
      _listRevision++;
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

  bool get _canEditSelected =>
      selectedEvents.length == 1 && _canEdit(selectedEvents.single);

  bool get _canRedactSelected =>
      selectedEvents.isNotEmpty &&
      selectedEvents.every(
        (event) =>
            event.senderId == personal.client.userID &&
            (!event.status.isSent ||
                (event.canRedact &&
                    RoomCapabilities.forFeature(
                      BridgeFeature.delete,
                      event.room,
                      event: event,
                    ).allowed)),
      );

  bool get _canSaveSelected =>
      selectedEvents.length == 1 &&
      {
        MessageTypes.Video,
        MessageTypes.Image,
        MessageTypes.Sticker,
        MessageTypes.Audio,
        MessageTypes.File,
      }.contains(selectedEvents.single.messageType);

  @override
  void editSelectedEventAction() {
    final event = selectedEvents.firstOrNull;
    if (event == null || !_canEdit(event)) return;
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
      selectedEvents.clear();
      _listRevision++;
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

  String _selectedText() => selectedEvents
      .map((event) {
        final timeline = timelineFor(event);
        return (timeline == null ? event : event.getDisplayEvent(timeline))
            .body;
      })
      .join('\n\n');

  void _copySelected() {
    Clipboard.setData(ClipboardData(text: _selectedText()));
    clearSelectedEvents();
  }

  Future<void> _redactSelected() async {
    final events = List<Event>.of(selectedEvents);
    final l10n = L10n.of(context);
    final reasonInput = events.any((event) => event.status.isSent)
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
      futureWithProgress: (onProgress) async {
        for (final (i, event) in events.indexed) {
          onProgress(i / events.length);
          if (event.status.isSent) {
            await event.redactEvent(reason: reason);
          } else {
            await event.cancelSend();
          }
        }
      },
    );
    if (mounted) clearSelectedEvents();
  }

  @override
  Future<void> deleteErrorEventsAction() async {
    final events = List<Event>.of(selectedEvents);
    if (events.any((event) => event.status != EventStatus.error)) return;
    try {
      for (final event in events) {
        await event.cancelSend();
      }
    } catch (_) {
      _notify('The unsent message could not be removed.');
    }
    if (mounted) clearSelectedEvents();
  }

  @override
  Future<void> forwardEventsAction() async {
    final events = List<Event>.of(selectedEvents);
    if (events.isEmpty) return;
    final forward = [
      for (final event in events)
        switch (timelineFor(event)) {
          final Timeline timeline => event.getDisplayEvent(timeline),
          null => event,
        },
    ];
    if (forward.any(
      (e) => !RoundMediaPolicy.fromContent(e.content).canForward,
    )) {
      _notify('This message cannot be forwarded.');
      return;
    }
    if (forward.any(
      (e) => RoundVideoDescriptor.fromContent(e.content) != null,
    )) {
      if (forward.length != 1) {
        _notify('Forward one round video at a time.');
        return;
      }
      await TelegramRoundService.of(
        forward.single.room.client,
      ).showForwardPicker(context, forward.single);
      if (mounted) clearSelectedEvents();
      return;
    }
    await showScaffoldDialog(
      context: context,
      builder: (context) => ShareScaffoldDialog(
        items: [
          for (final event in forward) ContentShareItem(event.content.copy()),
        ],
      ),
    );
    if (mounted) clearSelectedEvents();
  }

  @override
  void sendAgainAction() {
    final event = selectedEvents.firstOrNull;
    if (event == null) return;
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
      clearSelectedEvents();
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
    clearSelectedEvents();
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

  Future<void> _selectionMenu(String action) async {
    final event = selectedEvents.singleOrNull;
    if (event == null) return;
    switch (action) {
      case 'source':
        clearSelectedEvents();
        _openSource(event);
      case 'bookmark':
        clearSelectedEvents();
        await _bookmark(event);
      case 'save':
        event.saveFile(context);
      case 'info':
        clearSelectedEvents();
        showEventInfo(event);
    }
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

  Future<void> _chooseSource() async {
    if (replyEvent != null || editEvent != null || sending) return;
    final frozenGroup = group;
    final frozenReply = replyEvent;
    final wasFocused = inputFocus.hasFocus;
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
    );
    if (value == null ||
        !mounted ||
        !identical(widget.group, frozenGroup) ||
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
    setState(() {
      selectedNetwork = value;
      _draftTarget = SendTarget(
        conversation: value,
        readUpToEventId: viewed[value.roomId]?.eventId,
      );
      if (_needsNetworkChoice) problem = null;
      _needsNetworkChoice = false;
    });
    if (wasFocused) inputFocus.requestFocus();
    await _draft();
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

  @override
  Future<void> send() async {
    if (!composerEnabled ||
        sendController.text.trim().isEmpty ||
        !PersonalPrivacy.surfaceUnlocked)
      return;
    final frozen = target;
    final valueAtSend = sendController.value;
    final text = valueAtSend.text;
    final replyAtSend = replyEvent;
    final editAtSend = editEvent;
    final privacyGeneration = PersonalPrivacy.surfaceGeneration;
    final draftKey = 'draft:person:${group.id}';
    bool activeAccount() =>
        _stillHere() && draftKey == 'draft:person:${group.id}';
    bool consumeOriginal() =>
        activeAccount() &&
        PersonalPrivacy.surfaceUnlocked &&
        PersonalPrivacy.surfaceGeneration == privacyGeneration &&
        sendController.value == valueAtSend &&
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
    var accepted = false;
    setState(() => sending = true);
    try {
      final proceed = await showTrustUserInRoomDialog(context, room);
      if (!proceed || !consumeOriginal()) return;
      _stopTyping();
      final result = await personal.sendImmediate(
        room,
        text,
        replyTo: replyAtSend,
        editEventId: editAtSend?.eventId,
      );
      if (!activeAccount()) return;
      if (result.state != ImmediateSendState.accepted) {
        _notify(
          'Sending was not confirmed. Retrying retains the same attempt.',
        );
        return;
      }
      accepted = true;
      if (result.eventId != null && editAtSend == null) {
        _rememberAccepted(frozen, result.eventId!, DateTime.now());
      }
      while (activeAccount()) {
        _draftTimer?.cancel();
        final currentValue = sendController.value;
        final currentReply = replyEvent;
        final currentEdit = editEvent;
        final currentTarget = target;
        final consume = consumeOriginal();
        final remaining = consume
            ? (editAtSend == null ? '' : _pendingText)
            : currentValue.text;
        await personal.savePersonalDraft(draftKey, currentTarget, remaining);
        if (!activeAccount()) return;
        if (sendController.value != currentValue ||
            !identical(replyEvent, currentReply) ||
            !identical(editEvent, currentEdit) ||
            target.conversation != currentTarget.conversation ||
            consume != consumeOriginal())
          continue;
        _savedDraftText = remaining;
        if (consume) {
          sendController.text = remaining;
          replyEvent = null;
          editEvent = null;
          _pendingText = '';
          _inputEmpty = remaining.isEmpty;
          if (remaining.isEmpty) _draftTarget = null;
        }
        await personal.completeImmediate(result.actionId);
        break;
      }
    } catch (_) {
      _notify(
        accepted
            ? 'Message accepted. Your draft and send state are retained until saving is confirmed.'
            : 'Sending was not confirmed. Your draft is preserved. Check the source before retrying.',
      );
    } finally {
      if (mounted) setState(() => sending = false);
    }
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

  @override
  bool get selectMode => selectedEvents.isNotEmpty;

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

  void _updateInputBarHeight() {
    if (!mounted) return;
    final box = inputBarKey.currentContext?.findRenderObject();
    final height = box is RenderBox && box.hasSize ? box.size.height : 72.0;
    if (height != inputBarHeight) setState(() => inputBarHeight = height);
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
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Build.

  List<Widget> _selectionActions(BuildContext context) {
    final l10n = L10n.of(context);
    final single = selectedEvents.length == 1;
    PopupMenuItem<String> item(String value, IconData icon, String label) =>
        PopupMenuItem(
          value: value,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: NotionSpace.sm,
            children: [Icon(icon), Text(label)],
          ),
        );
    return [
      if (_canEditSelected)
        IconButton(
          icon: const Icon(Icons.edit_outlined),
          tooltip: l10n.edit,
          onPressed: editSelectedEventAction,
        ),
      IconButton(
        icon: const Icon(Icons.copy_outlined),
        tooltip: l10n.copyToClipboard,
        onPressed: _copySelected,
      ),
      if (_canRedactSelected)
        IconButton(
          icon: const Icon(Icons.delete_outlined),
          tooltip: l10n.redactMessage,
          onPressed: _redactSelected,
        ),
      if (single)
        PopupMenuButton<String>(
          useRootNavigator: true,
          tooltip: 'More message actions',
          onSelected: _selectionMenu,
          itemBuilder: (context) => [
            item('source', Icons.open_in_new_outlined, 'Open in source chat'),
            item('bookmark', Icons.bookmark_outline, 'Bookmark'),
            if (_canSaveSelected)
              item('save', Icons.download_outlined, l10n.downloadFile),
            item('info', Icons.info_outlined, l10n.messageInfo),
          ],
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final columns = FluffyThemes.isColumnMode(context);
    final projection = InboxProjection.snapshot(personal);
    final person = projection.metadataForEntity('person:${group.id}');
    final displayName = person.nickname ?? group.name;
    final anyRoom = _anyRoom;
    final selecting = selectedEvents.isNotEmpty;
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
    return PopScope(
      canPop: !selecting && !showEmojiPicker,
      onPopInvokedWithResult: (pop, _) {
        if (pop) return;
        if (selecting) {
          clearSelectedEvents();
        } else if (showEmojiPicker) {
          emojiPickerAction();
        }
      },
      child: Scaffold(
        backgroundColor: background == null ? null : Color(background),
        // Messages scroll under the glass header (DESIGN.md "Glass").
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          flexibleSpace: NotionGlassBar(
            tint: selecting ? theme.colorScheme.tertiaryContainer : null,
          ),
          toolbarHeight: NotionTokens.headerHeight,
          elevation: 0,
          scrolledUnderElevation: 0,
          shape: Border(
            bottom: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
          automaticallyImplyLeading: false,
          leading: selecting
              ? IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: clearSelectedEvents,
                  tooltip: L10n.of(context).close,
                  color: theme.colorScheme.onTertiaryContainer,
                )
              : columns
              ? null
              : IconButton(
                  icon: const Icon(Icons.chevron_left),
                  tooltip: 'Back',
                  onPressed: () => Navigator.maybePop(context),
                ),
          titleSpacing: columns ? NotionSpace.xl : 0,
          // Selection count and header cross-fade; the count rolls.
          title: NotionFadeThrough(
            duration: NotionMotion.short,
            alignment: AlignmentDirectional.centerStart,
            child: selecting
                ? NotionAnimatedCount(
                    key: const ValueKey('selection'),
                    count: selectedEvents.length,
                  )
                : NotionCompactChatHeader(
                    key: const ValueKey('header'),
                    avatar: personalConversationAvatar(
                      personal,
                      entityId: 'person:${group.id}',
                      avatar: projection.avatarForGroup(group),
                      name: displayName,
                      size: NotionSize.avatarSm,
                    ),
                    name: displayName,
                    onDetails: () => showNotionMergedChatDetails(
                      context,
                      personal: personal,
                      group: group,
                    ),
                  ),
          ),
          actions: [
            NotionFadeThrough(
              duration: NotionMotion.short,
              alignment: AlignmentDirectional.centerEnd,
              child: Row(
                key: ValueKey(selecting),
                mainAxisSize: MainAxisSize.min,
                children: selecting
                    ? _selectionActions(context)
                    : [
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
        floatingActionButton: ConversationJumpButton(
          visible: _scrolledUp && !selecting,
          count: _newBelow,
          onPressed: () => scrollController.animateTo(
            0,
            duration: NotionMotion.long,
            curve: NotionMotion.emphasized,
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
                        Opacity(
                          opacity: wallpaper.wallpaperOpacity ?? 0.5,
                          child: MxcImage(
                            cacheKey: wallpaper.wallpaperUrl.toString(),
                            uri: wallpaper.wallpaperUrl,
                            fit: BoxFit.cover,
                            height: MediaQuery.sizeOf(context).height,
                            width: MediaQuery.sizeOf(context).width,
                            isThumbnail: false,
                            placeholder: (_) => const SizedBox.shrink(),
                          ),
                        ),
                      // Composer keystrokes, notices and send state rebuild
                      // this page; the gate hands back the previous list
                      // subtree unless something the rows render changed.
                      _MergedListGate(
                        revision: (
                          _listRevision,
                          inputBarHeight,
                          anyRoom.id,
                          theme,
                        ),
                        child: GestureDetector(
                          onTap: clearSingleSelectedEvent,
                          child: ChatEventList(controller: this),
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
                                maxWidth: FluffyThemes.maxTimelineWidth,
                              ),
                              child: ConversationTint(
                                color: selecting
                                    ? theme.colorScheme.tertiaryContainer
                                    : theme.colorScheme.surfaceContainer,
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
                    ],
                  ),
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

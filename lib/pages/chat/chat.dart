// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/chat_view.dart';
import 'package:fluffychat/pages/chat/compact_composer.dart'
    show ConversationSourceChip;
import 'package:fluffychat/pages/chat/conversation_source.dart';
import 'package:fluffychat/pages/chat/event_info_dialog.dart';
import 'package:fluffychat/pages/chat/events/message.dart';
import 'package:fluffychat/pages/chat/start_poll_bottom_sheet.dart';
import 'package:fluffychat/pages/chat/trust_user_key_dialog.dart';
import 'package:fluffychat/pages/chat/utils/web_file_to_x_file.dart';
import 'package:fluffychat/pages/chat/voice_message_sender.dart';
import 'package:fluffychat/pages/chat_details/chat_details.dart';
import 'package:fluffychat/personal/capabilities.dart';
import 'package:fluffychat/personal/immediate_outbox.dart';
import 'package:fluffychat/personal/media/immediate_media_outbox.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/personal/round_video/round_availability.dart';
import 'package:fluffychat/personal/round_video/round_capture_controller.dart';
import 'package:fluffychat/personal/round_video/telegram_media_protocol.dart';
import 'package:fluffychat/personal/round_video/telegram_room_binding.dart';
import 'package:fluffychat/personal/round_video/telegram_round_service.dart';
import 'package:fluffychat/utils/adaptive_bottom_sheet.dart';
import 'package:fluffychat/utils/error_reporter.dart';
import 'package:fluffychat/utils/file_selector.dart';
import 'package:fluffychat/utils/matrix_live_kit_calls/matrix_live_kit_call.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/utils/other_party_can_receive.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/show_scaffold_dialog.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:fluffychat/widgets/app_lock.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/mxc_image.dart';
import 'package:fluffychat/widgets/share_scaffold_dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:personal_core/personal_core.dart'
    show ChatTheme, RoundMediaPolicy, RoundVideoDescriptor;
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:universal_html/universal_html.dart' as web;

import '../../utils/account_bundles.dart';
import 'send_file_dialog.dart';
import 'send_location_dialog.dart';

class ChatPage extends StatelessWidget {
  final String roomId;
  final List<ShareItem>? shareItems;
  final String? eventId;
  final Timeline? timeline;
  final String? action;

  const ChatPage({
    super.key,
    required this.roomId,
    this.eventId,
    this.shareItems,
    this.timeline,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final room =
        timeline?.room ?? Matrix.of(context).client.getRoomById(roomId);
    if (room == null) {
      return Scaffold(
        appBar: AppBar(title: Text(L10n.of(context).oopsSomethingWentWrong)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(L10n.of(context).youAreNoLongerParticipatingInThisChat),
          ),
        ),
      );
    }

    return ChatPageWithRoom(
      key: Key('chat_page_${roomId}_${eventId}_$action'),
      room: room,
      shareItems: shareItems,
      eventId: eventId,
      timeline: timeline,
      action: action,
    );
  }
}

class ChatPageWithRoom extends StatefulWidget {
  final Room room;
  final List<ShareItem>? shareItems;
  final String? eventId;
  final Timeline? timeline;
  final String? action;

  const ChatPageWithRoom({
    super.key,
    required this.room,
    this.shareItems,
    this.eventId,
    this.timeline,
    this.action,
  });

  @override
  ChatController createState() => ChatController();
}

class ChatController extends State<ChatPageWithRoom>
    with WidgetsBindingObserver
    implements ConversationTimelineSource, ConversationComposerHost {
  @override
  Room get room => sendingClient.getRoomById(roomId) ?? widget.room;

  @override
  late Client sendingClient;

  Timeline? timeline;

  @override
  String? activeThreadId;

  /// Every default emoji, built once per process instead of on every open.
  static final Set<String> _defaultBigEmojis = {
    for (final category in defaultEmojiSet)
      for (final emoji in category.emoji) emoji.emoji,
  };

  /// Emoji rendered large when sent alone; shared with the merged chat.
  static Set<String> get defaultBigEmojis => _defaultBigEmojis;

  @override
  final Set<String> bigEmojis = _defaultBigEmojis;

  @override
  late final String readMarkerEventId;

  String get roomId => widget.room.id;

  @override
  final AutoScrollController scrollController = AutoScrollController();

  @override
  late final FocusNode inputFocus;

  Timer? typingCoolDown;
  Timer? typingTimeout;
  bool currentlyTyping = false;
  bool dragging = false;

  final GlobalKey inputBarKey = GlobalKey();

  void onDragEntered(_) => setState(() => dragging = true);

  void onDragExited(_) => setState(() => dragging = false);

  Future<void> onDragDone(DropDoneDetails details) async {
    setState(() => dragging = false);
    if (details.files.isEmpty) return;
    await _pickAttachments(() async => details.files);
  }

  bool get canSaveSelectedEvent =>
      selectedEvents.length == 1 &&
      {
        MessageTypes.Video,
        MessageTypes.Image,
        MessageTypes.Sticker,
        MessageTypes.Audio,
        MessageTypes.File,
      }.contains(selectedEvents.single.messageType);

  void saveSelectedEvent(BuildContext context) =>
      selectedEvents.single.saveFile(context);

  @override
  List<Event> selectedEvents = [];

  final Set<String> unfolded = {};

  @override
  Event? replyEvent;

  final VoiceMessageSender _voiceSender = VoiceMessageSender();

  @override
  Event? editEvent;

  bool _scrolledUp = false;

  bool get showScrollDownButton =>
      _scrolledUp || timeline?.allowNewEvent == false;

  @override
  bool get selectMode => selectedEvents.isNotEmpty;

  final int _loadHistoryCount = 100;

  String pendingText = '';

  @override
  bool showEmojiPicker = false;

  @override
  String? get threadLastEventId {
    final threadId = activeThreadId;
    if (threadId == null) return null;
    return timeline?.events
        .filterByVisibleInGui(threadId: threadId)
        .firstOrNull
        ?.eventId;
  }

  // ConversationTimelineSource: one room, one timeline.

  @override
  List<Event>? get conversationEvents =>
      timeline?.events.filterByVisibleInGui(threadId: activeThreadId);

  @override
  Timeline? timelineFor(Event event) => timeline;

  @override
  Set<String> get conversationRoomIds => {room.id};

  @override
  List<Room> get typingRooms => [room];

  @override
  ({ChatTheme? theme}) get conversationPalette =>
      Message.resolveRoomPalette(room);

  @override
  bool get canLoadHistory =>
      activeThreadId == null && (timeline?.canRequestHistory ?? false);

  @override
  bool get isLoadingHistory => timeline?.isRequestingHistory ?? false;

  /// Loads further back by itself unless most of the loaded events are
  /// hidden (state/collapsed), which would keep requesting empty pages.
  @override
  bool get autoLoadHistory {
    final timeline = this.timeline;
    if (timeline == null || historyError != null || historyLoading) {
      return false;
    }
    final visibleIndex = timeline.events.lastIndexWhere(
      (event) => !event.isCollapsedState && event.isVisibleInGui,
    );
    return visibleIndex > timeline.events.length - 50;
  }

  @override
  bool get canLoadFuture => timeline?.canRequestFuture ?? false;

  @override
  bool get isLoadingFuture => timeline?.isRequestingFuture ?? false;

  @override
  void mentionSender(Event event) =>
      sendController.text += '${event.senderFromMemoryOrFallback.mention} ';

  @override
  void Function(String eventId)? get threadOpener =>
      activeThreadId == null ? enterThread : null;

  @override
  String? sourceLabelFor(Event event) => null;

  @override
  bool seriesBoundary(Event event) => false;

  @override
  bool get strictCapabilities => false;

  // ConversationComposerHost: the room is the send target.

  @override
  bool get composerEnabled => !_personalSending && !_attachmentPending;

  @override
  bool get composerBusy => _personalSending || _attachmentPending;

  @override
  Widget buildComposerSource(BuildContext context) => ConversationSourceChip(
    network: PersonalClient.networkOf(room),
    locked: replyEvent != null,
  );

  @override
  bool get allowsAccountSwitch => true;

  void enterThread(String eventId) => setState(() {
    activeThreadId = eventId;
    selectedEvents.clear();
  });

  void closeThread() => setState(() {
    activeThreadId = null;
    selectedEvents.clear();
  });

  Future<void> recreateChat() async {
    final room = this.room;
    final userId = room.directChatMatrixID;
    if (userId == null) {
      throw Exception(
        'Try to recreate a room with is not a DM room. This should not be possible from the UI!',
      );
    }
    await showFutureLoadingDialog(
      context: context,
      future: () => room.invite(userId),
    );
  }

  Future<void> leaveChat() async {
    final success = await showFutureLoadingDialog(
      context: context,
      future: room.leave,
    );
    if (!mounted) return;
    if (success.error != null) return;
    context.go('/rooms');
  }

  @override
  String? historyError;
  @override
  bool historyLoading = false;
  final _historyPositions = <(Timeline, int, String?, String?)>{};
  @override
  Future<void> requestHistory([_]) async {
    final current = timeline;
    if (historyLoading || current == null || current.isRequestingHistory)
      return;
    final before = (
      current.events.length,
      current.room.prev_batch,
      current.events.lastOrNull?.eventId,
    );
    setState(() {
      historyLoading = true;
      historyError = null;
    });
    try {
      await current.requestHistory(historyCount: _loadHistoryCount);
      if (!mounted || !identical(timeline, current)) return;
      final position = (
        current,
        current.events.length,
        current.room.prev_batch,
        current.events.lastOrNull?.eventId,
      );
      final repeated = !_historyPositions.add(position);
      if (_historyPositions.length > 32)
        _historyPositions.remove(_historyPositions.first);
      if (current.canRequestHistory &&
          (repeated ||
              before ==
                  (
                    current.events.length,
                    current.room.prev_batch,
                    current.events.lastOrNull?.eventId,
                  ))) {
        historyError = 'History did not advance. Retry loading older messages.';
      }
    } catch (_) {
      if (mounted && identical(timeline, current))
        historyError = 'Older history could not load. Retry.';
    } finally {
      if (mounted) setState(() => historyLoading = false);
    }
  }

  @override
  Future<void> requestFuture() async {
    final timeline = this.timeline;
    if (timeline == null) return;
    Logs().v('Requesting future...');

    final mostRecentEvent = timeline.events.filterByVisibleInGui().firstOrNull;

    await timeline.requestFuture(historyCount: _loadHistoryCount);

    if (mostRecentEvent != null) {
      setReadMarker(eventId: mostRecentEvent.eventId);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final index = timeline.events.filterByVisibleInGui().indexOf(
          mostRecentEvent,
        );
        if (index >= 0) {
          scrollController.scrollToIndex(
            index,
            preferPosition: AutoScrollPosition.begin,
          );
        }
      });
    }
  }

  void _updateScrollController() {
    if (!mounted) {
      return;
    }
    if (!scrollController.hasClients) return;
    if (timeline?.allowNewEvent == false ||
        scrollController.position.pixels > 0 && _scrolledUp == false) {
      setState(() => _scrolledUp = true);
    } else if (scrollController.position.pixels <= 0 && _scrolledUp == true) {
      setState(() => _scrolledUp = false);
      setReadMarker();
    }
  }

  Future<void> _loadDraft() async {
    // Protected personal storage is native-only; web keeps composer state in memory.
    if (kIsWeb) return;
    final personal = PersonalClient.of(room.client);
    final prefs = Matrix.of(context).store;
    try {
      var draft = await personal.loadDraft(room);
      final legacy = prefs.getString('draft_$roomId');
      if (draft == null && legacy != null) {
        await personal.saveDraft(room, legacy);
        await prefs.remove('draft_$roomId');
        draft = legacy;
      }
      if (mounted && sendController.text.isEmpty && draft != null) {
        sendController.text = draft;
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'The draft could not be opened. Existing data is preserved.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _shareItems() async {
    final shareItems = widget.shareItems;
    if (shareItems == null || shareItems.isEmpty) return;
    final frozen = _captureAttachmentContext();
    if (!room.otherPartyCanReceiveMessages) {
      final theme = Theme.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: theme.colorScheme.errorContainer,
          closeIconColor: theme.colorScheme.onErrorContainer,
          content: Text(
            L10n.of(context).otherPartyNotLoggedIn,
            style: TextStyle(color: theme.colorScheme.onErrorContainer),
          ),
          showCloseIcon: true,
        ),
      );
      return;
    }
    final proceed = await showTrustUserInRoomDialog(context, frozen.room);
    if (!mounted || !proceed) return;
    try {
      frozen.validate();
    } catch (_) {
      return;
    }
    for (final item in shareItems) {
      if (item is FileShareItem) continue;
      if (item is TextShareItem) frozen.room.sendTextEvent(item.value);
      if (item is ContentShareItem) frozen.room.sendEvent(item.value.copy());
    }
    final files = shareItems
        .whereType<FileShareItem>()
        .map((item) => item.value)
        .toList();
    if (files.isEmpty) return;
    await _pickAttachments(() async => files);
  }

  KeyEventResult _customEnterKeyHandling(FocusNode node, KeyEvent evt) {
    if (evt is KeyDownEvent &&
        evt.logicalKey == LogicalKeyboardKey.arrowUp &&
        !PlatformInfos.isMobile &&
        editEvent == null &&
        replyEvent == null &&
        sendController.text.isEmpty) {
      _editLastSentMessage();
      return KeyEventResult.handled;
    }

    if (evt is KeyDownEvent &&
        evt.logicalKey == LogicalKeyboardKey.escape &&
        editEvent != null) {
      _cancelEditWithConfirmation();
      return KeyEventResult.handled;
    }

    // Enter confirming an IME candidate belongs to the editor, never send.
    if (evt.logicalKey.keyLabel == 'Enter' &&
        sendController.value.composing.isValid &&
        !sendController.value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    if (!HardwareKeyboard.instance.isShiftPressed &&
        evt.logicalKey.keyLabel == 'Enter' &&
        AppSettings.sendOnEnter.value) {
      if (evt is KeyDownEvent) {
        send();
      }
      return KeyEventResult.handled;
    } else if (evt.logicalKey.keyLabel == 'Enter' && evt is KeyDownEvent) {
      final currentLineNum =
          sendController.text
              .substring(0, sendController.selection.baseOffset)
              .split('\n')
              .length -
          1;
      final currentLine = sendController.text.split('\n')[currentLineNum];

      for (final pattern in [
        '- [ ] ',
        '- [x] ',
        '* [ ] ',
        '* [x] ',
        '- ',
        '* ',
        '+ ',
      ]) {
        if (currentLine.startsWith(pattern)) {
          if (currentLine == pattern) {
            return KeyEventResult.ignored;
          }
          sendController.text += '\n$pattern';
          return KeyEventResult.handled;
        }
      }

      return KeyEventResult.ignored;
    } else {
      return KeyEventResult.ignored;
    }
  }

  @override
  void initState() {
    inputFocus = FocusNode(onKeyEvent: _customEnterKeyHandling);

    scrollController.addListener(_updateScrollController);
    inputFocus.addListener(_inputFocusListener);

    sendingClient = widget.room.client;
    _loadDraft();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _shareItems();
      _checkMatrixRtcCallSupport();
      if (widget.action == 'call') {
        Matrix.of(context).activeCallRoomId.value = room.id;
      }
    });
    web.window.addEventListener('paste', _handleClipboardFilePasteWeb);

    super.initState();
    _displayChatDetailsColumn = ValueNotifier(
      AppSettings.displayChatDetailsColumn.value,
    );

    final lastEventThreadId =
        room.lastEvent?.relationshipType == RelationshipTypes.thread
        ? room.lastEvent?.relationshipEventId
        : null;
    readMarkerEventId = room.hasNewMessages
        ? lastEventThreadId ?? room.fullyRead
        : '';
    WidgetsBinding.instance.addObserver(this);
    _tryLoadTimeline();
  }

  /// One LiveKit discovery per client and process; failures are retried.
  static final _liveKitSupport = Expando<Future<bool>>();

  Future<void> _checkMatrixRtcCallSupport() async {
    // Bridged rooms never offer the call button, so they never need the
    // network round trip.
    final checkedRoom = room;
    if (checkedRoom.states['m.bridge'] != null ||
        checkedRoom.states['uk.half-shot.bridge'] != null) {
      return;
    }
    // Keep the request and its rebuild off the chat-open transition.
    await _awaitRouteSettled();
    if (!mounted) return;
    final client = checkedRoom.client;
    final support = _liveKitSupport[client] ??= client
        .getLiveKitServiceUrls()
        .then((urls) => urls.isNotEmpty);
    try {
      if (!await support || !mounted || supportLiveKitCalls) return;
      setState(() {
        supportLiveKitCalls = true;
      });
    } catch (e) {
      if (identical(_liveKitSupport[client], support)) {
        _liveKitSupport[client] = null;
      }
      Logs().d('Unable to check MatrixRTC call support', e);
    }
  }

  /// Completes when this page's push transition has finished (or at once if
  /// it is not animating). Bounded so a stalled animation never blocks.
  Future<void> _awaitRouteSettled() async {
    if (!mounted) return;
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.status != AnimationStatus.forward) {
      return;
    }
    final settled = Completer<void>();
    void listener(AnimationStatus status) {
      if (status != AnimationStatus.forward && !settled.isCompleted) {
        settled.complete();
      }
    }

    animation.addStatusListener(listener);
    try {
      await settled.future.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {},
      );
    } finally {
      animation.removeStatusListener(listener);
    }
  }

  @override
  final Set<String> expandedEventIds = {};

  @override
  void expandEventsFrom(Event event, bool expand) {
    final events = timeline!.events.filterByVisibleInGui(
      threadId: activeThreadId,
    );
    final start = events.indexOf(event);
    setState(() {
      for (var i = start; i < events.length; i++) {
        final event = events[i];
        if (!event.isCollapsedState) return;
        if (expand) {
          expandedEventIds.add(event.eventId);
        } else {
          expandedEventIds.remove(event.eventId);
        }
      }
    });
  }

  Future<void> _tryLoadTimeline() async {
    final initialEventId = widget.eventId;
    loadTimelineFuture = _getTimeline();
    try {
      await loadTimelineFuture;
      if (!mounted || timeline == null) return;
      // We launched the chat with a given initial event ID:
      if (initialEventId != null) {
        scrollToEventId(initialEventId);
        return;
      }

      var readMarkerEventIndex = readMarkerEventId.isEmpty
          ? -1
          : timeline!.events
                .filterByVisibleInGui(
                  exceptionEventId: readMarkerEventId,
                  threadId: activeThreadId,
                )
                .indexWhere((e) => e.eventId == readMarkerEventId);

      // Read marker is existing but not found in first events. Try a single
      // requestHistory call before opening timeline on event context:
      if (readMarkerEventId.isNotEmpty && readMarkerEventIndex == -1) {
        await timeline?.requestHistory(historyCount: _loadHistoryCount);
        if (!mounted || timeline == null) return;
        readMarkerEventIndex = timeline!.events
            .filterByVisibleInGui(
              exceptionEventId: readMarkerEventId,
              threadId: activeThreadId,
            )
            .indexWhere((e) => e.eventId == readMarkerEventId);
      }

      if (readMarkerEventIndex > 1) {
        Logs().v('Scroll up to visible event', readMarkerEventId);
        scrollToEventId(readMarkerEventId, highlightEvent: false);
      } else if (readMarkerEventId.isNotEmpty && readMarkerEventIndex == -1) {
        _showScrollUpMaterialBanner(readMarkerEventId);
      }

      // Mark room as read on first visit if requirements are fulfilled
      setReadMarker();

      if (!mounted) return;
    } catch (e, s) {
      if (!mounted) return;
      ErrorReporter(context, 'Unable to load timeline').onErrorCallback(e, s);
    }
  }

  String? scrollUpBannerEventId;

  void discardScrollUpBannerEventId() => setState(() {
    scrollUpBannerEventId = null;
  });

  void _showScrollUpMaterialBanner(String eventId) => setState(() {
    scrollUpBannerEventId = eventId;
  });

  @override
  String? animateInEventId;

  Future<void> _insert(int index) async {
    if (index > 0) return;
    final firstEvent = timeline?.events.firstOrNull;
    final eventId = firstEvent?.transactionId ?? firstEvent?.eventId;
    animateInEventId = eventId;
    await Future.delayed(FluffyThemes.animationDuration);
    if (animateInEventId == eventId) animateInEventId = null;
  }

  bool _viewUpdateScheduled = false;

  /// Timeline `onUpdate` can fire many times per frame (sync batches, history
  /// pages, decryption). Coalesce into one read-marker pass and one rebuild
  /// per frame.
  void updateView() {
    if (!mounted || _viewUpdateScheduled) return;
    _viewUpdateScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _viewUpdateScheduled = false;
      if (!mounted) return;
      setReadMarker();
      setState(() {});
    });
  }

  Future<void>? loadTimelineFuture;

  void retryLoadTimeline() {
    _tryLoadTimeline();
    setState(() {});
  }

  int _timelineLoadGeneration = 0;

  Future<void> _getTimeline({String? eventContextId}) async {
    final generation = ++_timelineLoadGeneration;
    final requestedRoom = room;
    final client = requestedRoom.client;
    await client.roomsLoading;
    await client.accountDataLoading;
    if (!mounted || generation != _timelineLoadGeneration) return;
    if (eventContextId != null &&
        (!eventContextId.isValidMatrixIdStrict() ||
            eventContextId.sigil != '\$')) {
      eventContextId = null;
    }
    Timeline loadedTimeline;
    try {
      loadedTimeline =
          widget.timeline ??
          await requestedRoom.getTimeline(
            onUpdate: updateView,
            onInsert: _insert,
            eventContextId: eventContextId,
          );
    } catch (e) {
      // Only a failed context lookup can fall back to the current timeline.
      // Initial loading errors must reach the retry UI.
      if (eventContextId == null) rethrow;
      loadedTimeline = await requestedRoom.getTimeline(
        onUpdate: updateView,
        onInsert: _insert,
      );
      if (mounted &&
          generation == _timelineLoadGeneration &&
          (e is TimeoutException || e is IOException)) {
        _showScrollUpMaterialBanner(eventContextId);
      }
    }
    if (timeline == null && mounted && generation == _timelineLoadGeneration) {
      // Swapping the placeholder for a full timeline mid-transition costs a
      // heavy frame while the page slides in; show it once the route settles.
      await _awaitRouteSettled();
    }
    if (!mounted || generation != _timelineLoadGeneration) {
      if (loadedTimeline != widget.timeline) {
        loadedTimeline.cancelSubscriptions();
      }
      return;
    }
    if (timeline != loadedTimeline) timeline?.cancelSubscriptions();
    timeline = loadedTimeline;
    historyError = null;
    _historyPositions.clear();
    loadedTimeline.requestKeys(onlineKeyBackupOnly: false);
    if (requestedRoom.markedUnread &&
        PersonalPrivacy.policy.allowAutomaticRead) {
      unawaited(requestedRoom.markUnread(false));
    }
  }

  @override
  String? scrollToEventIdMarker;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!mounted) return;
    setReadMarker();
  }

  String? _setReadMarkerEventId;
  String? personalSeenEventId;

  void setReadMarker({String? eventId}) {
    if (!mounted ||
        !PersonalPrivacy.surfaceUnlocked ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    // Do not send read markers when app is not in foreground
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }

    final setOnLatestEvent = eventId == null;

    // We only set read marker if we are at the bottom
    if (_scrolledUp && setOnLatestEvent) return;

    // We do not set read marker if we offer user the scroll up banner
    if (scrollUpBannerEventId != null) return;

    // We do not set read marker if timeline is empty
    final timeline = this.timeline;
    if (timeline == null || timeline.events.isEmpty) return;

    // Do not set read marker on rtc notification while call is active. This
    // mutes callkit.
    if (room.hasActiveMatrixRtcCall &&
        timeline.events.first.type == RtcNotificationContent.eventType) {
      return;
    }

    eventId ??= timeline.events.firstWhereOrNull((event) {
      if (isTelegramMediaControl(event.type)) return false;
      if (event.eventId == room.lastEvent?.eventId) return true;
      if (room.client.pushruleEvaluator.match(event).notify) {
        return true;
      }
      final original = event.originalSource;
      if (original != null &&
          room.client.pushruleEvaluator
              .match(Event.fromMatrixEvent(original, room))
              .notify) {
        return true;
      }
      return false;
    })?.eventId;

    if (setOnLatestEvent && (room.hasNewMessages || room.isUnread)) {
      eventId ??= timeline.events
          .firstWhereOrNull(
            (event) =>
                !isTelegramMediaControl(event.type) && event.isVisibleInGui,
          )
          ?.eventId;
    }
    if (timeline.events.any(
      (event) => event.eventId == eventId && isTelegramMediaControl(event.type),
    ))
      return;

    // There is no event we could place a read marker
    if (eventId == null) return;

    // This is a sending event, we do not set a readmarker yet
    if (eventId.isValidMatrixIdStrict() == false) return;

    // We are already setting a read marker on this event
    if (_setReadMarkerEventId == eventId) return;

    // Already set a read marker on this event
    if (room.fullyRead == eventId && !setOnLatestEvent) return;

    // Set a readmarker on a specific event, not latest, but room is not unread
    // at all.
    if (setOnLatestEvent &&
        !room.hasNewMessages &&
        room.notificationCount == 0) {
      return;
    }

    if (mounted &&
        scrollController.hasClients &&
        scrollController.position.pixels <= 1) {
      final seenEventId = eventId;
      final seenRoom = room;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            room != seenRoom ||
            !PersonalPrivacy.surfaceUnlocked ||
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed ||
            ModalRoute.of(context)?.isCurrent != true ||
            _scrolledUp ||
            !scrollController.hasClients ||
            scrollController.position.pixels > 1) {
          return;
        }
        personalSeenEventId = seenEventId;
        PersonalPrivacy.observe(seenRoom, seenEventId);
      });
    }
    if (!PersonalPrivacy.policy.allowAutomaticRead) return;
    Logs().d('Set read marker');
    _setReadMarkerEventId = eventId;
    // ignore: unawaited_futures
    timeline
        .setReadMarker(
          eventId: eventId,
          public: AppSettings.sendPublicReadReceipts.value,
        )
        .whenComplete(() {
          if (_setReadMarkerEventId == eventId) _setReadMarkerEventId = null;
        });
  }

  @override
  void dispose() {
    _timelineLoadGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    timeline?.cancelSubscriptions();
    timeline = null;
    _storeInputTimeoutTimer?.cancel();
    typingCoolDown?.cancel();
    typingTimeout?.cancel();
    sendController.dispose();
    scrollController.dispose();
    inputFocus.removeListener(_inputFocusListener);
    inputFocus.dispose();
    _displayChatDetailsColumn.dispose();
    web.window.removeEventListener('paste', _handleClipboardFilePasteWeb);
    if (currentlyTyping) PersonalPrivacy.setTyping(room, false);
    MxcImage.clearCache(widget.room.id);
    super.dispose();
  }

  @override
  TextEditingController sendController = TextEditingController();

  @override
  void setSendingClient(Client c) {
    // first cancel typing with the old sending client
    if (currentlyTyping) {
      // no need to have the setting typing to false be blocking
      typingCoolDown?.cancel();
      typingCoolDown = null;
      PersonalPrivacy.setTyping(room, false);
      currentlyTyping = false;
    }
    setState(() => sendingClient = c);
    // then cancel the old timeline
    // fixes bug with read reciepts and quick switching
    loadTimelineFuture = _getTimeline(eventContextId: room.fullyRead).onError(
      ErrorReporter(
        context,
        'Unable to load timeline after changing sending Client',
      ).onErrorCallback,
    );

    setState(() {});
  }

  void setActiveClient(Client c) => setState(() {
    Matrix.of(context).setActiveClient(c);
  });

  bool _personalSending = false;
  bool get personalSending => _personalSending;
  bool _attachmentPending = false;
  bool get attachmentPending => _attachmentPending;
  @override
  Future<void> send() async {
    if (_personalSending || _attachmentPending) return;
    if (!mounted) return;
    setState(() => _personalSending = true);
    try {
      await _sendPersonal();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'The message could not be prepared. Your draft is preserved.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _personalSending = false);
    }
  }

  Future<void> _sendPersonal() async {
    final frozenRoom = room;
    final frozenText = sendController.text;
    final frozenReply = replyEvent;
    final frozenEdit = editEvent;
    final frozenThread = activeThreadId;
    final frozenThreadLast = threadLastEventId;
    final frozenPendingText = pendingText;
    final frozenValue = sendController.value;
    final privacyGeneration = PersonalPrivacy.surfaceGeneration;
    bool sameContext() =>
        mounted &&
        identical(room, frozenRoom) &&
        identical(Matrix.of(context).client, frozenRoom.client) &&
        identical(replyEvent, frozenReply) &&
        identical(editEvent, frozenEdit) &&
        activeThreadId == frozenThread &&
        threadLastEventId == frozenThreadLast &&
        PersonalPrivacy.surfaceUnlocked &&
        PersonalPrivacy.surfaceGeneration == privacyGeneration;
    if (frozenText.trim().isEmpty) return;
    for (final feature in [
      if (frozenReply != null) BridgeFeature.reply,
      if (frozenEdit != null) BridgeFeature.edit,
    ]) {
      final result = RoomCapabilities.forFeature(
        feature,
        frozenRoom,
        event: frozenEdit ?? frozenReply,
      );
      if (result.status == CapabilityStatus.unavailable) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(result.reason)));
        return;
      }
    }

    final proceed = await showTrustUserInRoomDialog(context, frozenRoom);
    if (!mounted || !proceed) return;
    if (!sameContext() || sendController.value != frozenValue) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The message changed. Review your draft before sending.',
          ),
        ),
      );
      return;
    }
    _storeInputTimeoutTimer?.cancel();

    var parseCommands = true;

    final commandMatch = RegExp(r'^\/(\w+)').firstMatch(frozenText);
    if (commandMatch != null &&
        !sendingClient.commands.keys.contains(commandMatch[1]!.toLowerCase())) {
      final l10n = L10n.of(context);
      final dialogResult = await showOkCancelAlertDialog(
        context: context,
        title: l10n.commandInvalid,
        message: l10n.commandMissing(commandMatch[0]!),
        okLabel: l10n.sendAsText,
        cancelLabel: l10n.cancel,
      );
      if (dialogResult != OkCancelResult.ok) return;
      if (!sameContext() || sendController.value != frozenValue) return;
      parseCommands = false;
    }

    if (currentlyTyping) {
      typingCoolDown?.cancel();
      currentlyTyping = false;
      PersonalPrivacy.setTyping(room, false);
    }

    try {
      final personal = PersonalClient.of(frozenRoom.client);
      ImmediateSendResult? result;
      if (parseCommands && RegExp(r'^/\w+').hasMatch(frozenText)) {
        await frozenRoom.sendTextEvent(
          frozenText,
          inReplyTo: frozenReply,
          editEventId: frozenEdit?.eventId,
          threadRootEventId: frozenThread,
        );
      } else {
        result = await personal.sendImmediate(
          frozenRoom,
          frozenText,
          replyTo: frozenReply,
          editEventId: frozenEdit?.eventId,
          threadId: frozenThread,
        );
        if (result.state != ImmediateSendState.accepted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Sending was not confirmed. Retrying the same content retains the attempt ID.',
                ),
              ),
            );
          }
          return;
        }
      }
      // Transport acceptance is final even if local draft/receipt handling fails.
      String remainingDraft() =>
          mounted &&
              identical(room, frozenRoom) &&
              (!sameContext() || sendController.value != frozenValue)
          ? sendController.text
          : frozenPendingText;
      var nextText = remainingDraft();
      var draftStored = false;
      try {
        // A save can overlap typing or a reply/edit change. Keep persisting the
        // latest editor value before retiring the accepted outbox attempt.
        do {
          nextText = remainingDraft();
          await personal.saveDraft(frozenRoom, nextText);
        } while (mounted &&
            identical(room, frozenRoom) &&
            remainingDraft() != nextText);
        draftStored = true;
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Message accepted. The draft could not be updated; send state is preserved.',
              ),
            ),
          );
        }
      }
      if (result != null && draftStored) {
        try {
          await personal.completeImmediate(result.actionId);
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Message accepted. Its send state is retained until local storage is ready.',
                ),
              ),
            );
          }
        }
      }
      if (!mounted || room != frozenRoom) return;
      setState(() {
        // A new draft, selection or IME range belongs to the editor.
        if (draftStored &&
            sameContext() &&
            sendController.value == frozenValue) {
          sendController.value = TextEditingValue(
            text: nextText,
            selection: TextSelection.collapsed(offset: nextText.length),
          );
          replyEvent = null;
          editEvent = null;
          pendingText = '';
        }
        _inputTextIsEmpty = sendController.text.isEmpty;
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Sending was not confirmed. Your draft is preserved. Check the conversation before retrying.',
            ),
          ),
        );
      }
    }
  }

  FrozenAttachmentContext _captureAttachmentContext() {
    final frozenRoom = room;
    final frozenReply = replyEvent;
    final frozenEdit = editEvent;
    final frozenThread = activeThreadId;
    final frozenThreadLast = threadLastEventId;
    final privacyGeneration = PersonalPrivacy.surfaceLockGeneration;
    return FrozenAttachmentContext(
      room: frozenRoom,
      replyTo: frozenReply,
      threadRootEventId: frozenThread,
      threadLastEventId: frozenThreadLast,
      isCurrent: () =>
          mounted &&
          identical(room, frozenRoom) &&
          identical(Matrix.of(context).client, frozenRoom.client) &&
          identical(replyEvent, frozenReply) &&
          identical(editEvent, frozenEdit) &&
          frozenEdit == null &&
          activeThreadId == frozenThread &&
          threadLastEventId == frozenThreadLast &&
          PersonalPrivacy.surfaceUnlocked &&
          PersonalPrivacy.surfaceLockGeneration == privacyGeneration,
    );
  }

  /// One picker/preview at a time. All routes keep their original source and
  /// reply, and a cancelled picker never consumes the editor's draft.
  Future<void> _pickAttachments(Future<List<XFile>> Function() pick) async {
    if (!mounted || _attachmentPending || _personalSending) return;
    final frozen = _captureAttachmentContext();
    final originalValue = sendController.value;
    final restoreFocus = inputFocus.hasFocus;
    var accepted = false;
    setState(() => _attachmentPending = true);
    try {
      frozen.validate();
      inputFocus.unfocus();
      final files = await pick();
      if (!mounted || files.isEmpty) return;
      frozen.validate();
      final result = await showAdaptiveDialog<AttachmentSendResult>(
        context: context,
        builder: (_) => SendFileDialog(
          files: files,
          room: frozen.room,
          outerContext: context,
          replyTo: frozen.replyTo,
          initialCaption: originalValue.text,
          composeContext: frozen,
          threadRootEventId: frozen.threadRootEventId,
          threadLastEventId: frozen.threadLastEventId,
        ),
      );
      if (!mounted || result == null) return;
      accepted = true;
      if (!frozen.isCurrent()) return;
      if (sendController.value == originalValue &&
          result.caption == originalValue.text.trim()) {
        // Persist before clearing. A storage error keeps the user's text.
        if (!kIsWeb) {
          _storeInputTimeoutTimer?.cancel();
          await PersonalClient.of(
            frozen.room.client,
          ).saveDraft(frozen.room, '');
        }
        if (!mounted) return;
        frozen.validate();
        if (sendController.value == originalValue) {
          setState(() {
            sendController.clear();
            _inputTextIsEmpty = true;
          });
        } else if (!kIsWeb) {
          await PersonalClient.of(
            frozen.room.client,
          ).saveDraft(frozen.room, sendController.text);
        }
      }
      if (mounted && identical(replyEvent, frozen.replyTo)) {
        setState(() => replyEvent = null);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              accepted
                  ? 'Attachments accepted. Your draft is kept until saving is confirmed.'
                  : 'Attachments could not be completed in the original conversation. Your draft is preserved.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _attachmentPending = false);
        if (restoreFocus) inputFocus.requestFocus();
      }
    }
  }

  Future<void> sendFileAction({FileType type = FileType.any}) =>
      _pickAttachments(
        () => selectFiles(context, allowMultiple: true, type: type),
      );

  Future<void> sendImageFromClipBoard(Uint8List? image) async {
    if (image == null) return;
    await _pickAttachments(
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

  Future<void> openGalleryAction() => _pickAttachments(
    () => AppLock.of(
      context,
    ).pauseWhile(ImagePicker().pickMultipleMedia(requestFullMetadata: false)),
  );

  Future<void> openCameraAction() => _pickAttachments(() async {
    final file = await AppLock.of(
      context,
    ).pauseWhile(ImagePicker().pickImage(source: ImageSource.camera));
    return [?file];
  });

  Future<void> _handleClipboardFilePasteWeb(web.Event event) async {
    if (event is! web.ClipboardEvent) return;
    final clipboardFiles = event.clipboardData?.files;
    if (clipboardFiles == null || clipboardFiles.length < 1) return;
    // The browser clears clipboardData when this event handler awaits.
    final localFiles = clipboardFiles.toList();
    event.preventDefault();
    event.stopPropagation();
    await _pickAttachments(() async {
      final files = <XFile>[];
      for (final file in localFiles) {
        files.add(await webToXFile(file));
      }
      return files;
    });
  }

  Future<void> _handleClipboardImagePaste() async {
    final frozen = _captureAttachmentContext();
    final editorValue = sendController.value;
    await _pickAttachments(() async {
      final files = await Pasteboard.files();
      frozen.validate();
      if (files.isNotEmpty) return files.map(XFile.new).toList();
      final image = await Pasteboard.image;
      frozen.validate();
      if (image != null)
        return [
          XFile.fromData(
            image,
            name: 'pasted-image.png',
            path: 'pasted-image.png',
            mimeType: 'image/png',
          ),
        ];
      final textData = await Clipboard.getData('text/plain');
      frozen.validate();
      if (textData?.text != null && sendController.value == editorValue) {
        final selection = editorValue.selection.isValid
            ? editorValue.selection
            : TextSelection.collapsed(offset: editorValue.text.length);
        final text = editorValue.text.replaceRange(
          selection.start,
          selection.end,
          textData!.text!,
        );
        sendController.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(
            offset: selection.start + textData.text!.length,
          ),
        );
        onInputBarChanged(text);
      }
      return [];
    });
  }

  Future<void> openVideoCameraAction() => _pickAttachments(() async {
    final file = await AppLock.of(context).pauseWhile(
      ImagePicker().pickVideo(
        source: ImageSource.camera,
        maxDuration: const Duration(minutes: 1),
      ),
    );
    return [?file];
  });

  @override
  Future<bool> onVoiceMessageSend(
    String path,
    int duration,
    List<int> waveform,
    String fileName, {
    Future<bool> Function(Room)? confirmTrust,
    Future<Uint8List?> Function(String)? readRecording,
  }) {
    final target = room;
    final client = target.client;
    final reply = replyEvent;
    final thread = activeThreadId;
    return _voiceSender.send(
      context: context,
      target: target,
      reply: reply,
      thread: thread,
      lastThreadEvent: threadLastEventId,
      composerUnchanged: () =>
          mounted &&
          identical(sendingClient, client) &&
          identical(room.client, client) &&
          room.id == target.id &&
          identical(replyEvent, reply) &&
          activeThreadId == thread &&
          editEvent == null,
      path: path,
      duration: duration,
      waveform: waveform,
      fileName: fileName,
      confirmTrust: confirmTrust,
      readRecording: readRecording,
      onAccepted: () => setState(() => replyEvent = null),
    );
  }

  @override
  void hideEmojiPicker() {
    setState(() => showEmojiPicker = false);
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

  void _inputFocusListener() {
    if (showEmojiPicker && inputFocus.hasFocus) {
      setState(() => showEmojiPicker = false);
    }
  }

  Future<void> sendLocationAction() async {
    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendLocationDialog(room: room),
    );
  }

  String _getSelectedEventString() {
    var copyString = '';
    if (selectedEvents.length == 1) {
      return selectedEvents.first.getDisplayEvent(timeline!).body;
    }
    for (final event in selectedEvents) {
      if (copyString.isNotEmpty) copyString += '\n\n';
      copyString += event.getDisplayEvent(timeline!).body;
    }
    return copyString;
  }

  void copyEventsAction() {
    Clipboard.setData(ClipboardData(text: _getSelectedEventString()));
    setState(() {
      showEmojiPicker = false;
      selectedEvents.clear();
    });
  }

  Future<void> reportEventAction() async {
    final event = selectedEvents.single;
    final l10n = L10n.of(context);
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    if (!mounted) return;
    final reason = await showTextInputDialog(
      context: context,
      title: l10n.whyDoYouWantToReportThis,
      okLabel: l10n.ok,
      cancelLabel: l10n.cancel,
      hintText: l10n.reason,
    );
    if (reason == null || reason.isEmpty) return;
    if (!mounted) return;
    final result = await showFutureLoadingDialog(
      context: context,
      future: () => Matrix.of(
        context,
      ).client.reportEvent(event.roomId!, event.eventId, reason: reason),
    );
    if (result.error != null) return;
    if (!mounted) return;
    setState(() {
      showEmojiPicker = false;
      selectedEvents.clear();
    });
    scaffoldMessenger.showSnackBar(
      SnackBar(content: Text(l10n.contentHasBeenReported)),
    );
  }

  @override
  Future<void> deleteErrorEventsAction() async {
    try {
      if (selectedEvents.any((event) => event.status != EventStatus.error)) {
        throw Exception(
          'Tried to delete failed to send events but one event is not failed to sent',
        );
      }
      for (final event in selectedEvents) {
        await event.cancelSend();
      }
      setState(selectedEvents.clear);
    } catch (e, s) {
      if (!mounted) return;
      ErrorReporter(
        context,
        'Error while delete error events action',
      ).onErrorCallback(e, s);
    }
  }

  Future<void> redactEventsAction() async {
    final reasonInput = selectedEvents.any((event) => event.status.isSent)
        ? await showTextInputDialog(
            context: context,
            title: L10n.of(context).redactMessage,
            message: L10n.of(context).redactMessageDescription,
            isDestructive: true,
            hintText: L10n.of(context).optionalRedactReason,
            maxLength: 255,
            maxLines: 3,
            minLines: 1,
            okLabel: L10n.of(context).remove,
            cancelLabel: L10n.of(context).cancel,
          )
        : null;
    if (reasonInput == null) return;
    final reason = reasonInput.isEmpty ? null : reasonInput;
    if (!mounted) return;
    await showFutureLoadingDialog(
      context: context,
      futureWithProgress: (onProgress) async {
        final count = selectedEvents.length;
        for (final (i, event) in selectedEvents.indexed) {
          onProgress(i / count);
          if (event.status.isSent) {
            if (event.canRedact) {
              await event.redactEvent(reason: reason);
            } else {
              final client = currentRoomBundle.firstWhere(
                (cl) => selectedEvents.first.senderId == cl!.userID,
                orElse: () => null,
              );
              if (client == null) {
                return;
              }
              final room = client.getRoomById(roomId)!;
              await Event.fromJson(
                event.toJson(),
                room,
              ).redactEvent(reason: reason);
            }
          } else {
            await event.cancelSend();
          }
        }
      },
    );
    setState(() {
      showEmojiPicker = false;
      selectedEvents.clear();
    });
  }

  @override
  List<Client?> get currentRoomBundle {
    final clients = Matrix.of(context).currentBundle!;
    clients.removeWhere((c) => c!.getRoomById(roomId) == null);
    return clients;
  }

  bool get canRedactSelectedEvents {
    if (isArchived) return false;
    final clients = Matrix.of(context).currentBundle;
    for (final event in selectedEvents) {
      if (!event.status.isSent) return false;
      if (event.canRedact == false &&
          !(clients!.any((cl) => event.senderId == cl!.userID))) {
        return false;
      }
    }
    return true;
  }

  bool get canPinSelectedEvents {
    if (isArchived ||
        !room.canChangeStateEvent(EventTypes.RoomPinnedEvents) ||
        selectedEvents.length != 1 ||
        !selectedEvents.single.status.isSent ||
        activeThreadId != null) {
      return false;
    }
    return true;
  }

  /// Effective mode: the round button only replaces the voice mic when the
  /// room is not known to refuse rounds, so voice notes stay reachable.
  @override
  bool get roundRecordingMode =>
      PlatformInfos.isAndroid &&
      PersonalClient.networkOf(room) == 'telegram' &&
      AppSettings.personalRoundRecordingMode.value &&
      roundAvailability.canRecord;

  /// Cached per room/sync/trust change; display only, never authorizes.
  @override
  RoundAvailability get roundAvailability => RoundAvailability.of(room);

  @override
  Future<void> toggleRoundRecordingMode() async {
    await AppSettings.personalRoundRecordingMode.setItem(
      !AppSettings.personalRoundRecordingMode.value,
    );
    if (mounted) setState(() {});
  }

  @override
  bool get canRecordRoundSilently =>
      PlatformInfos.isAndroid &&
      roundAvailability.canRecord &&
      TelegramRoomBinding.of(
            room,
          )?.capabilities(room).extension.operation('silent_send').allowed ==
          true;

  @override
  Future<void> recordRound(
    RoundCaptureGestureController gesture, {
    bool silent = false,
  }) async {
    final frozenRoom = room;
    final frozenReply = replyEvent;
    final frozenThread = activeThreadId;
    try {
      final result = await TelegramRoundService.of(frozenRoom.client)
          .captureAndSend(
            context,
            frozenRoom,
            reply: frozenReply,
            threadId: frozenThread,
            gesture: gesture,
            silent: silent,
            stillCurrent: () =>
                mounted &&
                room.id == frozenRoom.id &&
                identical(Matrix.of(context).client, frozenRoom.client) &&
                identical(room.client, frozenRoom.client) &&
                activeThreadId == frozenThread,
          );
      if (!mounted || result == null) return;
      if (result.state == ImmediateMediaState.matrixAccepted &&
          identical(replyEvent, frozenReply))
        setState(() => replyEvent = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(switch (result.state) {
            ImmediateMediaState.matrixAccepted =>
              'Matrix accepted the round video. Telegram delivery awaits confirmation.',
            ImmediateMediaState.unknown =>
              'The send result is unknown. The recording and the same attempt remain queued.',
            ImmediateMediaState.staged =>
              'Recording saved locally. Send it from the original conversation.',
            _ => 'Recording awaits saving or retry in the round video queue.',
          }),
        ),
      );
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(roundFailureMessage(error))));
    }
  }

  bool get canEditSelectedEvents {
    if (isArchived ||
        selectedEvents.length != 1 ||
        !selectedEvents.first.status.isSent ||
        RoundVideoDescriptor.fromContent(selectedEvents.first.content) !=
            null) {
      return false;
    }
    return currentRoomBundle.any(
      (cl) => selectedEvents.first.senderId == cl!.userID,
    );
  }

  @override
  Future<void> forwardEventsAction() async {
    if (selectedEvents.isEmpty) return;
    final timeline = this.timeline;
    if (timeline == null) return;

    final forwardEvents = List<Event>.from(
      selectedEvents,
    ).map((event) => event.getDisplayEvent(timeline)).toList();
    if (forwardEvents.any(
      (e) => !RoundMediaPolicy.fromContent(e.content).canForward,
    ))
      return;
    if (forwardEvents.any(
      (e) => RoundVideoDescriptor.fromContent(e.content) != null,
    )) {
      if (forwardEvents.length != 1) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Forward one round video at a time.')),
        );
        return;
      }
      await TelegramRoundService.of(
        forwardEvents.single.room.client,
      ).showForwardPicker(context, forwardEvents.single);
      if (mounted) setState(() => selectedEvents.clear());
      return;
    }

    await showScaffoldDialog(
      context: context,
      builder: (context) => ShareScaffoldDialog(
        items: forwardEvents
            .map((event) => ContentShareItem(event.content.copy()))
            .toList(),
      ),
    );
    if (!mounted) return;
    setState(() => selectedEvents.clear());
  }

  @override
  void sendAgainAction() {
    final event = selectedEvents.first;
    if (RoundVideoDescriptor.fromContent(event.content) != null) {
      final txid =
          event.unsigned?.tryGet<String>('transaction_id') ?? event.eventId;
      final match = RegExp(r'^round-([A-Za-z0-9_-]{1,128})$').firstMatch(txid);
      if (match != null)
        unawaited(
          () async {
            await TelegramRoundService.of(event.room.client).retry(
              match[1]!,
              stillCurrent: () =>
                  mounted &&
                  room.id == event.room.id &&
                  identical(Matrix.of(context).client, event.room.client),
            );
          }().catchError((Object _) {}),
        );
      if (mounted) setState(() => selectedEvents.clear());
      return;
    }
    if (event.status.isError) {
      event.sendAgain();
    }
    final allEditEvents = event
        .aggregatedEvents(timeline!, RelationshipTypes.edit)
        .where((e) => e.status.isError);
    for (final e in allEditEvents) {
      e.sendAgain();
    }
    setState(() => selectedEvents.clear());
  }

  @override
  void replyAction({Event? replyTo}) {
    setState(() {
      replyEvent = replyTo ?? selectedEvents.first;
      selectedEvents.clear();
    });
    inputFocus.requestFocus();
  }

  @override
  Future<void> scrollToEventId(
    String eventId, {
    bool highlightEvent = true,
    bool loadContextIfMissing = true,
  }) async {
    if (!mounted || timeline == null) return;
    final foundEvent = timeline!.events.firstWhereOrNull(
      (event) => event.eventId == eventId,
    );

    final eventIndex = foundEvent == null
        ? -1
        : timeline!.events
              .filterByVisibleInGui(
                exceptionEventId: eventId,
                threadId: activeThreadId,
              )
              .indexOf(foundEvent);

    if (eventIndex == -1) {
      if (!loadContextIfMissing) {
        _showScrollUpMaterialBanner(eventId);
        return;
      }
      setState(() {
        timeline?.cancelSubscriptions();
        timeline = null;
        _scrolledUp = false;
        loadTimelineFuture = _getTimeline(eventContextId: eventId).onError(
          ErrorReporter(
            context,
            'Unable to load timeline after scroll to ID',
          ).onErrorCallback,
        );
      });
      await loadTimelineFuture;
      WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
        if (!mounted || timeline == null) return;
        scrollToEventId(
          eventId,
          highlightEvent: highlightEvent,
          loadContextIfMissing: false,
        );
      });
      return;
    }
    if (highlightEvent) {
      setState(() {
        scrollToEventIdMarker = eventId;
      });
    }
    await scrollController.scrollToIndex(
      eventIndex + 1,
      duration: FluffyThemes.animationDuration,
      preferPosition: AutoScrollPosition.middle,
    );
    _updateScrollController();
  }

  Future<void> scrollDown() async {
    if (timeline == null) return;
    if (!timeline!.allowNewEvent) {
      setState(() {
        timeline?.cancelSubscriptions();
        timeline = null;
        _scrolledUp = false;
        loadTimelineFuture = _getTimeline().onError(
          ErrorReporter(
            context,
            'Unable to load timeline after scroll down',
          ).onErrorCallback,
        );
      });
      await loadTimelineFuture;
    }
    if (!mounted || !scrollController.hasClients) return;
    scrollController.jumpTo(0);
  }

  @override
  void onEmojiSelected(_, Emoji? emoji) {
    typeEmoji(emoji);
    onInputBarChanged(sendController.text);
  }

  void typeEmoji(Emoji? emoji) {
    if (emoji == null) return;
    final text = sendController.text;
    final selection = sendController.selection;
    final start = selection.baseOffset == -1 ? 0 : selection.baseOffset;
    final newText = sendController.text.isEmpty
        ? emoji.emoji
        : text.replaceRange(selection.start, selection.end, emoji.emoji);
    sendController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(
        // don't forget an UTF-8 combined emoji might have a length > 1
        offset: start + emoji.emoji.length,
      ),
    );
  }

  @override
  void emojiPickerBackspace() {
    sendController
      ..text = sendController.text.characters.skipLast(1).toString()
      ..selection = TextSelection.fromPosition(
        TextPosition(offset: sendController.text.length),
      );
  }

  void clearSelectedEvents() => setState(() {
    selectedEvents.clear();
    showEmojiPicker = false;
  });

  void clearSingleSelectedEvent() {
    if (selectedEvents.length <= 1) {
      clearSelectedEvents();
    }
  }

  void _startEditingEvent(Event event, {bool clearSelection = false}) {
    final timeline = this.timeline;
    if (timeline == null) return;

    final client = currentRoomBundle.firstWhere(
      (c) => c?.userID == event.senderId,
      orElse: () => null,
    );
    if (client == null) return;

    setSendingClient(client);
    setState(() {
      pendingText = sendController.text;
      editEvent = event;
      sendController.text = event
          .getDisplayEvent(timeline)
          .calcLocalizedBodyFallback(
            MatrixLocals(L10n.of(context)),
            withSenderNamePrefix: false,
            hideReply: true,
          );
      if (clearSelection) selectedEvents.clear();
    });
    inputFocus.requestFocus();
  }

  @override
  void editSelectedEventAction() {
    _startEditingEvent(selectedEvents.first, clearSelection: true);
  }

  void _editLastSentMessage() {
    final timeline = this.timeline;
    if (timeline == null) return;

    final events = timeline.events.filterByVisibleInGui(
      threadId: activeThreadId,
    );

    final lastOwnMessage = events.firstWhereOrNull(
      (e) =>
          e.type == EventTypes.Message &&
          e.messageType == MessageTypes.Text &&
          e.status.isSent &&
          !e.redacted &&
          currentRoomBundle.any((c) => c?.userID == e.senderId),
    );

    if (lastOwnMessage == null) return;

    _startEditingEvent(lastOwnMessage);
  }

  Future<void> goToNewRoomAction() async {
    final result = await showFutureLoadingDialog(
      context: context,
      future: () async {
        final users = await room.requestParticipants(
          [Membership.join, Membership.leave],
          true,
          false,
        );
        users.sort((a, b) => a.powerLevel.level.compareTo(b.powerLevel.level));
        final via = users
            .map((user) => user.id.domain)
            .whereType<String>()
            .toSet()
            .take(10)
            .toList();
        return room.client.joinRoom(
          room
              .getState(EventTypes.RoomTombstone)!
              .parsedTombstoneContent
              .replacementRoom,
          via: via,
        );
      },
    );
    if (result.error != null) return;
    if (!mounted) return;
    context.go('/rooms/${result.result!}');

    await showFutureLoadingDialog(context: context, future: room.leave);
  }

  @override
  void onSelectMessage(Event event) {
    if (!event.redacted) {
      if (selectedEvents.contains(event)) {
        setState(() => selectedEvents.remove(event));
      } else {
        setState(() => selectedEvents.add(event));
      }
      selectedEvents.sort(
        (a, b) => a.originServerTs.compareTo(b.originServerTs),
      );
    }
  }

  @override
  int? findChildIndexCallback(Key key, Map<String, int> thisEventsKeyMap) {
    // this method is called very often. As such, it has to be optimized for speed.
    if (key is! ValueKey) {
      return null;
    }
    final eventId = key.value;
    if (eventId is! String) {
      return null;
    }
    // first fetch the last index the event was at
    final index = thisEventsKeyMap[eventId];
    if (index == null) {
      return null;
    }
    // we need to +1 as 0 is the typing thing at the bottom
    return index + 1;
  }

  @override
  void onInputBarSubmitted(String _) {
    if (sendController.value.composing.isValid &&
        !sendController.value.composing.isCollapsed)
      return;
    send();
    FocusScope.of(context).requestFocus(inputFocus);
  }

  @override
  void onAddPopupMenuButtonSelected(AddPopupMenuActions choice) {
    room.client.getConfig();

    switch (choice) {
      case AddPopupMenuActions.file:
        sendFileAction();
        return;
      case AddPopupMenuActions.image:
        sendFileAction(type: FileType.image);
        return;
      case AddPopupMenuActions.video:
        sendFileAction(type: FileType.video);
        return;
      case AddPopupMenuActions.poll:
        showAdaptiveBottomSheet(
          context: context,
          builder: (context) => StartPollBottomSheet(room: room),
        );
        return;
      case AddPopupMenuActions.photoCamera:
        openCameraAction();
        return;
      case AddPopupMenuActions.videoCamera:
        openVideoCameraAction();
        return;
      case AddPopupMenuActions.roundVideoSilent:
        final gesture = RoundCaptureGestureController(held: true)..lock();
        recordRound(gesture, silent: true).whenComplete(gesture.dispose);
        return;
      case AddPopupMenuActions.location:
        sendLocationAction();
        return;
    }
  }

  Future<void> unpinEvent(String eventId) async {
    final response = await showOkCancelAlertDialog(
      context: context,
      title: L10n.of(context).unpin,
      message: L10n.of(context).confirmEventUnpin,
      okLabel: L10n.of(context).unpin,
      cancelLabel: L10n.of(context).cancel,
    );
    if (!mounted) return;
    if (response == OkCancelResult.ok) {
      final events = room.pinnedEventIds
        ..removeWhere((oldEvent) => oldEvent == eventId);
      showFutureLoadingDialog(
        context: context,
        future: () => room.setPinnedEvents(events),
      );
    }
  }

  void pinEvent() {
    final pinnedEventIds = room.pinnedEventIds;
    final selectedEventIds = selectedEvents.map((e) => e.eventId).toSet();
    final unpin =
        selectedEventIds.length == 1 &&
        pinnedEventIds.contains(selectedEventIds.single);
    if (unpin) {
      pinnedEventIds.removeWhere(selectedEventIds.contains);
    } else {
      pinnedEventIds.addAll(selectedEventIds);
    }
    showFutureLoadingDialog(
      context: context,
      future: () => room.setPinnedEvents(pinnedEventIds),
    );
  }

  Timer? _storeInputTimeoutTimer;
  static const Duration _storeInputTimeout = Duration(milliseconds: 500);

  @override
  double? inputBarHeight;

  void updateInputBarHeight() {
    if (!mounted) return;
    RenderBox? renderBox;
    if (inputBarKey.currentContext?.findRenderObject() != null) {
      renderBox = inputBarKey.currentContext!.findRenderObject() as RenderBox;
    }

    final height = renderBox?.size.height ?? 72.0;
    if (height != inputBarHeight) {
      setState(() {
        inputBarHeight = height;
      });
    }
  }

  @override
  void onInputBarChanged(String text) {
    if (_inputTextIsEmpty != text.isEmpty) {
      setState(() {
        _inputTextIsEmpty = text.isEmpty;
      });
    }

    _storeInputTimeoutTimer?.cancel();
    if (!kIsWeb) {
      _storeInputTimeoutTimer = Timer(_storeInputTimeout, () async {
        try {
          await PersonalClient.of(room.client).saveDraft(room, text);
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'The draft could not be saved to encrypted storage.',
                ),
              ),
            );
          }
        }
      });
    }
    if (text.endsWith(' ') && Matrix.of(context).hasComplexBundles) {
      final clients = currentRoomBundle;
      for (final client in clients) {
        final prefix = client!.sendPrefix;
        if ((prefix.isNotEmpty) &&
            text.toLowerCase() == '${prefix.toLowerCase()} ') {
          setSendingClient(client);
          setState(() {
            sendController.clear();
          });
          return;
        }
      }
    }
    if (PersonalPrivacy.policy.allowTyping) {
      typingCoolDown?.cancel();
      typingCoolDown = Timer(const Duration(seconds: 2), () {
        if (!mounted) return;
        typingCoolDown = null;
        currentlyTyping = false;
        PersonalPrivacy.setTyping(room, false);
      });
      typingTimeout ??= Timer(const Duration(seconds: 30), () {
        typingTimeout = null;
        currentlyTyping = false;
      });
      if (!currentlyTyping) {
        currentlyTyping = true;
        PersonalPrivacy.setTyping(
          room,
          true,
          timeout: const Duration(seconds: 30).inMilliseconds,
        );
      }
    }
  }

  bool _inputTextIsEmpty = true;

  bool get isArchived =>
      {Membership.leave, Membership.ban}.contains(room.membership);

  @override
  void showEventInfo([Event? event]) =>
      (event ?? selectedEvents.single).showInfoDialog(context);

  @override
  void cancelReplyEventAction() => setState(() {
    if (editEvent != null) {
      sendController.text = pendingText;
      pendingText = '';
    }
    replyEvent = null;
    editEvent = null;
  });

  void startOrJoinVideoCall() {
    Matrix.of(context).activeCallRoomId.value = room.id;
  }

  bool supportLiveKitCalls = false;

  Future<void> _cancelEditWithConfirmation() async {
    final originalText = editEvent!
        .getDisplayEvent(timeline!)
        .calcLocalizedBodyFallback(
          MatrixLocals(L10n.of(context)),
          withSenderNamePrefix: false,
          hideReply: true,
        );

    if (sendController.text != originalText) {
      final result = await showOkCancelAlertDialog(
        context: context,
        title: L10n.of(context).areYouSure,
        message: L10n.of(context).discardEdits,
        okLabel: L10n.of(context).ok,
        cancelLabel: L10n.of(context).cancel,
      );
      if (result == OkCancelResult.cancel) return;
    }

    cancelReplyEventAction();
  }

  late final ValueNotifier<bool> _displayChatDetailsColumn;

  Future<void> toggleDisplayChatDetailsColumn() async {
    await AppSettings.displayChatDetailsColumn.setItem(
      !_displayChatDetailsColumn.value,
    );
    _displayChatDetailsColumn.value = !_displayChatDetailsColumn.value;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Actions(
      actions: kIsWeb
          ? {}
          : <Type, Action<Intent>>{
              PasteTextIntent: CallbackAction<PasteTextIntent>(
                onInvoke: (PasteTextIntent intent) =>
                    _handleClipboardImagePaste(),
              ),
            },
      child: Row(
        children: [
          // Header and composer glass share one backdrop read.
          Expanded(child: BackdropGroup(child: ChatView(this))),
          ValueListenableBuilder(
            valueListenable: _displayChatDetailsColumn,
            builder: (context, displayChatDetailsColumn, _) =>
                !FluffyThemes.isThreeColumnMode(context) ||
                    room.membership != Membership.join ||
                    !displayChatDetailsColumn
                ? const SizedBox(height: double.infinity, width: 0)
                : Container(
                    width: FluffyThemes.columnWidth,
                    clipBehavior: Clip.hardEdge,
                    decoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(width: 1, color: theme.dividerColor),
                      ),
                    ),
                    child: ChatDetails(
                      roomId: roomId,
                      embeddedCloseButton: IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: toggleDisplayChatDetailsColumn,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

enum AddPopupMenuActions {
  image,
  video,
  file,
  poll,
  photoCamera,
  videoCamera,
  roundVideoSilent,
  location,
}

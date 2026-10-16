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
import 'package:fluffychat/pages/chat/event_info_dialog.dart';
import 'package:fluffychat/pages/chat/start_poll_bottom_sheet.dart';
import 'package:fluffychat/pages/chat/trust_user_key_dialog.dart';
import 'package:fluffychat/pages/chat/utils/web_file_to_x_file.dart';
import 'package:fluffychat/pages/chat_details/chat_details.dart';
import 'package:fluffychat/personal/capabilities.dart';
import 'package:fluffychat/personal/immediate_outbox.dart';
import 'package:fluffychat/personal/media/immediate_media_outbox.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/personal/round_video/round_capture_controller.dart';
import 'package:fluffychat/personal/round_video/telegram_media_protocol.dart';
import 'package:fluffychat/personal/round_video/telegram_round_service.dart';
import 'package:fluffychat/personal/round_video/telegram_room_binding.dart';
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
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/mxc_image.dart';
import 'package:fluffychat/widgets/share_scaffold_dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:mime/mime.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:personal_core/personal_core.dart'
    show RoundVideoDescriptor, RoundMediaPolicy;
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:universal_html/universal_html.dart' as web;

import '../../utils/account_bundles.dart';
import '../../utils/localized_exception_extension.dart';
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
    with WidgetsBindingObserver {
  Room get room => sendingClient.getRoomById(roomId) ?? widget.room;

  late Client sendingClient;

  Timeline? timeline;

  String? activeThreadId;

  late final Set<String> bigEmojis;

  late final String readMarkerEventId;

  String get roomId => widget.room.id;

  final AutoScrollController scrollController = AutoScrollController();

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

    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: details.files,
        room: room,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
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

  List<Event> selectedEvents = [];

  final Set<String> unfolded = {};

  Event? replyEvent;

  Event? editEvent;

  bool _scrolledUp = false;

  bool get showScrollDownButton =>
      _scrolledUp || timeline?.allowNewEvent == false;

  bool get selectMode => selectedEvents.isNotEmpty;

  final int _loadHistoryCount = 100;

  String pendingText = '';

  bool showEmojiPicker = false;

  String? get threadLastEventId {
    final threadId = activeThreadId;
    if (threadId == null) return null;
    return timeline?.events
        .filterByVisibleInGui(threadId: threadId)
        .firstOrNull
        ?.eventId;
  }

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

  String? historyError;
  bool historyLoading = false;
  final _historyPositions = <(Timeline, int, String?, String?)>{};
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
    final proceed = await showTrustUserInRoomDialog(context, room);
    if (!mounted || !proceed) return;
    for (final item in shareItems) {
      if (item is FileShareItem) continue;
      if (item is TextShareItem) room.sendTextEvent(item.value);
      if (item is ContentShareItem) room.sendEvent(item.value.copy());
    }
    final files = shareItems
        .whereType<FileShareItem>()
        .map((item) => item.value)
        .toList();
    if (files.isEmpty) return;
    showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: files,
        room: room,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
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

    bigEmojis = defaultEmojiSet.fold(
      <String>{},
      (emojis, category) => {
        ...emojis,
        ...(category.emoji.map((emoji) => emoji.emoji)),
      },
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

  Future<void> _checkMatrixRtcCallSupport() async {
    try {
      final urls = await room.client.getLiveKitServiceUrls();
      if (!mounted || urls.isEmpty) return;
      setState(() {
        supportLiveKitCalls = true;
      });
    } catch (e) {
      Logs().d('Unable to check MatrixRTC call support', e);
    }
  }

  final Set<String> expandedEventIds = {};

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

  String? animateInEventId;

  Future<void> _insert(int index) async {
    if (index > 0) return;
    final firstEvent = timeline?.events.firstOrNull;
    final eventId = firstEvent?.transactionId ?? firstEvent?.eventId;
    animateInEventId = eventId;
    await Future.delayed(FluffyThemes.animationDuration);
    if (animateInEventId == eventId) animateInEventId = null;
  }

  void updateView() {
    if (!mounted) return;
    setReadMarker();
    setState(() {});
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

  TextEditingController sendController = TextEditingController();

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
  Future<void> send() async {
    if (_personalSending) return;
    _personalSending = true;
    try {
      await _sendPersonal();
    } finally {
      _personalSending = false;
    }
  }

  Future<void> _sendPersonal() async {
    final frozenRoom = room;
    final frozenText = sendController.text;
    final frozenReply = replyEvent;
    final frozenEdit = editEvent;
    final frozenThread = activeThreadId;
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

    final proceed = await showTrustUserInRoomDialog(context, room);
    if (!mounted || !proceed) return;
    if (sendController.text.trim().isEmpty) return;
    _storeInputTimeoutTimer?.cancel();

    var parseCommands = true;

    final commandMatch = RegExp(r'^\/(\w+)').firstMatch(sendController.text);
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
      if (dialogResult == OkCancelResult.cancel) return;
      parseCommands = false;
    }

    if (currentlyTyping) {
      typingCoolDown?.cancel();
      currentlyTyping = false;
      PersonalPrivacy.setTyping(room, false);
    }

    _personalSending = true;
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
      final nextText = mounted && sendController.text != frozenText
          ? sendController.text
          : pendingText;
      var draftStored = false;
      try {
        await personal.saveDraft(frozenRoom, nextText);
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
        await personal.completeImmediate(result.actionId);
      }
      if (!mounted || room != frozenRoom) return;
      setState(() {
        sendController.text = nextText;
        _inputTextIsEmpty = nextText.isEmpty;
        replyEvent = null;
        editEvent = null;
        pendingText = '';
      });
    } finally {
      _personalSending = false;
    }
  }

  Future<void> sendFileAction({FileType type = FileType.any}) async {
    final files = await selectFiles(context, allowMultiple: true, type: type);
    if (files.isEmpty) return;
    if (!mounted) return;
    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: files,
        room: room,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
  }

  Future<void> sendImageFromClipBoard(Uint8List? image) async {
    if (image == null) return;
    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: [XFile.fromData(image)],
        room: room,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
  }

  Future<void> openGalleryAction() async {
    inputFocus.unfocus();
    final files = await ImagePicker().pickMultipleMedia(
      requestFullMetadata: false,
    );
    if (files.isEmpty) return;
    if (!mounted) return;

    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: files,
        room: room,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
  }

  Future<void> openCameraAction() async {
    inputFocus.unfocus();
    final file = await ImagePicker().pickImage(source: ImageSource.camera);
    if (file == null) return;
    if (!mounted) return;

    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: [file],
        room: room,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
  }

  Future<void> _handleClipboardFilePasteWeb(web.Event event) async {
    if (event is! web.ClipboardEvent) return;

    final clipboardFiles = event.clipboardData?.files;
    final length = clipboardFiles?.length ?? 0;
    if (clipboardFiles == null || length < 1) return;

    // Browser will clear clipboardData when we await!
    // We MUST extract the files synchronously first.
    final localFiles = clipboardFiles.toList();

    if (localFiles.isEmpty) return;

    event.preventDefault();
    event.stopPropagation();

    final xFilesResult = await showFutureLoadingDialog(
      context: context,
      future: () async {
        // Convert one after another seems to be more stable
        final xFiles = <XFile>[];
        for (final file in localFiles) {
          xFiles.add(await webToXFile(file));
        }
        return xFiles;
      },
    );
    final xFiles = xFilesResult.result;
    if (xFiles == null || xFiles.isEmpty) return;

    if (!mounted) return;
    showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: xFiles,
        room: room,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
  }

  Future<void> _handleClipboardImagePaste() async {
    final files = await Pasteboard.files();
    if (files.isNotEmpty) {
      if (!mounted) return;
      await showAdaptiveDialog(
        context: context,
        builder: (c) => SendFileDialog(
          files: files.map(XFile.new).toList(),
          room: room,
          outerContext: context,
          threadRootEventId: activeThreadId,
          threadLastEventId: threadLastEventId,
        ),
      );
      return;
    }
    final image = await Pasteboard.image;
    if (image != null) {
      await sendImageFromClipBoard(image);
      return;
    }
    // No image in clipboard — fall back to pasting text
    final textData = await Clipboard.getData('text/plain');
    if (textData?.text != null) {
      final selection = sendController.selection;
      final text = sendController.text;
      final newText = text.replaceRange(
        selection.start,
        selection.end,
        textData!.text!,
      );
      sendController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(
          offset: selection.start + textData.text!.length,
        ),
      );
      onInputBarChanged(sendController.text);
    }
  }

  Future<void> openVideoCameraAction() async {
    inputFocus.unfocus();
    final file = await ImagePicker().pickVideo(
      source: ImageSource.camera,
      maxDuration: const Duration(minutes: 1),
    );
    if (file == null) return;
    if (!mounted) return;

    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: [file],
        room: room,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
  }

  Future<void> onVoiceMessageSend(
    String path,
    int duration,
    List<int> waveform,
    String fileName,
  ) async {
    final proceed = await showTrustUserInRoomDialog(context, room);
    if (!mounted || !proceed) return;
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final audioFile = XFile(path);

    final bytesResult = await showFutureLoadingDialog(
      context: context,
      future: audioFile.readAsBytes,
    );
    final bytes = bytesResult.result;
    if (bytes == null) return;

    final mimeType = lookupMimeType(fileName, headerBytes: bytes);
    final extension = mimeType == null ? null : extensionFromMime(mimeType);
    if (extension != null) {
      fileName =
          'voice_message_${DateTime.now().millisecondsSinceEpoch}.$extension';
    }

    final file = MatrixAudioFile(
      bytes: bytes,
      name: fileName,
      mimeType: mimeType,
    );

    try {
      await room.sendFileEvent(
        file,
        inReplyTo: replyEvent,
        threadRootEventId: activeThreadId,
        extraContent: {
          'info': {...file.info, 'duration': duration},
          'org.matrix.msc3245.voice': {},
          'org.matrix.msc1767.audio': {
            'duration': duration,
            'waveform': waveform,
          },
        },
      );
    } catch (e) {
      if (!mounted) return;
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text(e.toLocalizedString(context))),
      );
      return;
    }
    setState(() {
      replyEvent = null;
    });
    return;
  }

  void hideEmojiPicker() {
    setState(() => showEmojiPicker = false);
  }

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

  bool get roundRecordingMode =>
      PlatformInfos.isAndroid &&
      PersonalClient.networkOf(room) == 'telegram' &&
      AppSettings.personalRoundRecordingMode.value;

  Future<void> toggleRoundRecordingMode() async {
    await AppSettings.personalRoundRecordingMode.setItem(
      !AppSettings.personalRoundRecordingMode.value,
    );
    if (mounted) setState(() {});
  }

  bool get canRecordRoundSilently =>
      PlatformInfos.isAndroid &&
      TelegramRoomBinding.of(
            room,
          )?.capabilities(room).extension.operation('silent_send').allowed ==
          true;

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
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Round videos require trusted support from the new Telegram bridge, encryption and available storage.',
            ),
          ),
        );
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

  void replyAction({Event? replyTo}) {
    setState(() {
      replyEvent = replyTo ?? selectedEvents.first;
      selectedEvents.clear();
    });
    inputFocus.requestFocus();
  }

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

  void onInputBarSubmitted(String _) {
    if (sendController.value.composing.isValid &&
        !sendController.value.composing.isCollapsed)
      return;
    send();
    FocusScope.of(context).requestFocus(inputFocus);
  }

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

  void showEventInfo([Event? event]) =>
      (event ?? selectedEvents.single).showInfoDialog(context);

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
          Expanded(child: ChatView(this)),
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

// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/config/themes.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat_event_list.dart'
    show conversationReadMarkerRow, conversationUnreadCount;
import 'package:chatloom/pages/chat/chat_message_actions.dart';
import 'package:chatloom/pages/chat/chat_timeline_preload.dart';
import 'package:chatloom/pages/chat/chat_view.dart';
import 'package:chatloom/pages/chat/compact_composer.dart'
    show ConversationSourceChip;
import 'package:chatloom/pages/chat/composer_keyboard.dart';
import 'package:chatloom/pages/chat/conversation_message_actions.dart';
import 'package:chatloom/pages/chat/composer_send_later.dart';
import 'package:chatloom/pages/chat/conversation_message_menu.dart';
import 'package:chatloom/pages/chat/conversation_motion.dart';
import 'package:chatloom/pages/chat/conversation_navigation.dart';
import 'package:chatloom/pages/chat/conversation_search.dart';
import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/pages/chat/event_info_dialog.dart';
import 'package:chatloom/pages/chat/events/message.dart';
import 'package:chatloom/pages/chat/events/message_delivery_status.dart';
import 'package:chatloom/pages/chat/message_deletion.dart';
import 'package:chatloom/pages/chat/start_poll_bottom_sheet.dart';
import 'package:chatloom/pages/chat/trust_user_key_dialog.dart';
import 'package:chatloom/pages/chat/utils/web_file_to_x_file.dart';
import 'package:chatloom/pages/chat/voice_message_sender.dart';
import 'package:chatloom/pages/chat_details/chat_details.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/composer_commands.dart';
import 'package:chatloom/personal/copy_notice.dart';
import 'package:chatloom/personal/developer_options.dart';
import 'package:chatloom/personal/hidden_messages.dart';
import 'package:chatloom/personal/immediate_outbox.dart';
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/personal/media/gallery_content.dart';
import 'package:chatloom/personal/network_chat_actions.dart';
import 'package:chatloom/personal/network_rejections.dart';
import 'package:chatloom/personal/performance_probe.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/personal_hub.dart' show RoomPersonalButton;
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/round_video/round_availability.dart';
import 'package:chatloom/personal/round_video/round_capture_controller.dart';
import 'package:chatloom/personal/round_video/telegram_media_protocol.dart';
import 'package:chatloom/personal/round_video/telegram_room_binding.dart';
import 'package:chatloom/personal/round_video/telegram_round_service.dart';
import 'package:chatloom/personal/seen_chat_notifications.dart';
import 'package:chatloom/personal/send_warmup.dart';
import 'package:chatloom/personal/text_split.dart';
import 'package:chatloom/personal/ui/forward_sheet.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/error_reporter.dart';
import 'package:chatloom/utils/file_selector.dart';
import 'package:chatloom/utils/localized_exception_extension.dart';
import 'package:chatloom/utils/macos_desktop.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:chatloom/utils/other_party_can_receive.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:chatloom/widgets/app_lock.dart';
import 'package:chatloom/widgets/future_loading_dialog.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:chatloom/widgets/share_scaffold_dialog.dart';
import 'package:collection/collection.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
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

  const ChatPage({
    super.key,
    required this.roomId,
    this.eventId,
    this.shareItems,
    this.timeline,
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
      key: Key('chat_page_${roomId}_$eventId'),
      room: room,
      shareItems: shareItems,
      eventId: eventId,
      timeline: timeline,
    );
  }
}

class ChatPageWithRoom extends StatefulWidget {
  final Room room;
  final List<ShareItem>? shareItems;
  final String? eventId;
  final Timeline? timeline;

  const ChatPageWithRoom({
    super.key,
    required this.room,
    this.shareItems,
    this.eventId,
    this.timeline,
  });

  @override
  ChatController createState() => ChatController();
}

class ChatController extends State<ChatPageWithRoom>
    with WidgetsBindingObserver
    implements
        ConversationTimelineSource,
        ConversationComposerHost,
        ComposerSendLaterHost {
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

  /// Media and files can be saved from the message menu (voice and audio
  /// included) once sent; an unsent file is still on this device.
  bool canSaveEvent(Event event) =>
      !event.redacted &&
      event.status.isSent &&
      {
        MessageTypes.Video,
        MessageTypes.Image,
        MessageTypes.Sticker,
        MessageTypes.Audio,
        MessageTypes.File,
      }.contains(event.messageType);

  @override
  Event? replyEvent;

  final VoiceMessageSender _voiceSender = VoiceMessageSender();

  @override
  Event? editEvent;

  bool _scrolledUp = false;

  bool get showScrollDownButton =>
      _scrolledUp || timeline?.allowNewEvent == false;

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
  List<Event>? get conversationEvents {
    final timeline = this.timeline;
    if (timeline == null) return null;
    final events = timeline.events;
    // The list, its header and the typing row read this several times per
    // build; filter once per timeline change. In-place timeline changes
    // (decryption, status, redaction) always end in [updateView], which
    // bumps the revision.
    final key = (
      timeline,
      _timelineRevision,
      activeThreadId,
      events.length,
      events.firstOrNull,
      events.firstOrNull?.status,
      events.lastOrNull,
    );
    final cached = _conversationEvents;
    if (cached != null && _conversationEventsKey == key) return cached;
    _conversationEventsKey = key;
    return _conversationEvents = List.unmodifiable(
      events.filterByVisibleInGui(threadId: activeThreadId),
    );
  }

  List<Event>? _conversationEvents;
  Object? _conversationEventsKey;

  /// Bumped whenever something the timeline rows render changes. The list
  /// gate in [ChatView] rebuilds the rows only then, so composer keystrokes,
  /// send state, the jump button and notices never rebuild message rows.
  int _timelineRevision = 0;
  int get timelineRevision => _timelineRevision;

  /// [setState] for state the timeline rows render: events, history and
  /// thread switches, collapsed runs, the jump highlight, a failed load.
  /// Everything else (composer, header) uses plain [setState].
  void _hiddenMessagesChanged() {
    if (mounted) setTimelineState(() {});
  }

  void setTimelineState(VoidCallback fn) {
    _timelineRevision++;
    setState(fn);
    _syncJumpButton();
  }

  /// Whether the jump-to-latest button shows. A listenable, so scrolling
  /// away from the newest message never rebuilds the page.
  final ValueNotifier<bool> jumpButtonVisible = ValueNotifier(false);

  void _syncJumpButton() => jumpButtonVisible.value = showScrollDownButton;

  /// True while the chat positions a freshly opened list at the first
  /// unread message; the list is laid out but invisible meanwhile.
  final ValueNotifier<bool> timelineHold = ValueNotifier(false);

  /// The timeline could not be loaded: the list shows "Couldn't load
  /// messages" with Try again (never a dialog).
  bool timelineLoadFailed = false;

  /// The timeline the inbox started loading on tap (see
  /// [ChatTimelinePreload]); adopted by [_tryLoadTimeline].
  ChatTimelinePreload? _preload;

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

  bool _futureFailed = false;

  /// A chat opened around its first unread message loads newer messages as
  /// the user reads down (Telegram), until a load fails.
  @override
  bool get autoLoadFuture =>
      canLoadFuture && !isLoadingFuture && !_futureFailed;

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

  /// The conversation menu's actions for the current source (Send later,
  /// Remind me), offered again by a long press on Send.
  RoomPersonalButton _personalActions() {
    final source = room;
    return RoomPersonalButton(
      room: source,
      composer: sendController,
      readCutoff: () => personalSeenEventId,
      replyEvent: () => replyEvent,
      isEditing: () => editEvent != null,
      threadRootEventId: () => activeThreadId,
      threadLastEventId: () => threadLastEventId,
      isCurrentSource: () => mounted && identical(room, source),
      clearScheduledReply: cancelReplyEventAction,
    );
  }

  @override
  Future<void> composerSendLater() =>
      _personalActions().run(context, 'schedule');

  @override
  Future<void> composerRemindMe() =>
      _personalActions().run(context, 'reminder');

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

  void enterThread(String eventId) => setTimelineState(() {
    activeThreadId = eventId;
  });

  void closeThread() => setTimelineState(() {
    activeThreadId = null;
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
    setTimelineState(() {
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
      if (mounted) setTimelineState(() => historyLoading = false);
    }
  }

  @override
  Future<void> requestFuture({bool quiet = false}) async {
    final timeline = this.timeline;
    if (timeline == null) return;
    Logs().v('Requesting future...');

    final mostRecentEvent = timeline.events.filterByVisibleInGui().firstOrNull;

    try {
      await timeline.requestFuture(historyCount: _loadHistoryCount);
      _futureFailed = false;
    } catch (error, stack) {
      // The SDK leaves its flag set after a failure, which would keep the
      // "load newer" button spinning forever.
      timeline.isRequestingFuture = false;
      // Automatic loading stops until the user taps "Load more".
      _futureFailed = true;
      if (!mounted) return;
      setTimelineState(() {});
      // An automatic load fails silently: "Load more" stays for a retry.
      if (quiet) return;
      await ErrorReporter.action(
        context,
        action: ErrorAction.load,
        onRetry: requestFuture,
      ).onErrorCallback(error, stack);
      return;
    }

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
    // Runs on every scroll notification; only the jump button follows the
    // flip (a listenable), the page and the rows never rebuild for it.
    final scrolledUp =
        timeline?.allowNewEvent == false ||
        scrollController.position.pixels > 0;
    if (scrolledUp == _scrolledUp) return;
    _scrolledUp = scrolledUp;
    _syncJumpButton();
    if (!scrolledUp) setReadMarker();
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
      _savedDraft = draft ?? '';
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
      // The themed snackbar (dock tone, hairline), not a translucent red
      // block over the chat.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.of(context).otherPartyNotLoggedIn),
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
      // The bubble shows the send; a refusal the SDK rethrows is explained.
      if (item is TextShareItem) {
        unawaited(
          // Shared text is a message, never a command.
          frozen.room
              .sendTextEvent(item.value, parseCommands: false)
              .then<void>((_) {}, onError: _reportSendFailure),
        );
      }
      if (item is ContentShareItem) {
        unawaited(
          frozen.room
              .sendEvent(item.value.copy())
              .then<void>((_) {}, onError: _reportSendFailure),
        );
      }
    }
    final files = shareItems
        .whereType<FileShareItem>()
        .map((item) => item.value)
        .toList();
    if (files.isEmpty) return;
    await _pickAttachments(() async => files);
  }

  KeyEventResult _customEnterKeyHandling(FocusNode node, KeyEvent evt) {
    final keyboard = HardwareKeyboard.instance;
    // A bare ↑ only: ⌘↑ and ⌥↑ are scroll and chat-switching shortcuts.
    if (evt is KeyDownEvent &&
        evt.logicalKey == LogicalKeyboardKey.arrowUp &&
        !PlatformInfos.isMobile &&
        !keyboard.isMetaPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isControlPressed &&
        !keyboard.isShiftPressed &&
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
    // Telegram Desktop: Esc drops the reply being written.
    if (evt is KeyDownEvent &&
        evt.logicalKey == LogicalKeyboardKey.escape &&
        replyEvent != null &&
        !PlatformInfos.isMobile) {
      cancelReplyEventAction();
      return KeyEventResult.handled;
    }

    // Enter confirming an IME candidate belongs to the editor, never send.
    if (evt.logicalKey.keyLabel == 'Enter' &&
        sendController.value.composing.isValid &&
        !sendController.value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    // ⌘↩ always sends (Telegram, Slack), also with "Send on enter" off.
    if (!keyboard.isShiftPressed &&
        evt.logicalKey.keyLabel == 'Enter' &&
        (AppSettings.sendOnEnter.value ||
            (keyboard.isMetaPressed && !PlatformInfos.isMobile))) {
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
    scrollController.addListener(_jumpButtonScroll);
    inputFocus.addListener(_inputFocusListener);

    sendingClient = widget.room.client;
    // A network refusing a reaction, edit or deletion is said here.
    _rejections = NetworkRejectionWatcher(
      widget.room.client,
      rooms: () => {roomId},
      notify: (text) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(text)));
        }
      },
    );
    if (PlatformInfos.isMacOS) {
      MacDesktopCommands.bindChat(
        this,
        MacChatCommands(
          searchInChat: openSearch,
          scrollToTop: () {
            if (!scrollController.hasClients) return;
            scrollController.jumpTo(scrollController.position.maxScrollExtent);
          },
          scrollToBottom: () => unawaited(scrollDown()),
          typeIntoComposer: (text) => typeIntoComposer(this, text),
          // Esc = Back: the page's PopScope cancels a reply, edit, panel
          // or thread first (Telegram Desktop), then the chat closes.
          escape: () {
            if (!mounted) return false;
            unawaited(Navigator.maybePop(context));
            return true;
          },
        ),
      );
    }
    // A search hit in Chat details comes back here instead of a new page.
    ConversationJumpTargets.register(
      this,
      covers: (room) =>
          room.id == roomId && identical(room.client, this.room.client),
      jump: (event) => scrollToEventId(event.eventId),
    );
    _loadDraft();
    // "Remove for you" (FX-16): refilter the rows when it changes.
    HiddenMessages.instance
      ..load(widget.room.client)
      ..addListener(_hiddenMessagesChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _openProbe.mark('first_frame');
      NotionMotion.afterRouteSettled(context, () => _openProbe.mark('route'));
      _shareItems();
      // The first send must not wait for the member list (trust check);
      // loaded once the opening slide has finished.
      warmUpSendPath(room, route: ModalRoute.of(context)?.animation);
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
    final preload = widget.timeline == null
        ? ChatTimelinePreload.take(widget.room)
        : null;
    if (preload != null && widget.eventId == null) {
      preload.adopt(onUpdate: updateView, onInsert: _insert);
      _preload = preload;
    } else {
      preload?.discard();
    }
    _tryLoadTimeline();
  }

  bool _inviteJoinStarted = false;

  /// Accepts a pending invite once per page. The view asks on every build;
  /// a rebuild while the join is in flight must not stack another dialog or
  /// send a parallel join. A failed join is reported once, not retried in a
  /// loop.
  void joinInviteOnce() {
    if (_inviteJoinStarted || room.membership != Membership.invite) return;
    _inviteJoinStarted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || room.membership != Membership.invite) return;
      showFutureLoadingDialog(
        context: context,
        future: () => room.join(),
        exceptionContext: ExceptionContext.joinRoom,
      );
    });
  }

  @override
  final Set<String> expandedEventIds = {};

  @override
  void expandEventsFrom(Event event, bool expand) {
    final events = timeline!.events.filterByVisibleInGui(
      threadId: activeThreadId,
    );
    final start = events.indexOf(event);
    setTimelineState(() {
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

  /// `chat_open.*` probe points, from this page's creation (the tap).
  final _openProbe = PersonalPerformanceProbe.span('chat_open');

  Future<void> _tryLoadTimeline() async {
    final initialEventId = widget.eventId;
    final preload = _preload;
    _preload = null;
    final ready = preload?.timeline;
    if (ready != null) {
      // Loaded on tap (Telegram): the very first frame has the rows, so the
      // page slides in with its messages instead of a placeholder.
      _adoptTimeline(ready, room);
      loadTimelineFuture = Future<void>.value();
    } else {
      _loadTimeline(preload: preload);
    }
    // Decided before the rows are first built: a chat that opens far above
    // its newest message stays invisible until it is positioned there.
    void holdIfFarUnread() {
      if (initialEventId == null &&
          timeline != null &&
          _firstUnreadRow() >= _holdUnreadRows) {
        timelineHold.value = true;
      }
    }

    holdIfFarUnread();
    try {
      await loadTimelineFuture;
      if (!mounted || timeline == null) return;
      // Runs before the load's rebuild (this listener was registered first).
      if (!timelineHold.value) holdIfFarUnread();
      _openProbe
        ..mark('timeline')
        ..markAfterFrame('rows');
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
        timelineHold.value = false;
        await timeline?.requestHistory(historyCount: _loadHistoryCount);
        if (!mounted || timeline == null) return;
        readMarkerEventIndex = timeline!.events
            .filterByVisibleInGui(
              exceptionEventId: readMarkerEventId,
              threadId: activeThreadId,
            )
            .indexWhere((e) => e.eventId == readMarkerEventId);
      }

      // Still not loaded (a busy group): open on the history around the
      // read marker, as Telegram does, instead of at the newest message.
      if (readMarkerEventId.isNotEmpty && readMarkerEventIndex == -1) {
        readMarkerEventIndex = await _loadAroundReadMarker();
        if (!mounted || timeline == null) return;
      }

      if (readMarkerEventIndex > 1) {
        Logs().v('Open at the first unread message');
        await _openAtUnread();
      } else if (readMarkerEventId.isNotEmpty && readMarkerEventIndex == -1) {
        // The context could not load: offer the way up instead.
        _showScrollUpMaterialBanner(readMarkerEventId);
      }

      // Mark room as read on first visit if requirements are fulfilled
      setReadMarker();

      if (!mounted) return;
    } catch (e, s) {
      // History or positioning failed: the chat stays usable where it is.
      logBackgroundError('timeline_open', e, s);
    } finally {
      if (mounted) timelineHold.value = false;
    }
  }

  /// Unread rows from which a freshly opened chat is positioned while
  /// invisible; fewer usually fit on the first screen.
  static const int _holdUnreadRows = 6;

  /// Replaces the timeline by the history around the read marker (the
  /// event-context path of [scrollToEventId]) while the list stays hidden.
  /// Returns the marker's row index in it, or -1 when the context did not
  /// load (the live timeline is kept then).
  Future<int> _loadAroundReadMarker() async {
    timelineHold.value = true;
    setTimelineState(() {
      timeline?.cancelSubscriptions();
      timeline = null;
      _scrolledUp = false;
      _loadTimeline(eventContextId: readMarkerEventId);
    });
    await loadTimelineFuture;
    if (!mounted || timeline == null) return -1;
    return timeline!.events
        .filterByVisibleInGui(
          exceptionEventId: readMarkerEventId,
          threadId: activeThreadId,
        )
        .indexWhere((e) => e.eventId == readMarkerEventId);
  }

  /// The oldest unread row (above which "N unread messages" sits), or -1.
  int _firstUnreadRow() {
    final rows = conversationEvents;
    if (rows == null || readMarkerEventId.isEmpty) return -1;
    final marker = conversationReadMarkerRow(
      rows,
      readMarkerEventId,
      timelineEvents: timeline?.events,
    );
    return conversationUnreadCount(rows, marker) > 0 ? marker - 1 : -1;
  }

  /// The first unread message the jump button still goes to before the
  /// newest one (Telegram's page-down order); null once seen or passed.
  String? _unreadJumpEventId;

  /// Opens at the first unread message: the divider sits right under the
  /// header (Telegram, Signal) and the jump button counts what is below.
  Future<void> _openAtUnread() async {
    final row = _firstUnreadRow();
    final rows = conversationEvents;
    if (row < 0 || rows == null) return;
    final eventId = rows[row].eventId;
    // Let the rows be laid out first.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !scrollController.hasClients) return;
    if (!await _revealUnread(eventId, animate: false)) return;
    if (!mounted || !scrollController.hasClients) return;
    if (scrollController.position.pixels > 0) {
      _unreadJumpEventId = eventId;
      final loaded = conversationUnreadCount(
        rows,
        conversationReadMarkerRow(
          rows,
          readMarkerEventId,
          timelineEvents: timeline?.events,
        ),
      );
      // A context timeline holds only part of the unread run.
      newBelow.value = timeline?.allowNewEvent == false
          ? math.max(loaded, room.notificationCount)
          : loaded;
    }
  }

  /// Scrolls so the row of [eventId] (the oldest unread message, with the
  /// "N unread messages" divider on top) sits right under the glass header.
  /// [animate]: glide like the jump button; otherwise jump (opening).
  Future<bool> _revealUnread(String eventId, {required bool animate}) {
    final index =
        conversationEvents?.indexWhere((e) => e.eventId == eventId) ?? -1;
    return conversationRevealRow(
      context,
      scrollController,
      index,
      animate: animate,
    );
  }

  /// Whether the row of [eventId] is below the visible part of the list.
  bool _rowBelowViewport(String eventId) {
    final index =
        conversationEvents?.indexWhere((e) => e.eventId == eventId) ?? -1;
    if (index < 0 || !scrollController.hasClients) return false;
    final viewport = scrollController.position.context.storageContext
        .findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return false;
    final visible = viewport.localToGlobal(Offset.zero) & viewport.size;
    int? newestVisible;
    for (final entry in scrollController.tagMap.entries) {
      final box = entry.value.context.findRenderObject();
      if (box is! RenderBox || !box.hasSize || !box.attached) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (!visible.overlaps(rect)) continue;
      if (newestVisible == null || entry.key < newestVisible) {
        newestVisible = entry.key;
      }
    }
    return newestVisible != null && index < newestVisible;
  }

  String? scrollUpBannerEventId;

  void discardScrollUpBannerEventId() => setState(() {
    scrollUpBannerEventId = null;
  });

  void _showScrollUpMaterialBanner(String eventId) => setState(() {
    scrollUpBannerEventId = eventId;
  });

  /// "First unread": the read marker could not be loaded on open.
  void jumpToFirstUnread() {
    final eventId = scrollUpBannerEventId;
    if (eventId == null) return;
    discardScrollUpBannerEventId();
    unawaited(scrollToEventId(eventId));
  }

  // -------------------------------------------------------------------------
  // In-chat search (FX-03).

  ConversationSearchController? _search;
  bool _searchShown = false;

  /// Created on the first search; most chats are never searched.
  ConversationSearchController get search =>
      _search ??= ConversationSearchController(
        rooms: () => [room],
        loaded: () => timeline?.events ?? const <Event>[],
        jump: (event) => scrollToEventId(event.eventId),
      )..addListener(_searchChanged);

  bool get searchActive => _search?.active ?? false;

  /// Only entering and leaving search rebuild the page (header, composer
  /// slot); typing and stepping rebuild the search widgets alone.
  void _searchChanged() {
    final shown = searchActive;
    if (shown == _searchShown || !mounted) return;
    _searchShown = shown;
    setState(() {});
  }

  /// ⌘F, the ⋯ menu's "Search conversation": the header becomes the field.
  void openSearch() {
    if (!mounted) return;
    if (activeThreadId != null) closeThread();
    if (showEmojiPicker) hideEmojiPicker();
    inputFocus.unfocus();
    search.open();
  }

  void closeSearch() => _search?.close();

  // -------------------------------------------------------------------------
  // Unread mentions (FX-11).

  final Set<String> _handledMentions = {};

  /// Mentions this page already went to (the "@" count subtracts them).
  final ValueNotifier<int> mentionsHandled = ValueNotifier(0);

  /// The "@" button: the oldest unread message that mentions the user,
  /// paging back (up to five pages) while the read marker is not loaded.
  Future<void> jumpToMention() async {
    final marker = readMarkerEventId.isEmpty
        ? room.fullyRead
        : readMarkerEventId;
    int markerRow() {
      final rows = conversationEvents ?? const <Event>[];
      return conversationReadMarkerRow(
        rows,
        marker,
        timelineEvents: timeline?.events,
      );
    }

    for (var page = 0; page < 5 && markerRow() < 0; page++) {
      if (!canLoadHistory || historyError != null) break;
      await requestHistory();
      if (!mounted) return;
    }
    final rows = conversationEvents ?? const <Event>[];
    final mentions = conversationUnreadMentions(
      rows,
      markerRow(),
      highlighted: conversationHighlights,
      handled: _handledMentions,
    );
    if (mentions.isEmpty) {
      // The server still counts mentions this device cannot find: settle
      // the count and show the first unread message instead.
      mentionsHandled.value = math.max(
        mentionsHandled.value,
        room.highlightCount,
      );
      final unread = _firstUnreadRow();
      if (unread >= 0) {
        await _revealUnread(rows[unread].eventId, animate: true);
      }
      return;
    }
    final target = mentions.first;
    _handledMentions.add(target.eventId);
    mentionsHandled.value = _handledMentions.length;
    await scrollToEventId(target.eventId);
  }

  // -------------------------------------------------------------------------
  // Jump to date (FX-11).

  /// The day chip, the floating date pill and the search bar's calendar.
  @override
  Future<void> pickJumpDate([DateTime? around]) async {
    final day = await pickConversationDay(context, around ?? DateTime.now());
    if (day == null || !mounted) return;
    await jumpToDay(day);
  }

  /// Shows the first message of [day] (or the next one after it) right
  /// under the header: from the loaded rows, else the history around the
  /// server's event for that time, else paging back.
  Future<void> jumpToDay(DateTime day) async {
    if (await _revealDay(day)) return;
    final start = DateTime(day.year, day.month, day.day);
    String? eventId;
    try {
      eventId = (await room.client.getEventByTimestamp(
        room.id,
        start.millisecondsSinceEpoch,
        Direction.f,
      )).eventId;
    } catch (_) {
      // Older servers lack the endpoint: page back below.
    }
    if (!mounted) return;
    if (eventId != null && _rowIndexFor(eventId) < 0) {
      timelineHold.value = true;
      try {
        setTimelineState(() {
          timeline?.cancelSubscriptions();
          timeline = null;
          _scrolledUp = false;
          _loadTimeline(eventContextId: eventId);
        });
        await loadTimelineFuture;
        if (!mounted) return;
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
        if (await _revealDay(day)) return;
      } finally {
        if (mounted) timelineHold.value = false;
      }
    }
    for (var page = 0; page < 10 && canLoadHistory; page++) {
      if (historyError != null) break;
      await requestHistory();
      if (!mounted) return;
      if (await _revealDay(day)) return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Couldn’t load messages from that day.')),
    );
  }

  Future<bool> _revealDay(DateTime day) async {
    final rows = conversationEvents;
    if (rows == null || rows.isEmpty) return false;
    if (!conversationRowsReachDay(rows, day) && canLoadHistory) return false;
    final index = conversationRowForDay(rows, day);
    if (index < 0) {
      // After the newest message: the bottom of the chat.
      await scrollDown();
      return true;
    }
    return conversationRevealRow(
      context,
      scrollController,
      index,
      animate: true,
    );
  }

  @override
  String? animateInEventId;

  /// New messages that arrived below while scrolled up (the jump badge).
  final ValueNotifier<int> newBelow = ValueNotifier(0);

  /// Telegram's way back: messages a quote jump left, newest last. The jump
  /// button returns to them before it goes to the latest messages.
  final List<String> _returnStack = [];
  bool _returning = false;

  void _jumpButtonScroll() {
    if (!scrollController.hasClients ||
        scrollController.position.pixels > 0 ||
        timeline?.allowNewEvent == false) {
      return;
    }
    newBelow.value = 0;
    _returnStack.clear();
    _unreadJumpEventId = null;
  }

  /// Remembers where a jump to [targetId] starts: the built row that quotes
  /// it (the reply the user tapped).
  void _rememberJumpOrigin(String targetId) {
    if (_returning) return;
    final events = conversationEvents;
    if (events == null || !scrollController.hasClients) return;
    final indexes = scrollController.tagMap.keys.toList()..sort();
    for (final index in indexes) {
      if (index < 0 || index >= events.length) continue;
      final event = events[index];
      if (event.inReplyToEventId(includingFallback: false) != targetId) {
        continue;
      }
      if (_returnStack.lastOrNull != event.eventId) {
        _returnStack.add(event.eventId);
        if (_returnStack.length > 8) _returnStack.removeAt(0);
      }
      return;
    }
  }

  Future<void> _insert(int index) async {
    if (index > 0) return;
    final firstEvent = timeline?.events.firstOrNull;
    if (firstEvent != null &&
        _scrolledUp &&
        firstEvent.senderId != firstEvent.room.client.userID &&
        firstEvent.isVisibleInGui &&
        {
          EventTypes.Message,
          EventTypes.Sticker,
          EventTypes.Encrypted,
          PollEventContent.startType,
        }.contains(firstEvent.type)) {
      newBelow.value++;
    }
    // A page of newer history (scrolling down a jumped timeline) is not an
    // arrival: its rows never animate.
    if (timeline?.isRequestingFuture ?? false) return;
    final eventId = firstEvent?.transactionId ?? firstEvent?.eventId;
    animateInEventId = eventId;
    await Future.delayed(ChatLoomThemes.animationDuration);
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
      setTimelineState(() {});
    });
  }

  Future<void>? loadTimelineFuture;

  void retryLoadTimeline() {
    _tryLoadTimeline();
    setTimelineState(() {});
  }

  /// Loads a timeline into the page ([_getTimeline]). A failure is shown in
  /// the list itself, with Try again; it is logged, never a dialog.
  void _loadTimeline({String? eventContextId, ChatTimelinePreload? preload}) {
    timelineLoadFailed = false;
    late final Future<void> load;
    load = _getTimeline(eventContextId: eventContextId, preload: preload)
        .catchError((Object error, StackTrace stack) {
          logBackgroundError('timeline_load', error, stack);
          if (!mounted || !identical(loadTimelineFuture, load)) return;
          setTimelineState(() => timelineLoadFailed = true);
        });
    loadTimelineFuture = load;
  }

  /// Makes [loaded] the page's timeline. No rebuild of its own: the first
  /// build, the load future or the caller's [setTimelineState] follows.
  void _adoptTimeline(Timeline loaded, Room requestedRoom) {
    if (timeline != loaded) timeline?.cancelSubscriptions();
    timeline = loaded;
    _timelineRevision++;
    timelineLoadFailed = false;
    historyError = null;
    _historyPositions.clear();
    _syncJumpButton();
    loaded.requestKeys(onlineKeyBackupOnly: false);
    if (requestedRoom.markedUnread &&
        PersonalPrivacy.policy.allowAutomaticRead) {
      unawaited(requestedRoom.markUnread(false));
    }
  }

  int _timelineLoadGeneration = 0;

  Future<void> _getTimeline({
    String? eventContextId,
    ChatTimelinePreload? preload,
  }) async {
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
          await (preload?.future ??
              requestedRoom.getTimeline(
                onUpdate: updateView,
                onInsert: _insert,
                eventContextId: eventContextId,
              ));
    } catch (e) {
      // Only a failed context lookup can fall back to the current timeline.
      // Initial loading errors must reach the retry UI.
      if (eventContextId == null) rethrow;
      loadedTimeline = await requestedRoom.getTimeline(
        onUpdate: updateView,
        onInsert: _insert,
      );
      // Only the read marker gets the "First unread" way back; any other
      // jump simply stays at the newest messages.
      if (mounted &&
          generation == _timelineLoadGeneration &&
          eventContextId == readMarkerEventId &&
          (e is TimeoutException || e is IOException)) {
        _showScrollUpMaterialBanner(eventContextId);
      }
    }
    // Shown as soon as it is there, even mid-slide (Telegram); the
    // placeholder only appears after the loader grace, so a load that lands
    // during the page push never flashes it.
    if (!mounted || generation != _timelineLoadGeneration) {
      if (loadedTimeline != widget.timeline) {
        loadedTimeline.cancelSubscriptions();
      }
      return;
    }
    _adoptTimeline(loadedTimeline, requestedRoom);
  }

  @override
  String? scrollToEventIdMarker;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      if (mounted) _flushDraft();
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    if (!mounted) return;
    setReadMarker();
  }

  String? _setReadMarkerEventId;
  String? personalSeenEventId;

  void setReadMarker({String? eventId}) {
    // Local only (incognito sends no receipt): clears this chat's
    // notification while its newest message is on screen.
    if (mounted) {
      SeenChatNotifications.seen(
        context,
        [room],
        atBottom: () =>
            !_scrolledUp &&
            activeThreadId == null &&
            this.timeline?.allowNewEvent != false &&
            scrollController.hasClients &&
            scrollController.position.pixels <= 1,
      );
    }
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

    // We do not set read marker if timeline is empty
    final timeline = this.timeline;
    if (timeline == null || timeline.events.isEmpty) return;

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
          // No public receipt for an unaccepted message request (FX-02).
          public:
              AppSettings.sendPublicReadReceipts.value &&
              !isMessageRequest(room),
        )
        .whenComplete(() {
          if (_setReadMarkerEventId == eventId) _setReadMarkerEventId = null;
        });
  }

  NetworkRejectionWatcher? _rejections;

  @override
  void dispose() {
    HiddenMessages.instance.removeListener(_hiddenMessagesChanged);
    _rejections?.dispose();
    MacDesktopCommands.unbindChat(this);
    ConversationJumpTargets.unregister(this);
    _search?.removeListener(_searchChanged);
    _search?.dispose();
    mentionsHandled.dispose();
    _timelineLoadGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    timeline?.cancelSubscriptions();
    timeline = null;
    _flushDraft();
    typingCoolDown?.cancel();
    typingTimeout?.cancel();
    sendController.dispose();
    scrollController.dispose();
    composerInset.dispose();
    newBelow.dispose();
    jumpButtonVisible.dispose();
    timelineHold.dispose();
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
    _loadTimeline(eventContextId: room.fullyRead);

    setTimelineState(() {});
  }

  void setActiveClient(Client c) => setState(() {
    Matrix.of(context).setActiveClient(c);
  });

  bool _personalSending = false;

  /// Over-long texts go as several messages once the user agrees (BR-05).
  final _longText = LongMessageSplitter();
  bool _attachmentPending = false;
  @override
  Future<void> send() async {
    if (_personalSending || _attachmentPending) return;
    if (!mounted) return;
    setState(() => _personalSending = true);
    try {
      // Tap → durable → bubble → server ack (`send.*` probe points).
      await PersonalPerformanceProbe.runInSpan(
        PersonalPerformanceProbe.span('send'),
        _sendPersonal,
      );
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
      if (mounted && _personalSending) {
        setState(() => _personalSending = false);
      }
    }
  }

  /// Telegram/Messenger send: the composer empties the moment the message
  /// is durable in the encrypted outbox (before any network I/O) and is free
  /// for the next message at once. The local echo shows "Sending…", and the
  /// network result updates that bubble ("Not sent · Tap to retry"). The
  /// text stays in the composer only when the outbox could not persist it,
  /// and an old message is never put back into text the user is typing.
  Future<void> _sendPersonal() async {
    final frozenRoom = room;
    final frozenText = sendController.text;
    final frozenReply = replyEvent;
    final frozenEdit = editEvent;
    final frozenThread = activeThreadId;
    final frozenThreadLast = threadLastEventId;
    final frozenPendingText = pendingText;
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
    // Longer than the network takes: offered as several messages (BR-05).
    final toSend = _longText.prepare(
      context,
      frozenRoom,
      frozenText,
      editing: frozenEdit != null,
      command: composerCommandOf(frozenRoom.client, frozenText) != null,
      resend: () => unawaited(send()),
    );
    if (toSend == null) return;
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
    // Compare the text, not the whole editing value: an IME that finishes
    // its composing region on the tap changes the value, not the message.
    if (!sameContext() || sendController.text != frozenText) {
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

    // Only formatting commands (/me, /plain, /html) run as commands. Any
    // other `/word` is a message (Telegram bot commands such as /start), and
    // nothing typed here can sign out, leave a chat or clear data.
    final command = composerCommandOf(frozenRoom.client, frozenText);

    if (currentlyTyping) {
      typingCoolDown?.cancel();
      currentlyTyping = false;
      PersonalPrivacy.setTyping(room, false);
    }

    final sent = _SentComposer(
      room: frozenRoom,
      text: toSend,
      reply: frozenReply,
      edit: frozenEdit,
      pendingText: frozenPendingText,
    );
    if (command != null) {
      // Formatting commands are not outbox messages: the SDK runs them.
      final draft = _consumeSent(sent);
      try {
        await frozenRoom.sendTextEvent(
          frozenText,
          inReplyTo: frozenReply,
          editEventId: frozenEdit?.eventId,
          threadRootEventId: frozenThread,
        );
        await draft;
      } catch (_) {
        await draft;
        _giveBack(sent, 'The command did not run.');
      }
      return;
    }

    final personal = PersonalClient.of(frozenRoom.client);
    final durable = Completer<void>();
    Future<bool>? draft;
    final outcome = personal.sendImmediate(
      frozenRoom,
      toSend,
      replyTo: frozenReply,
      editEventId: frozenEdit?.eventId,
      threadId: frozenThread,
      onDurable: (attempt) {
        PersonalPerformanceProbe.currentSpan?.mark('durable');
        final saved = draft = _consumeSent(sent);
        // Once the draft no longer holds the text, an identical message
        // typed later is a new one, never this attempt resumed.
        unawaited(
          saved.then((stored) async {
            if (stored) await personal.markImmediateConsumed(attempt.actionId);
          }),
        );
        if (!durable.isCompleted) durable.complete();
      },
    );
    // Returns (and frees the composer) as soon as the message is durable;
    // the network phase finishes in the background.
    await Future.any<void>([
      durable.future,
      outcome.then<void>((_) {}, onError: (Object _) {}),
    ]);
    unawaited(_finishSend(personal, sent, outcome, () => draft));
    // The next part of a split text, once this one is durable.
    _longText.continueWith(sendController.text, (rest) {
      if (!mounted || !identical(room, frozenRoom)) return;
      setState(() {
        sendController.value = TextEditingValue(
          text: rest,
          selection: TextSelection.collapsed(offset: rest.length),
        );
        _inputTextIsEmpty = rest.isEmpty;
      });
      unawaited(send());
    });
  }

  /// After the outbox persisted [sent]: empties the composer (keeping only
  /// what was typed after the tap), ends the reply/edit, frees the send
  /// button and saves the remaining text as the encrypted draft. Returns
  /// whether the draft was saved.
  Future<bool> _consumeSent(_SentComposer sent) {
    _storeInputTimeoutTimer?.cancel();
    if (mounted && identical(room, sent.room)) {
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
          pendingText = '';
        }
        _inputTextIsEmpty = sendController.text.isEmpty;
        _personalSending = false;
      });
      // Telegram: sending brings you to your message (not back to a quote).
      if (_scrolledUp) {
        _returnStack.clear();
        unawaited(scrollDown());
      }
    }
    return _persistDraft(sent.room);
  }

  /// Saves the editor's text as [target]'s encrypted draft until it is
  /// stable (typing may continue while a save runs). True on success.
  Future<bool> _persistDraft(Room target) async {
    if (kIsWeb) return true;
    final personal = PersonalClient.of(target.client);
    bool here() => mounted && identical(room, target);
    var text = here() ? _draftText : '';
    try {
      while (true) {
        await personal.saveDraft(target, text);
        _savedDraft = text;
        if (!here() || _draftText == text) return true;
        text = _draftText;
      }
    } catch (_) {
      return false;
    }
  }

  /// What the room's draft holds: the editor, or the text an edit replaced.
  String get _draftText =>
      editEvent != null ? pendingText : sendController.text;

  Future<void> _finishSend(
    PersonalClient personal,
    _SentComposer sent,
    Future<ImmediateSendResult> outcome,
    Future<bool>? Function() draft,
  ) async {
    ImmediateSendResult? result;
    try {
      result = await outcome;
    } catch (_) {}
    if (result?.state == ImmediateSendState.accepted) {
      PersonalPerformanceProbe.currentSpan?.finish('acked');
    }
    var drafted = draft();
    if (drafted == null) {
      if (result?.state != ImmediateSendState.accepted) {
        // Never durable: nothing was sent and the text never left the editor.
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'The message could not be saved for sending, so it was not sent. Your text is kept.',
              ),
            ),
          );
        }
        return;
      }
      // An attempt left by an earlier session had already delivered it.
      drafted = _consumeSent(sent);
    }
    final stored = await drafted;
    if (result == null) return;
    if (result.state == ImmediateSendState.accepted) {
      // Transport acceptance is final even if local draft handling fails.
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
    // The bubble shows "Not sent · Tap to retry" with the same attempt.
    if (personal.localEchoShown(result.transactionId)) return;
    // Rejected before it reached the timeline: nothing was sent, so the
    // attempt is retired and the text comes back.
    unawaited(
      personal.discardImmediate(result.actionId).catchError((Object _) {}),
    );
    _giveBack(sent, switch (result.errorCode) {
      'bridge_unavailable' =>
        'This network does not accept this message right now.',
      'replyUnavailable' => 'The message you replied to is unavailable.',
      'sourceUnavailable' => 'This chat is unavailable.',
      _ => 'The message did not reach the server.',
    });
  }

  /// A message that failed before it had a bubble returns to the composer
  /// when the composer is still empty; otherwise the user decides.
  void _giveBack(_SentComposer sent, String reason) {
    if (!mounted || !identical(room, sent.room)) return;
    void restore() {
      if (!mounted || !identical(room, sent.room)) return;
      final current = sendController.text;
      final quiet =
          (current.isEmpty ||
              (sent.edit != null && current == sent.pendingText)) &&
          replyEvent == null &&
          editEvent == null;
      setState(() {
        final text = quiet || current.isEmpty
            ? sent.text
            : '${sent.text}\n$current';
        if (quiet) {
          replyEvent = sent.reply;
          if (sent.edit != null) {
            pendingText = current;
            editEvent = sent.edit;
          }
        }
        sendController.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
        _inputTextIsEmpty = sendController.text.isEmpty;
      });
      unawaited(_persistDraft(sent.room));
    }

    final current = sendController.text;
    final empty =
        current.isEmpty || (sent.edit != null && current == sent.pendingText);
    if (empty && replyEvent == null && editEvent == null) {
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

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
  /// [asFiles]: photos and videos are sent as files, unchanged; only the
  /// attach menu's "File" entry (Telegram, MD-02). Every other route
  /// compresses on the device without asking (HD chip in the preview).
  Future<void> _pickAttachments(
    Future<List<XFile>> Function() pick, {
    bool asFiles = false,
  }) async {
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
      final result = await showSendFileDialog(
        context,
        SendFileDialog(
          files: files,
          room: frozen.room,
          outerContext: context,
          replyTo: frozen.replyTo,
          initialCaption: originalValue.text,
          sendAsFiles: asFiles,
          composeContext: frozen,
          threadRootEventId: frozen.threadRootEventId,
          threadLastEventId: frozen.threadLastEventId,
        ),
      );
      if (!mounted || result == null) return;
      accepted = true;
      if (!frozen.isCurrent()) return;
      // Text, not the editing value: unfocusing for the picker ends the
      // IME's composing region, which must not keep a sent caption.
      if (sendController.text == originalValue.text &&
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
        if (sendController.text == originalValue.text) {
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
    } catch (error) {
      // Accepted attachments show their own bubbles; only a failure before
      // that is worth a notice (CS-12).
      if (accepted) {
        logBackgroundError('attachment_draft_retained', error);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Couldn’t send the attachments. Your draft is kept.'),
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
        asFiles: type == FileType.any,
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

  Future<void> openGalleryAction() =>
      _pickAttachments(() => selectPhotosOrVideos(context));

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
      // Files, then an image; text first when the Mac copy is text first.
      final media = await readClipboardMedia();
      frozen.validate();
      if (media != null) return media;
      final textData = await Clipboard.getData('text/plain');
      frozen.validate();
      if (textData?.text != null && sendController.value == editorValue) {
        onInputBarChanged(insertComposerText(sendController, textData!.text!));
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
    await showNotionCustomDialog<void>(
      context: context,
      builder: (c) => SendLocationDialog(room: room),
    );
  }

  @override
  List<ConversationMessageAction> messageActions(
    BuildContext context,
    Event event,
  ) => chatMessageActions(this, context, event);

  /// The text a message shows (its newest edit).
  String eventText(Event event) {
    final timeline = this.timeline;
    return (timeline == null ? event : event.getDisplayEvent(timeline)).body;
  }

  void copyEventAction(Event event) {
    Clipboard.setData(ClipboardData(text: eventText(event)));
    if (showEmojiPicker) setState(() => showEmojiPicker = false);
    unawaited(showCopiedNotice(context, L10n.of(context).copiedToClipboard));
  }

  Future<void> reportEventAction(Event event) async {
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
    setState(() => showEmojiPicker = false);
    scaffoldMessenger.showSnackBar(
      SnackBar(content: Text(l10n.contentHasBeenReported)),
    );
  }

  /// Removes a message that failed to send from the outbox and timeline.
  Future<void> deleteErrorEventAction(Event event) async {
    try {
      if (event.status != EventStatus.error) {
        throw Exception(
          'Tried to delete a failed to send event that did not fail',
        );
      }
      await event.cancelSend();
      if (mounted) setTimelineState(() {});
    } catch (e, s) {
      if (!mounted) return;
      ErrorReporter(
        context,
        'Error while delete error events action',
      ).onErrorCallback(e, s);
    }
  }

  /// Delete for everyone: a plain confirm, the bubble goes at once, the
  /// redaction runs in the background (see [MessageDeletions]).
  Future<void> redactEventAction(Event event) async {
    if (showEmojiPicker) setState(() => showEmojiPicker = false);
    Future<String?> Function()? redact;
    if (event.status.isSent && !event.canRedact) {
      // Another account of this bundle sent it.
      final client = currentRoomBundle.firstWhere(
        (cl) => event.senderId == cl!.userID,
        orElse: () => null,
      );
      final room = client?.getRoomById(roomId);
      if (room == null) return;
      redact = () => Event.fromJson(event.toJson(), room).redactEvent();
    }
    await MessageDeletions.delete(
      context,
      event,
      timeline: timeline,
      redact: redact,
      // The rows render the hidden set: re-filter them (a plain setState
      // never reaches the gated timeline rows).
      refresh: () {
        if (mounted) setTimelineState(() {});
      },
    );
  }

  @override
  List<Client?> get currentRoomBundle {
    final clients = Matrix.of(context).currentBundle!;
    clients.removeWhere((c) => c!.getRoomById(roomId) == null);
    return clients;
  }

  bool canRedactEvent(Event event) {
    if (isArchived || event.redacted || !event.status.isSent) return false;
    // Only what the network can delete for everyone (Telegram, Messenger).
    if (!ConversationMessageActions.canDeleteForEveryone(event)) return false;
    final clients = Matrix.of(context).currentBundle;
    return event.canRedact ||
        (clients?.any((cl) => event.senderId == cl!.userID) ?? false);
  }

  bool canPinEvent(Event event) =>
      !isArchived &&
      !event.redacted &&
      room.canChangeStateEvent(EventTypes.RoomPinnedEvents) &&
      event.status.isSent &&
      activeThreadId == null;

  /// Cached per room/sync/trust change; display only, never authorizes.
  @override
  RoundAvailability get roundAvailability => RoundAvailability.of(room);

  @override
  bool get canRecordRoundSilently =>
      PlatformInfos.supportsRoundCapture &&
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
      // The round's bubble is in the chat (with the reply) and shows its own
      // delivery: sending, sent, or "Not sent · Tap to retry". No notice.
      if (identical(replyEvent, frozenReply)) {
        setState(() => replyEvent = null);
      }
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(roundFailureMessage(error))));
    }
  }

  bool canEditEvent(Event event) {
    if (isArchived ||
        !ConversationMessageActions.canEditContent(event, timeline)) {
      return false;
    }
    return currentRoomBundle.any((cl) => event.senderId == cl!.userID);
  }

  Future<void> forwardEventAction(Event event) async {
    final timeline = this.timeline;
    if (timeline == null) return;
    final forward = event.getDisplayEvent(timeline);
    if (!RoundMediaPolicy.fromContent(forward.content).canForward) return;
    if (RoundVideoDescriptor.fromContent(forward.content) != null) {
      await TelegramRoundService.of(
        forward.room.client,
      ).showForwardPicker(context, forward);
      return;
    }
    await showForwardSheet(
      context,
      items: [
        for (final content in GalleryContent.forwardContents(
          forward.content.copy(),
        ))
          ContentShareItem(content),
      ],
    );
  }

  /// Sends a failed message (and its failed edits) again.
  void sendAgainAction(Event event) {
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
      return;
    }
    if (event.status.isError) {
      // Files go through the outgoing media queue (upload shown again).
      unawaited(
        MessageDeliveryActions.sendAgain(event).catchError((Object _) {}),
      );
    }
    final allEditEvents = event
        .aggregatedEvents(timeline!, RelationshipTypes.edit)
        .where((e) => e.status.isError);
    for (final e in allEditEvents) {
      // Outbox edits retry in the outbox (their attempt is completed).
      unawaited(
        MessageDeliveryActions.sendAgain(
          e,
        ).then<void>((_) {}, onError: _reportSendFailure),
      );
    }
    setTimelineState(() {});
  }

  /// A send the user started failed outside the bubble's own status (the
  /// SDK rethrows only a refusal): explain it instead of failing silently.
  void _reportSendFailure(Object error, StackTrace stack) {
    unawaited(
      ErrorReporter.action(
        mounted ? context : null,
        action: ErrorAction.send,
      ).onErrorCallback(error, stack),
    );
  }

  @override
  void replyAction({Event? replyTo}) {
    if (replyTo == null) return;
    setState(() {
      replyEvent = replyTo;
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
    _rememberJumpOrigin(eventId);
    final eventIndex = _rowIndexFor(eventId);

    if (eventIndex == -1) {
      if (!loadContextIfMissing) {
        if (eventId == readMarkerEventId) _showScrollUpMaterialBanner(eventId);
        return;
      }
      setTimelineState(() {
        timeline?.cancelSubscriptions();
        timeline = null;
        _scrolledUp = false;
        _loadTimeline(eventContextId: eventId);
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
      setTimelineState(() {
        scrollToEventIdMarker = eventId;
      });
    }
    await scrollController.scrollToIndex(
      eventIndex,
      duration: ChatLoomThemes.animationDuration,
      preferPosition: AutoScrollPosition.middle,
    );
    _updateScrollController();
    // The landed-on message flashes once (its bubble finishes the flash by
    // itself); clearing the marker keeps later rebuilds from replaying it.
    if (mounted && highlightEvent && scrollToEventIdMarker == eventId) {
      setTimelineState(() => scrollToEventIdMarker = null);
    }
  }

  /// Index of the list row (its `AutoScrollTag` index) showing [eventId], or
  /// -1 when the event is not loaded. A loaded event without a row (reaction,
  /// edit, hidden state; the read marker often sits on one) maps to the
  /// nearest older row instead of shifting every index by one.
  int _rowIndexFor(String eventId) {
    final events = timeline?.events ?? const <Event>[];
    final at = events.indexWhere((event) => event.eventId == eventId);
    if (at == -1) return -1;
    final rows = conversationEvents ?? const <Event>[];
    final rowOf = Map<Event, int>.identity();
    for (var i = 0; i < rows.length; i++) {
      rowOf[rows[i]] = i;
    }
    for (var i = at; i < events.length; i++) {
      final row = rowOf[events[i]];
      if (row != null) return row;
    }
    return rows.isEmpty ? -1 : rows.length - 1;
  }

  Future<void> scrollDown() async {
    if (timeline == null) return;
    // Telegram: the arrow first goes to the first unread message while it
    // is still below what is on screen...
    final unread = _unreadJumpEventId;
    if (unread != null) {
      _unreadJumpEventId = null;
      if (_rowBelowViewport(unread) &&
          await _revealUnread(unread, animate: true)) {
        return;
      }
    }
    // ...and after a quote jump it returns to the reply.
    if (_returnStack.isNotEmpty) {
      final origin = _returnStack.removeLast();
      _returning = true;
      try {
        await scrollToEventId(origin);
      } finally {
        _returning = false;
      }
      return;
    }
    if (!timeline!.allowNewEvent) {
      setTimelineState(() {
        timeline?.cancelSubscriptions();
        timeline = null;
        _scrolledUp = false;
        _loadTimeline();
      });
      await loadTimelineFuture;
    }
    if (!mounted || !scrollController.hasClients) return;
    final position = scrollController.position;
    if (position.pixels <= 0 || ConversationMotion.reduced(context)) {
      scrollController.jumpTo(0);
      return;
    }
    // Near: glide down. Far: jump to one screen above the newest message,
    // then glide, so a long way is neither slow nor an abrupt cut.
    final viewport = position.viewportDimension;
    if (position.pixels > 2 * viewport) scrollController.jumpTo(viewport);
    await scrollController.animateTo(
      0,
      duration: NotionMotion.long,
      curve: NotionMotion.emphasized,
    );
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

  void _startEditingEvent(Event event) {
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
    });
    inputFocus.requestFocus();
  }

  void editEventAction(Event event) => _startEditingEvent(event);

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
      case AddPopupMenuActions.gallery:
        // The combined system photo/video picker (Android photo picker,
        // multi-select); desktops pick media files.
        PlatformInfos.isMobile
            ? openGalleryAction()
            : sendFileAction(type: FileType.media);
        return;
      case AddPopupMenuActions.poll:
        unawaited(StartPollBottomSheet.show(context, room));
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

  /// Pinned messages as the user last set them: a pin or unpin shows at
  /// once and stays until the room's state confirms it (or it fails).
  List<String> get pinnedEventIds {
    final override = _pinnedOverride;
    if (override == null) return room.pinnedEventIds;
    final state = room.getState(EventTypes.RoomPinnedEvents);
    if (_pinnedWritten && !identical(state, _pinnedStateAtWrite)) {
      // The server's copy arrived (ours or a later change elsewhere).
      _pinnedOverride = null;
      return room.pinnedEventIds;
    }
    return override;
  }

  List<String>? _pinnedOverride;
  Object? _pinnedStateAtWrite;
  bool _pinnedWritten = false;
  int _pinnedGeneration = 0;

  Future<void> _setPinned(List<String> pinned, {required bool pinning}) async {
    final generation = ++_pinnedGeneration;
    final messenger = ScaffoldMessenger.of(context);
    final frozen = room;
    setState(() {
      _pinnedOverride = List.unmodifiable(pinned);
      _pinnedStateAtWrite = frozen.getState(EventTypes.RoomPinnedEvents);
      _pinnedWritten = false;
    });
    try {
      await frozen.setPinnedEvents(pinned);
      if (!mounted || generation != _pinnedGeneration) return;
      _pinnedWritten = true;
      // The state event may already have arrived with the response.
      setState(() {});
    } catch (error) {
      if (!mounted || generation != _pinnedGeneration) return;
      setState(() => _pinnedOverride = null);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            pinning
                ? 'Couldn’t pin the message. ${humanErrorText(error)}'
                : 'Couldn’t unpin the message. ${humanErrorText(error)}',
          ),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () {
              if (mounted) unawaited(_setPinned(pinned, pinning: pinning));
            },
          ),
        ),
      );
    }
  }

  /// Unpins at once with Undo (Telegram): pins are reversible.
  Future<void> unpinEvent(String eventId) async {
    final before = pinnedEventIds;
    if (!before.contains(eventId)) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Message unpinned'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            if (mounted) unawaited(_setPinned(before, pinning: true));
          },
        ),
      ),
    );
    await _setPinned([
      for (final id in before)
        if (id != eventId) id,
    ], pinning: false);
  }

  /// Pins [event], or unpins it when it is pinned already.
  void pinEvent(Event event) {
    final pinned = pinnedEventIds;
    if (pinned.contains(event.eventId)) {
      unawaited(unpinEvent(event.eventId));
      return;
    }
    unawaited(_setPinned([...pinned, event.eventId], pinning: true));
    // No bridge carries Matrix pins to the network (BR-06): say so once.
    final network = pinStaysInChatLoom(room);
    if (network != null && !_pinNoticeShown) {
      _pinNoticeShown = true;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('Pinned in ChatLoom only. $network doesn’t show it.'),
          ),
        );
    }
  }

  /// The "pinned in ChatLoom only" notice appears once per app run.
  static bool _pinNoticeShown = false;

  Timer? _storeInputTimeoutTimer;
  static const Duration _storeInputTimeout = Duration(milliseconds: 500);

  /// The text last persisted as this room's draft (null: unknown).
  String? _savedDraft;

  /// Saves a pending debounced draft now (leaving the chat, app paused), so
  /// the last 500 ms of typing are never lost. Fire-and-forget: the encrypted
  /// store keeps its fail-closed semantics; a failure keeps the old draft.
  void _flushDraft() {
    if (kIsWeb) return;
    final pending = _storeInputTimeoutTimer?.isActive ?? false;
    _storeInputTimeoutTimer?.cancel();
    _storeInputTimeoutTimer = null;
    final text = _draftText;
    if (!pending && (_savedDraft == null || _savedDraft == text)) return;
    final target = room;
    unawaited(
      PersonalClient.of(target.client)
          .saveDraft(target, text)
          .then<void>((_) => _savedDraft = text, onError: (Object _) {}),
    );
  }

  @override
  final ValueNotifier<double?> composerInset = ValueNotifier(null);

  /// Follows the composer's measured height. Only the list's spacer and the
  /// jump button listen: a growing reply preview or field never rebuilds
  /// the page or the timeline rows (it used to, once per animation frame).
  void updateInputBarHeight() {
    if (!mounted) return;
    final box = inputBarKey.currentContext?.findRenderObject();
    // Not laid out yet (loading): measure again on the next build.
    if (box is RenderBox && box.hasSize) composerInset.value = box.size.height;
  }

  @override
  void onInputBarChanged(String text) {
    if (_inputTextIsEmpty != text.isEmpty) {
      setState(() {
        _inputTextIsEmpty = text.isEmpty;
      });
    }

    _storeInputTimeoutTimer?.cancel();
    // An edit's text is not a draft: the room keeps the text it replaced.
    if (!kIsWeb && editEvent == null) {
      _storeInputTimeoutTimer = Timer(_storeInputTimeout, () async {
        _storeInputTimeoutTimer = null;
        try {
          await PersonalClient.of(room.client).saveDraft(room, text);
          _savedDraft = text;
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

  /// Raw message source: developer options only (CS-23), also when a
  /// deleted or unknown message row is tapped.
  @override
  void showEventInfo(Event event) {
    if (DeveloperOptions.enabled) event.showInfoDialog(context);
  }

  @override
  void cancelReplyEventAction() => setState(() {
    if (editEvent != null) {
      sendController.text = pendingText;
      pendingText = '';
    }
    replyEvent = null;
    editEvent = null;
  });

  /// System back with a reply or edit open: Telegram cancels it first. A
  /// changed edit asks before its text is discarded.
  void cancelReplyOrEditOnBack() {
    if (editEvent != null) {
      unawaited(_cancelEditWithConfirmation());
    } else {
      cancelReplyEventAction();
    }
  }

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
    if (!mounted) return;

    cancelReplyEventAction();
  }

  late final ValueNotifier<bool> _displayChatDetailsColumn;

  Future<void> toggleDisplayChatDetailsColumn() async {
    await AppSettings.displayChatDetailsColumn.setItem(
      !_displayChatDetailsColumn.value,
    );
    if (!mounted) return;
    _displayChatDetailsColumn.value = !_displayChatDetailsColumn.value;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Size notifications report changes only: measure the first layout.
    if (composerInset.value == null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => updateInputBarHeight(),
      );
    }
    return Actions(
      actions: kIsWeb
          ? {}
          : <Type, Action<Intent>>{
              PasteTextIntent: CallbackAction<PasteTextIntent>(
                onInvoke: (PasteTextIntent intent) =>
                    _handleClipboardImagePaste(),
              ),
              // Mac: Esc in the composer, nothing left to cancel, is Back.
              DismissIntent: ComposerBackAction(
                composer: inputFocus,
                enabled: PlatformInfos.isMacOS,
                onBack: () => unawaited(Navigator.maybePop(context)),
              ),
            },
      child: Row(
        children: [
          // Header and composer glass share one backdrop read.
          Expanded(child: BackdropGroup(child: ChatView(this))),
          ValueListenableBuilder(
            valueListenable: _displayChatDetailsColumn,
            builder: (context, displayChatDetailsColumn, _) =>
                !ChatLoomThemes.isThreeColumnMode(context) ||
                    room.membership != Membership.join ||
                    !displayChatDetailsColumn
                ? const SizedBox(height: double.infinity, width: 0)
                : Container(
                    width: ChatLoomThemes.columnWidth,
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
                        tooltip: 'Close details',
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
  /// Photos and videos in one picker.
  gallery,
  file,
  poll,
  photoCamera,
  videoCamera,
  roundVideoSilent,
  location,
}

/// What one send took from the composer, so the composer can be emptied
/// once the outbox has it and the text given back if it failed early.
class _SentComposer {
  final Room room;
  final String text;
  final Event? reply;
  final Event? edit;

  /// The draft an edit replaced (restored when the edit is sent).
  final String pendingText;

  const _SentComposer({
    required this.room,
    required this.text,
    required this.reply,
    required this.edit,
    required this.pendingText,
  });
}

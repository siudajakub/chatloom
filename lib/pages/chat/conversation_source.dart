// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';

import 'package:chatloom/personal/round_video/round_availability.dart';
import 'package:chatloom/personal/round_video/round_capture_controller.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart' show ChatTheme;
import 'package:scroll_to_index/scroll_to_index.dart';

import 'chat.dart' show AddPopupMenuActions;
import 'conversation_message_menu.dart' show ConversationMessageAction;

/// What [ChatEventList] renders and what its rows invoke. The ordinary chat
/// ([ChatController]) serves one room timeline; the merged person chat serves
/// the interleaved events of several source rooms, each row bound to the
/// timeline of its own room.
abstract interface class ConversationTimelineSource {
  /// Displayed events, newest first; null while the first timeline loads.
  List<Event>? get conversationEvents;

  /// The source timeline an event belongs to (edits, reactions, replies).
  Timeline? timelineFor(Event event);

  /// The room whose client, account config and encryption state the list
  /// shows (the send target in a merged chat).
  Room get room;

  /// Rooms whose voice/round media the list prefetches.
  Set<String> get conversationRoomIds;

  /// Rooms whose typing members are shown under the newest message.
  List<Room> get typingRooms;

  /// Private bubble palette for every row.
  ({ChatTheme? theme}) get conversationPalette;

  AutoScrollController get scrollController;

  /// Measured height of the composer drawn over the list (null before the
  /// first layout). A listenable, so composer growth never rebuilds rows.
  ValueListenable<double?> get composerInset;
  String? get activeThreadId;
  String? get animateInEventId;
  String? get readMarkerEventId;
  String? get scrollToEventIdMarker;
  Set<String> get bigEmojis;
  Set<String> get expandedEventIds;

  // Older history (top of the reversed list).
  bool get canLoadHistory;
  bool get isLoadingHistory;
  bool get historyLoading;
  String? get historyError;

  /// Whether reaching the top of the list should load history by itself.
  bool get autoLoadHistory;
  Future<void> requestHistory([dynamic _]);

  // Newer history of a fragmented (jumped-to) timeline.
  bool get canLoadFuture;
  bool get isLoadingFuture;
  Future<void> requestFuture();

  // Row callbacks.
  void replyAction({Event? replyTo});
  void showEventInfo(Event event);
  void mentionSender(Event event);
  Future<void> scrollToEventId(String eventId, {bool highlightEvent = true});
  void expandEventsFrom(Event event, bool expand);

  /// The long-press menu of [event]: every action that applies to this one
  /// message (there is no multi-selection), in menu order.
  List<ConversationMessageAction> messageActions(
    BuildContext context,
    Event event,
  );
  int? findChildIndexCallback(Key key, Map<String, int> thisEventsKeyMap);

  /// Opens a thread from its root, or null where threads are unavailable.
  void Function(String eventId)? get threadOpener;

  /// Heading over the first message of a series ("via Telegram"), or null.
  String? sourceLabelFor(Event event);

  /// True where a series must break before or after [event] for reasons the
  /// list cannot see (hidden source state events in a merged chat).
  bool seriesBoundary(Event event);

  /// Bridge features must be verified (not merely not refused) to be offered.
  bool get strictCapabilities;
}

/// What the shared composer ([ChatInputRow], [ReplyDisplay],
/// [ChatEmojiPicker]) reads and invokes. [room] is the send target.
abstract interface class ConversationComposerHost {
  Room get room;
  Client get sendingClient;
  TextEditingController get sendController;
  FocusNode get inputFocus;
  Event? get replyEvent;
  Event? get editEvent;
  Timeline? timelineFor(Event event);
  void cancelReplyEventAction();

  /// False while the composer must not send (loading, sending, no source).
  bool get composerEnabled;

  /// The send button shows progress.
  bool get composerBusy;

  /// The source chip at the start of the field.
  Widget buildComposerSource(BuildContext context);

  // Emoji and sticker picker.
  bool get showEmojiPicker;
  void emojiPickerAction();
  void hideEmojiPicker();
  void onEmojiSelected(Category? category, Emoji? emoji);
  void emojiPickerBackspace();
  String? get activeThreadId;
  String? get threadLastEventId;

  // Sending.
  Future<void> send();
  void onInputBarSubmitted(String text);
  void onInputBarChanged(String text);
  Future<void> sendImageFromClipBoard(Uint8List? image);
  void onAddPopupMenuButtonSelected(AddPopupMenuActions choice);
  Future<bool> onVoiceMessageSend(
    String path,
    int duration,
    List<int> waveform,
    String fileName, {
    Future<bool> Function(Room)? confirmTrust,
    Future<Uint8List?> Function(String)? readRecording,
  });

  // Round video.
  bool get roundRecordingMode;
  RoundAvailability get roundAvailability;
  Future<void> toggleRoundRecordingMode();
  bool get canRecordRoundSilently;
  Future<void> recordRound(
    RoundCaptureGestureController gesture, {
    bool silent = false,
  });

  void replyAction({Event? replyTo});

  /// Whether the composer may offer another account of the bundle (the
  /// ordinary chat); the row still checks the bundle itself.
  bool get allowsAccountSwitch;
  List<Client?> get currentRoomBundle;
  void setSendingClient(Client client);
}

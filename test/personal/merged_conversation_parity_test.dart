// SPDX-License-Identifier: AGPL-3.0-or-later
// Parity of the merged person chat with the ordinary chat: both render the
// same timeline (ChatEventList/Message) and composer (ChatInputRow/InputBar).
// Fictional offline fixtures only.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat.dart';
import 'package:chatloom/pages/chat/chat_event_list.dart';
import 'package:chatloom/pages/chat/chat_input_row.dart';
import 'package:chatloom/pages/chat/events/message.dart';
import 'package:chatloom/pages/chat/input_bar.dart';
import 'package:chatloom/pages/chat/undecryptable_chat_hint.dart';
import 'package:chatloom/pages/chat/voice_record_button.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/merged_chat_page.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/date_time_extension.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:personal_core/personal_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

/// A source timeline that has one more (empty) page of history.
class _PagingTimeline extends Timeline {
  int historyRequests = 0;
  bool exhausted = false;
  _PagingTimeline({required super.room, required super.chunk, super.onUpdate});

  @override
  bool get canRequestHistory => !exhausted;

  @override
  Future<void> requestHistory({
    int historyCount = Room.defaultHistoryCount,
    StateFilter? filter,
  }) async {
    historyRequests++;
    exhausted = true;
    onUpdate?.call();
  }
}

class _Room extends ConversationRoom {
  final bool paging;
  Timeline? timeline;
  _Room(super.client, super.id, {super.network, this.paging = false});

  @override
  Future<Timeline> getTimeline({
    void Function(int)? onChange,
    void Function(int)? onRemove,
    void Function(int)? onInsert,
    void Function()? onNewEvent,
    void Function()? onUpdate,
    String? eventContextId,
    int? limit = Room.defaultHistoryCount,
  }) async => timeline = paging
      ? _PagingTimeline(
          room: this,
          chunk: TimelineChunk(events: sourceEvents),
          onUpdate: onUpdate,
        )
      : ConversationTimeline(
          room: this,
          chunk: TimelineChunk(events: sourceEvents),
          onUpdate: onUpdate,
        );
}

/// The ordinary chat's controller on a fixed timeline, without the page.
class _OrdinaryHost extends ChatController {
  final Room source;
  int historyRequests = 0;
  _OrdinaryHost(this.source, Timeline timeline, String marker) {
    sendingClient = source.client;
    inputFocus = FocusNode();
    this.timeline = timeline;
    readMarkerEventId = marker;
  }
  @override
  Room get room => source;
  @override
  bool get canRecordRoundSilently => false;
  @override
  void onInputBarChanged(String text) {}
  @override
  Future<void> requestHistory([_]) async => historyRequests++;
}

Event _older(Room room, String id, String text) {
  final event = Event(
    room: room,
    eventId: id,
    type: EventTypes.Message,
    senderId: '@anna:example.invalid',
    originServerTs: DateTime.utc(2026, 10, 15, 9),
    content: {'msgtype': MessageTypes.Text, 'body': text},
  );
  (room as ConversationRoom).sourceEvents.add(event);
  return event;
}

/// Room a: one older day, a read message, an own message and an unread one;
/// Anna is typing. Room b: one message from another network.
({_Room a, _Room b}) _fixture(
  ConversationClient client, {
  bool paging = false,
  bool typing = false,
}) {
  final a = _Room(client, '!parity-a:example.invalid', paging: paging);
  final b = _Room(client, '!parity-b:example.invalid', network: 'messenger');
  a.state(bridgeFeaturesEventType, {
    'reply': 2,
    'reaction': 2,
    'reaction_count': 1,
    'edit': 2,
    'delete': 2,
  }, key: 'fixture');
  _older(a, r'$old', 'Older fictional message');
  a.message(r'$read', 'Read fictional message');
  a.message(r'$own', 'Own fictional message', outgoing: true, minute: 41);
  final unread = a.message(r'$new', 'Unread fictional message', minute: 42);
  b.message(r'$b1', 'Messenger fictional message', minute: 39);
  a.lastEvent = unread;
  a.roomAccountData['m.fully_read'] = BasicEvent(
    type: 'm.fully_read',
    content: {'event_id': r'$read'},
  );
  if (typing) {
    a.ephemerals['m.typing'] = BasicEvent(
      type: 'm.typing',
      content: {
        'user_ids': ['@anna:example.invalid'],
      },
    );
  }
  return (a: a, b: b);
}

PersonGroup _group(PersonalClient personal, Room a, Room b) => PersonGroup(
  id: 'parity-person',
  name: 'Anna',
  members: [personal.ref(a), personal.ref(b)],
  defaultRoomId: a.id,
);

/// Typing dots animate forever, so [settle] is off while someone types.
Future<void> _mount(
  WidgetTester tester,
  Widget child,
  Client client, {
  bool settle = true,
}) async {
  final state = ConversationMatrix(
    client,
    await SharedPreferences.getInstance(),
  );
  await tester.pumpWidget(
    Provider<MatrixState>.value(
      value: state,
      child: MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: child,
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
}

/// What both chats must show for the shared fixture.
void _expectSharedTimeline(WidgetTester tester, {required int rows}) {
  final context = tester.element(find.byType(ChatEventList));
  expect(find.byType(Message), findsNWidgets(rows));
  // Date separators: the older day and the fixture day.
  expect(
    find.text(DateTime.utc(2026, 10, 15, 9).toLocal().localizedDate(context)),
    findsOneWidget,
  );
  expect(
    find.text(
      DateTime.utc(2026, 10, 16, 16, 40).toLocal().localizedDate(context),
    ),
    findsOneWidget,
  );
  // Unread divider directly under the read message, counting what others
  // sent after it (the own message does not count).
  expect(find.text('1 unread message'), findsOneWidget);
  final divider = tester.getTopLeft(find.text('1 unread message'));
  expect(
    divider.dy,
    greaterThan(tester.getTopLeft(find.text('Read fictional message')).dy),
  );
  expect(
    divider.dy,
    lessThan(tester.getTopLeft(find.text('Own fictional message')).dy),
  );
  // Typing row and the shared composer.
  expect(find.byType(NotionTypingDots), findsOneWidget);
  expect(find.byType(InputBar), findsOneWidget);
  expect(find.byType(ChatInputRow), findsOneWidget);
  if (PlatformInfos.platformCanRecord) {
    expect(find.byType(VoiceRecordButton), findsOneWidget);
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  testWidgets('ordinary and merged chats render the same timeline features', (
    tester,
  ) async {
    // Tall enough that every fixture row (five in the merged chat, each
    // with its source heading) is on screen, not only in the scroll cache.
    await tester.binding.setSurfaceSize(const Size(800, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final client = ConversationClient();
    final rooms = _fixture(client, typing: true);
    final timeline = ConversationTimeline(
      room: rooms.a,
      chunk: TimelineChunk(events: rooms.a.sourceEvents),
    );
    final host = _OrdinaryHost(rooms.a, timeline, r'$read');
    addTearDown(() {
      timeline.cancelSubscriptions();
      host.sendController.dispose();
      host.inputFocus.dispose();
      host.scrollController.dispose();
    });
    await _mount(
      tester,
      Scaffold(
        body: Column(
          children: [
            Expanded(child: ChatEventList(controller: host)),
            ChatInputRow(host),
          ],
        ),
      ),
      client,
      settle: false,
    );
    _expectSharedTimeline(tester, rows: 4);
    // Ordinary rows carry no source heading.
    expect(find.textContaining('via '), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    final personal = ConversationPersonal(client);
    addTearDown(personal.dispose);
    await _mount(
      tester,
      MergedChatPage(
        personal: personal,
        group: _group(personal, rooms.a, rooms.b),
      ),
      client,
      settle: false,
    );
    // The same four rows plus the other network's message.
    _expectSharedTimeline(tester, rows: 5);
    expect(find.text('Messenger fictional message'), findsOneWidget);
    expect(find.text('via WhatsApp'), findsWidgets);
    expect(find.text('via Messenger'), findsOneWidget);
  });

  testWidgets('both chats request older history without a button', (
    tester,
  ) async {
    final client = ConversationClient();
    final rooms = _fixture(client, paging: true);
    final timeline = _PagingTimeline(
      room: rooms.a,
      chunk: TimelineChunk(events: rooms.a.sourceEvents),
    );
    final host = _OrdinaryHost(rooms.a, timeline, '');
    addTearDown(() {
      timeline.cancelSubscriptions();
      host.sendController.dispose();
      host.inputFocus.dispose();
      host.scrollController.dispose();
    });
    await _mount(
      tester,
      Scaffold(body: ChatEventList(controller: host)),
      client,
    );
    expect(host.historyRequests, greaterThan(0));

    await tester.pumpWidget(const SizedBox.shrink());
    final personal = ConversationPersonal(client);
    addTearDown(personal.dispose);
    await _mount(
      tester,
      MergedChatPage(
        personal: personal,
        group: _group(personal, rooms.a, rooms.b),
      ),
      client,
    );
    final source = rooms.a.timeline! as _PagingTimeline;
    expect(source.historyRequests, 1);
    // The limiting source was exhausted, so its oldest row is now covered.
    expect(find.text('Older fictional message'), findsOneWidget);
    expect(find.text('Older messages'), findsNothing);
  });

  testWidgets(
    'merged long-press offers the quick reactions, edit and delete per message',
    (tester) async {
      final client = ConversationClient();
      final rooms = _fixture(client);
      final personal = ConversationPersonal(client);
      addTearDown(personal.dispose);
      await _mount(
        tester,
        MergedChatPage(
          personal: personal,
          group: _group(personal, rooms.a, rooms.b),
        ),
        client,
      );
      final l10n = L10n.of(tester.element(find.byType(ChatEventList)));

      // Long press opens the reaction bar and the message's own actions;
      // there is no selection mode (no count, no selection bar).
      await tester.longPress(find.text('Unread fictional message'));
      await tester.pumpAndSettle();
      expect(find.text('1'), findsNothing);
      for (final emoji in NotionReactions.defaults) {
        expect(find.byKey(ValueKey('reaction-$emoji')), findsOneWidget);
      }
      expect(find.text(l10n.reply), findsOneWidget);
      expect(find.text('Open in source chat'), findsOneWidget);
      expect(find.text(l10n.edit), findsNothing);
      await tester.tap(find.byKey(const ValueKey('reaction-❤️')));
      await tester.pumpAndSettle();
      expect(rooms.a.sentEmoji, ['❤️']);

      // An own message: edit in the composer, delete in its source.
      await tester.longPress(find.text('Own fictional message'));
      await tester.pumpAndSettle();
      expect(find.text(l10n.delete), findsOneWidget);
      await tester.tap(find.text(l10n.edit));
      await tester.pumpAndSettle();
      final editor = tester.widget<TextField>(find.byType(TextField));
      expect(editor.controller!.text, 'Own fictional message');
      await tester.enterText(
        find.byType(TextField),
        'Edited fictional message',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('send_button')));
      await tester.pumpAndSettle();
      final sent = personal.sends.single;
      expect(sent.room, same(rooms.a));
      expect(sent.edit, r'$own');
      expect(sent.text, 'Edited fictional message');
      expect(editor.controller!.text, isEmpty);
    },
  );

  testWidgets('merged composer opens the shared emoji picker', (tester) async {
    final client = ConversationClient();
    final rooms = _fixture(client);
    final personal = ConversationPersonal(client);
    addTearDown(personal.dispose);
    await _mount(
      tester,
      MergedChatPage(
        personal: personal,
        group: _group(personal, rooms.a, rooms.b),
      ),
      client,
    );
    expect(find.byType(EmojiPicker), findsNothing);
    // UX-02: the emoji toggle sits beside "+", no tray to open first.
    await tester.tap(find.byTooltip('Emoji picker'));
    await tester.pumpAndSettle();
    expect(find.byType(EmojiPicker), findsOneWidget);
  });

  testWidgets('merged header counts undecryptable rows of every source', (
    tester,
  ) async {
    final client = ConversationClient();
    final rooms = _fixture(client);
    rooms.b.sourceEvents.insert(
      0,
      Event(
        room: rooms.b,
        eventId: r'$locked',
        type: EventTypes.Encrypted,
        senderId: '@anna:example.invalid',
        originServerTs: DateTime.utc(2026, 10, 16, 16, 43),
        content: {
          'algorithm': AlgorithmTypes.megolmV1AesSha2,
          'ciphertext': 'fictional',
          'session_id': 'fictional-session',
          'sender_key': 'fictional-key',
        },
      ),
    );
    final personal = ConversationPersonal(client);
    addTearDown(personal.dispose);
    await _mount(
      tester,
      MergedChatPage(
        personal: personal,
        group: _group(personal, rooms.a, rooms.b),
      ),
      client,
    );
    final hint = tester.widget<UndecryptableChatHint>(
      find.byType(UndecryptableChatHint),
    );
    expect(hint.count, 1);
  });

  testWidgets('merged header follows the ordinary back button rules', (
    tester,
  ) async {
    final client = ConversationClient();
    final rooms = _fixture(client);
    final personal = ConversationPersonal(client);
    addTearDown(personal.dispose);
    final page = MergedChatPage(
      personal: personal,
      group: _group(personal, rooms.a, rooms.b),
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _mount(tester, page, client);
    expect(find.byTooltip('Back'), findsOneWidget);

    // Two-column mode: the inbox stays beside the person, no back arrow.
    tester.view.physicalSize = const Size(1400, 900);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Back'), findsNothing);
  });
}

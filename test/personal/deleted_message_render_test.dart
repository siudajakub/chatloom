// SPDX-License-Identifier: AGPL-3.0-or-later
// Deleted messages in the conversation: the placeholder, no reactions or
// "edited" after a reload, the own delete at once, reply quotes and kept
// copies (Keep deleted messages). Fictional offline fixtures only.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/events/deleted_message.dart';
import 'package:chatloom/pages/chat/events/kept_message.dart';
import 'package:chatloom/pages/chat/events/message.dart';
import 'package:chatloom/pages/chat/events/message_reactions.dart';
import 'package:chatloom/pages/chat/events/reply_content.dart';
import 'package:chatloom/pages/chat/message_deletion.dart';
import 'package:chatloom/personal/deleted_messages.dart';
import 'package:chatloom/personal/kept_messages.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

const _anna = '@anna:example.invalid';

class _MemoryStorage implements KeptMessagesStorage {
  final records = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, Map<String, dynamic>>> readAll() async => {...records};
  @override
  Future<void> write(String key, Map<String, dynamic> value) async =>
      records[key] = value;
  @override
  Future<void> delete(String key) async => records.remove(key);
}

Map<String, Object?> _redactedBecause(String sender, {int minute = 50}) => {
  'redacted_because': {
    'type': EventTypes.Redaction,
    'event_id': r'$redaction',
    'sender': sender,
    'origin_server_ts': DateTime.utc(
      2026,
      10,
      16,
      16,
      minute,
    ).millisecondsSinceEpoch,
    'content': <String, Object?>{},
  },
};

void main() {
  late ConversationClient client;
  late ConversationRoom room;
  final scroll = ScrollController();
  final timelines = <Timeline>[];

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    await AppSettings.swipeRightToLeftToReply.setItem(false);
  });

  setUp(() async {
    client = ConversationClient();
    room = ConversationRoom(client, '!deleted:example.invalid');
    await AppSettings.hideRedactedEvents.setItem(false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  tearDown(() {
    for (final timeline in timelines) {
      timeline.cancelSubscriptions();
    }
    timelines.clear();
    MessageDeletions.debugReset(client);
    KeptMessages.instance.debugReset(client);
  });

  Timeline timelineOf(List<Event> events) {
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: events),
    );
    timelines.add(timeline);
    return timeline;
  }

  Widget app(Widget child) => Provider<MatrixState>.value(
    value: ConversationMatrix(client, AppSettings.store),
    child: MaterialApp(
      theme: NotionTheme.build(Brightness.dark),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(
        body: Align(alignment: Alignment.bottomCenter, child: child),
      ),
    ),
  );

  Widget message(Event event, Timeline timeline) => Message(
    event,
    bigEmojis: const {},
    onInfoTab: (_) {},
    scrollToEventId: (_) {},
    onSwipe: () {},
    timeline: timeline,
    onMention: () {},
    scrollController: scroll,
    enterThread: null,
  );

  Event related(String id, String type, Map<String, Object?> content) => Event(
    room: room,
    eventId: id,
    senderId: _anna,
    type: type,
    originServerTs: DateTime.utc(2026, 10, 16, 16, 45),
    content: content,
  );

  testWidgets('after a reload: placeholder, no reactions, no "edited"', (
    tester,
  ) async {
    // As the database returns it after a restart: the message is redacted,
    // its reaction and edit are not.
    final deleted = Event(
      room: room,
      eventId: r'$gone',
      senderId: _anna,
      type: EventTypes.Message,
      originServerTs: DateTime.utc(2026, 10, 16, 16, 40),
      content: {},
      unsigned: _redactedBecause(_anna),
    );
    final reaction = related(r'$like', EventTypes.Reaction, {
      'm.relates_to': {
        'rel_type': RelationshipTypes.reaction,
        'event_id': r'$gone',
        'key': '👍',
      },
    });
    final edit = related(r'$edit', EventTypes.Message, {
      'msgtype': 'm.text',
      'body': '* secret edit',
      'm.new_content': {'msgtype': 'm.text', 'body': 'secret edit'},
      'm.relates_to': {'rel_type': RelationshipTypes.edit, 'event_id': r'$gone'},
    });
    final timeline = timelineOf([edit, reaction, deleted]);
    expect(deleted.hasAggregatedEvents(timeline, RelationshipTypes.reaction), isTrue);
    await tester.pumpWidget(app(message(deleted, timeline)));
    await tester.pumpAndSettle();
    expect(find.text('Message deleted'), findsOneWidget);
    expect(find.byIcon(Icons.block), findsOneWidget);
    expect(find.textContaining('Redacted'), findsNothing);
    expect(find.textContaining('secret'), findsNothing);
    expect(find.byType(MessageReactions), findsNothing);
    expect(find.text('(edited)'), findsNothing);
    final label = tester.widget<Text>(find.text('Message deleted'));
    expect(label.style?.fontStyle, FontStyle.italic);
  });

  testWidgets('an own delete turns into "You deleted this message" at once', (
    tester,
  ) async {
    final own = room.message(r'$mine', 'see you at six', outgoing: true);
    final timeline = timelineOf([own]);
    await tester.pumpWidget(app(message(own, timeline)));
    await tester.pumpAndSettle();
    expect(find.text('see you at six'), findsOneWidget);
    MessageDeletions.debugMarkDeleting(own);
    await tester.pumpWidget(app(message(own, timeline)));
    await tester.pumpAndSettle();
    expect(find.text('You deleted this message'), findsOneWidget);
    expect(find.text('see you at six'), findsNothing);
    // The timeline's event keeps its content for a failed delete.
    expect(own.body, 'see you at six');
  });

  testWidgets('a reply quote of a deleted message looks like its placeholder', (
    tester,
  ) async {
    final original = Event(
      room: room,
      eventId: r'$quoted',
      senderId: _anna,
      type: EventTypes.Message,
      originServerTs: DateTime.utc(2026, 10, 16, 16, 30),
      content: {},
      unsigned: _redactedBecause(_anna),
    );
    await tester.pumpWidget(
      app(
        ReplyContent(
          original,
          fill: const Color(0xFF333333),
          textColor: const Color(0xFFCCCCCC),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Message deleted'), findsOneWidget);
    expect(find.byIcon(deletedMessageIcon(DeletedKind.other)), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('Message deleted')).style?.fontStyle,
      FontStyle.italic,
    );
  });

  testWidgets('a kept message shows its text dimmed with a Deleted chip', (
    tester,
  ) async {
    final storage = _MemoryStorage();
    final kept = KeptMessages.instance;
    final previousStorage = kept.storageFor;
    final previousOptions = kept.optionsFor;
    kept
      ..storageFor = ((_) => storage)
      ..optionsFor = () => const KeepDeletedOptions(enabled: true);
    addTearDown(() {
      kept
        ..storageFor = previousStorage
        ..optionsFor = previousOptions;
    });
    final original = room.message(r'$kept', 'the text she deleted');
    final redaction = Event(
      room: room,
      eventId: r'$redaction',
      senderId: _anna,
      type: EventTypes.Redaction,
      originServerTs: DateTime.utc(2026, 10, 16, 16, 50),
      content: {'redacts': r'$kept'},
      redacts: r'$kept',
    );
    await tester.runAsync(
      () => kept.capture(
        RedactionCapture(room: room, redaction: redaction, original: original),
      ),
    );
    expect(storage.records, hasLength(1));
    // Now the SDK applies the redaction.
    original.setRedactionEvent(redaction);
    final timeline = timelineOf([original]);
    await tester.pumpWidget(app(message(original, timeline)));
    await tester.pumpAndSettle();
    expect(find.byType(KeptMessageContent), findsOneWidget);
    expect(find.text('the text she deleted'), findsOneWidget);
    expect(find.text('Deleted'), findsOneWidget);
    expect(find.text('Message deleted'), findsNothing);
    await tester.tap(find.text('the text she deleted'));
    // Past a possible double-tap window of the bubble.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.textContaining('Deleted at'), findsOneWidget);
    expect(find.textContaining('Kept on this device only'), findsOneWidget);
  });
}

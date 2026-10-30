// SPDX-License-Identifier: AGPL-3.0-or-later
// BR-01: on a network that keeps one reaction per person (WhatsApp,
// Messenger, Telegram) a new reaction replaces the old one at once instead
// of being refused. Fictional offline fixtures only.
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/conversation_message_actions.dart';
import 'package:chatloom/pages/chat/events/message_reactions.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'conversation_test_support.dart';

Event _reaction(Event target, String id, String emoji, {int minute = 0}) =>
    Event(
      room: target.room,
      eventId: id,
      senderId: target.room.client.userID!,
      originServerTs: DateTime.utc(2026, 10, 16, 17, minute),
      type: EventTypes.Reaction,
      content: {
        'm.relates_to': {
          'rel_type': RelationshipTypes.reaction,
          'event_id': target.eventId,
          'key': emoji,
        },
      },
    );

Future<
  ({
    BuildContext context,
    ConversationRoom room,
    Event event,
    Timeline timeline,
  })
>
_setUp(
  WidgetTester tester,
  String id, {
  int? limit = 1,
  Map<String, String> own = const {},
}) async {
  final client = ConversationClient();
  final room = ConversationRoom(client, '!$id:example.invalid');
  if (limit == null) {
    room.states.remove(bridgeFeaturesEventType);
  } else {
    room.state(bridgeFeaturesEventType, {
      'id': 'fixture.capabilities',
      'reaction': 2,
      'reaction_count': limit,
      'reply': 2,
    }, key: 'fixture');
  }
  final event = room.message('\$$id-message', 'Fictional text');
  final timeline = Timeline(
    room: room,
    chunk: TimelineChunk(events: [event]),
  );
  addTearDown(timeline.cancelSubscriptions);
  var minute = 0;
  for (final entry in own.entries) {
    timeline.addAggregatedEvent(
      _reaction(event, entry.key, entry.value, minute: ++minute),
    );
  }
  late BuildContext context;
  await tester.pumpWidget(
    Provider<MatrixState>.value(
      value: ConversationMatrix(client, AppSettings.store),
      child: MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: Scaffold(
          body: Builder(
            builder: (c) {
              context = c;
              return MessageReactions(event, timeline);
            },
          ),
        ),
      ),
    ),
  );
  return (context: context, room: room, event: event, timeline: timeline);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  testWidgets('a new reaction replaces the old one at once', (tester) async {
    final f = await _setUp(tester, 'replace', own: {r'$thumbs': '👍'});
    expect(find.text('👍'), findsOneWidget);
    expect(
      await ConversationMessageActions.react(
        f.context,
        f.event,
        f.timeline,
        '❤️',
      ),
      isTrue,
    );
    // The old chip pops out at once (gone once its pop-out is over).
    await tester.pumpAndSettle();
    // Sent, never refused; the old chip is gone before the bridge's
    // redaction arrives, and the client did not redact it itself.
    expect(f.room.sentEmoji, ['❤️']);
    final manager = ConversationMessageActions.coordinator(f.event);
    expect(manager.isReplaced(r'$thumbs'), isTrue);
    expect(find.text('👍'), findsNothing);
    expect(
      ConversationMessageActions.ownReactionKeys(f.event, f.timeline),
      isNot(contains('👍')),
    );
    // Tapping the replaced emoji again waits for the bridge.
    expect(
      ConversationMessageActions.wouldAdd(f.event, f.timeline, '👍'),
      isFalse,
    );
    // The bridge's redaction removes the old reaction: nothing stays hidden.
    f.timeline.aggregatedEvents.clear();
    f.timeline.addAggregatedEvent(_reaction(f.event, r'$heart', '❤️'));
    ConversationMessageActions.reconcile(f.event, f.timeline);
    expect(manager.isReplaced(r'$thumbs'), isFalse);
    expect(
      manager.replacedFor(ConversationMessageActions.scope(f.event)),
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a failed replacement shows the old reaction again', (
    tester,
  ) async {
    final f = await _setUp(tester, 'restore', own: {r'$thumbs': '👍'});
    f.room.reactionFailure = TimeoutException('synthetic');
    await tester.pump();
    expect(
      await ConversationMessageActions.react(
        f.context,
        f.event,
        f.timeline,
        '❤️',
      ),
      isFalse,
    );
    await tester.pump();
    final manager = ConversationMessageActions.coordinator(f.event);
    expect(manager.isReplaced(r'$thumbs'), isFalse);
    expect(find.text('👍'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a replacement the network reverted shows the old one again', (
    tester,
  ) async {
    final f = await _setUp(tester, 'revert', own: {r'$thumbs': '👍'});
    final gate = Completer<String?>();
    f.room.reactionGate = gate;
    final sending = ConversationMessageActions.react(
      f.context,
      f.event,
      f.timeline,
      '❤️',
    );
    await tester.pumpAndSettle();
    // Hidden while the new one is on its way (optimistic; after the old
    // chip's pop-out).
    final manager = ConversationMessageActions.coordinator(f.event);
    expect(manager.isReplaced(r'$thumbs'), isTrue);
    expect(find.text('👍'), findsNothing);
    gate.complete(r'$heart');
    expect(await sending, isTrue);
    // The new reaction synced, then the network refused it and the
    // rejection watcher reverted it: the old one is still there.
    final heart = _reaction(f.event, r'$heart', '❤️');
    f.timeline.addAggregatedEvent(heart);
    ConversationMessageActions.reconcile(f.event, f.timeline);
    expect(manager.isReplaced(r'$thumbs'), isTrue);
    f.timeline.aggregatedEvents[f.event.eventId]![RelationshipTypes.reaction]!
        .remove(heart);
    ConversationMessageActions.reconcile(f.event, f.timeline);
    expect(manager.isReplaced(r'$thumbs'), isFalse);
    await tester.pump();
    expect(find.text('👍'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('three reactions (Telegram Premium) replace only the oldest', (
    tester,
  ) async {
    final f = await _setUp(tester, 'premium', limit: 3);
    f.timeline
      ..addAggregatedEvent(_reaction(f.event, r'$one', '👍', minute: 1))
      ..addAggregatedEvent(_reaction(f.event, r'$two', '🔥', minute: 2))
      ..addAggregatedEvent(_reaction(f.event, r'$three', '😂', minute: 3));
    await ConversationMessageActions.react(
      f.context,
      f.event,
      f.timeline,
      '❤️',
    );
    final manager = ConversationMessageActions.coordinator(f.event);
    expect(manager.isReplaced(r'$one'), isTrue);
    expect(manager.isReplaced(r'$two'), isFalse);
    expect(manager.isReplaced(r'$three'), isFalse);
    expect(f.room.sentEmoji, ['❤️']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a native Matrix room keeps every reaction', (tester) async {
    final f = await _setUp(tester, 'native', limit: null);
    f.timeline.addAggregatedEvent(_reaction(f.event, r'$thumbs', '👍'));
    await ConversationMessageActions.react(
      f.context,
      f.event,
      f.timeline,
      '❤️',
    );
    final manager = ConversationMessageActions.coordinator(f.event);
    expect(manager.isReplaced(r'$thumbs'), isFalse);
    expect(f.room.sentEmoji, ['❤️']);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

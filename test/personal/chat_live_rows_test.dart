// SPDX-License-Identifier: AGPL-3.0-or-later
// An open chat follows private nickname/palette changes, live reply originals
// and member profile changes without rebuilding rows per unrelated change.
// Fictional offline fixtures only.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat.dart';
import 'package:chatloom/pages/chat/chat_app_bar_title.dart';
import 'package:chatloom/pages/chat/chat_event_list.dart';
import 'package:chatloom/pages/chat/chat_view.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/events/message_content.dart';
import 'package:chatloom/pages/chat/events/reply_content.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

class _Controller extends ChatController {
  final Room source;
  _Controller(this.source, Timeline timeline) {
    sendingClient = source.client;
    this.timeline = timeline;
  }
  @override
  Room get room => source;
  @override
  String get readMarkerEventId => '';
}

/// Original lookups outside the loaded timeline: answers from [remote].
class _LookupRoom extends ConversationRoom {
  _LookupRoom(super.client, super.id);
  final remote = <Event?>[];
  int lookups = 0;
  @override
  Future<Event?> getEventById(String eventID) async {
    lookups++;
    return remote.isEmpty ? null : remote.removeAt(0);
  }
}

/// Group chat (no direct-chat mapping), so incoming rows show avatars.
class _GroupClient extends ConversationClient {
  @override
  Map<String, List<String>> get directChats => const {};
}

Event _text(Room room, String id, String body, {int minute = 30}) => Event(
  room: room,
  eventId: id,
  type: EventTypes.Message,
  senderId: '@anna:example.invalid',
  originServerTs: DateTime.utc(2026, 10, 16, 16, minute),
  content: {'msgtype': MessageTypes.Text, 'body': body},
);

Event _reply(Room room, String id, String to) => Event(
  room: room,
  eventId: id,
  type: EventTypes.Message,
  senderId: room.client.userID!,
  originServerTs: DateTime.utc(2026, 10, 16, 16, 45),
  content: {
    'msgtype': MessageTypes.Text,
    'body': 'Fictional answer',
    'm.relates_to': {
      'm.in_reply_to': {'event_id': to},
    },
  },
);

/// Mounts the production chrome/timeline split: [ChatRoomSignals] builds the
/// header, the timeline is its pass-through child. [tick] simulates the chat
/// controller rebuilding the list after a timeline update.
Future<ValueNotifier<int>> _mount(
  WidgetTester tester,
  ChatController controller,
) async {
  final tick = ValueNotifier(0);
  addTearDown(tick.dispose);
  final state = ConversationMatrix(
    controller.room.client,
    await SharedPreferences.getInstance(),
  );
  await tester.pumpWidget(
    Provider<MatrixState>.value(
      value: state,
      child: MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Scaffold(
          body: ChatRoomSignals(
            room: controller.room,
            child: ValueListenableBuilder<int>(
              valueListenable: tick,
              builder: (_, _, _) => ChatEventList(controller: controller),
            ),
            builder: (context, child) => Column(
              children: [
                ChatAppBarTitle(controller),
                Expanded(child: child),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
  return tick;
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 2));
}

Future<int> _rowRebuilds(Future<void> Function() body) async {
  var count = 0;
  debugOnRebuildDirtyWidget = (element, _) {
    final widget = element.widget;
    if (widget is MessageContent || widget is ConversationBubble) count++;
  };
  try {
    await body();
  } finally {
    debugOnRebuildDirtyWidget = null;
  }
  return count;
}

void _notify(PersonalClient personal) =>
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    personal.notifyListeners();

Finder _inReply(String text) => find.descendant(
  of: find.byType(ReplyContent),
  matching: find.textContaining(text),
);

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  testWidgets(
    'open chat follows private nickname and palette, ignores the rest',
    (tester) async {
      final client = ConversationClient();
      final room = ConversationRoom(client, '!live-personal:example.invalid');
      room.message(r'$live-in', 'Incoming fictional message');
      final personal = PersonalClient.of(client);
      addTearDown(personal.dispose);
      final controller = _Controller(room, await room.getTimeline());
      await _mount(tester, controller);
      expect(find.text('Incoming fictional message'), findsOneWidget);
      expect(find.text('Fixture nickname'), findsNothing);

      final unrelated = await _rowRebuilds(() async {
        personal.values['unrelated:fixture'] = {'value': 1};
        _notify(personal);
        await tester.pump();
      });
      expect(unrelated, 0);

      final changed = await _rowRebuilds(() async {
        personal.values['org:${room.id}'] = {
          'nickname': 'Fixture nickname',
          'theme': {'incomingColor': 0xFFF5F5F5, 'backgroundColor': 0xFF202020},
        };
        _notify(personal);
        await tester.pump();
      });
      expect(changed, greaterThan(0));
      expect(find.text('Fixture nickname'), findsOneWidget);
      expect(
        tester
            .widget<ConversationBubble>(find.byType(ConversationBubble))
            .backgroundColor,
        const Color(0xFFF5F5F5),
      );

      // The same values again: nothing to redraw.
      final repeated = await _rowRebuilds(() async {
        _notify(personal);
        await tester.pump();
      });
      expect(repeated, 0);
      await _unmount(tester);
    },
  );

  testWidgets('reply preview picks up an original decrypted in place', (
    tester,
  ) async {
    final client = ConversationClient();
    final room = ConversationRoom(client, '!live-decrypt:example.invalid');
    final encrypted = Event(
      room: room,
      eventId: r'$orig',
      type: EventTypes.Encrypted,
      senderId: '@anna:example.invalid',
      originServerTs: DateTime.utc(2026, 10, 16, 16, 30),
      content: {
        'msgtype': MessageTypes.BadEncrypted,
        'body': 'Fixture undecryptable',
        'algorithm': AlgorithmTypes.megolmV1AesSha2,
        'ciphertext': 'fixture',
      },
    );
    room.sourceEvents.add(encrypted);
    room.sourceEvents.insert(0, _reply(room, r'$answer', r'$orig'));
    final timeline = await room.getTimeline();
    final controller = _Controller(room, timeline);
    final tick = await _mount(tester, controller);
    expect(_inReply('Decrypted fictional original'), findsNothing);

    final index = timeline.events.indexWhere((e) => e.eventId == r'$orig');
    timeline.events[index] = _text(
      room,
      r'$orig',
      'Decrypted fictional original',
    );
    tick.value++;
    await tester.pump();
    expect(_inReply('Decrypted fictional original'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets(
    'missing reply original is refetched with backoff, then follows edits',
    (tester) async {
      final client = ConversationClient();
      final room = _LookupRoom(client, '!live-fetch:example.invalid');
      room.sourceEvents.insert(0, _reply(room, r'$answer', r'$remote'));
      final timeline = await room.getTimeline();
      final controller = _Controller(room, timeline);
      final tick = await _mount(tester, controller);
      expect(room.lookups, 1);
      await tester.pump();
      expect(find.text('Original message unavailable'), findsOneWidget);

      // Timeline updates right away do not hammer the server.
      tick.value++;
      await tester.pump();
      expect(room.lookups, 1);

      room.remote.add(_text(room, r'$remote', 'Fetched fictional original'));
      await tester.pump(const Duration(seconds: 6));
      tick.value++;
      await tester.pump();
      await tester.pump();
      expect(room.lookups, 2);
      expect(_inReply('Fetched fictional original'), findsOneWidget);

      // Found: no further lookups, and an edit arriving later is shown.
      final edit = Event(
        room: room,
        eventId: r'$edit',
        type: EventTypes.Message,
        senderId: '@anna:example.invalid',
        originServerTs: DateTime.utc(2026, 10, 16, 16, 50),
        content: {
          'msgtype': MessageTypes.Text,
          'body': '* Edited fictional original',
          'm.new_content': {
            'msgtype': MessageTypes.Text,
            'body': 'Edited fictional original',
          },
          'm.relates_to': {
            'rel_type': RelationshipTypes.edit,
            'event_id': r'$remote',
          },
        },
      );
      timeline.addAggregatedEvent(edit);
      await tester.pump(const Duration(minutes: 3));
      tick.value++;
      await tester.pump();
      expect(room.lookups, 2);
      expect(_inReply('Edited fictional original'), findsOneWidget);
      await _unmount(tester);
    },
  );

  testWidgets('sender avatar follows loaded member state', (tester) async {
    final client = _GroupClient();
    final room = ConversationRoom(client, '!live-member:example.invalid');
    room.message(r'$member-in', 'Group fictional message');
    final controller = _Controller(room, await room.getTimeline());
    final tick = await _mount(tester, controller);
    Iterable<String?> senderNames() => tester
        .widgetList<Avatar>(find.byType(Avatar))
        .where((a) => a.size == 28)
        .map((a) => a.name);
    expect(senderNames(), contains('Anna'));

    room.state(EventTypes.RoomMember, {
      'membership': 'join',
      'displayname': 'Anna Renamed',
    }, key: '@anna:example.invalid');
    tick.value++;
    await tester.pump();
    expect(senderNames(), contains('Anna Renamed'));
    expect(senderNames(), isNot(contains('Anna')));
    await _unmount(tester);
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
// Opening a chat (review PF-03, UX-09, CS-17): the rows are on screen while
// the page slides in, a far unread position opens at the "N unread
// messages" divider, a failed load says so inline. Fictional offline
// fixtures only; no account, network or storage.
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat.dart';
import 'package:chatloom/pages/chat/chat_event_list.dart';
import 'package:chatloom/pages/chat/chat_timeline_preload.dart';
import 'package:chatloom/pages/chat/chat_view.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

/// A room whose timeline arrives when [gate] completes (a slow store), or
/// fails with [failure].
class _GatedRoom extends ConversationRoom {
  Completer<void>? gate;
  Object? failure;
  int loads = 0;
  _GatedRoom(super.client, super.id);

  @override
  Future<Timeline> getTimeline({
    void Function(int)? onChange,
    void Function(int)? onRemove,
    void Function(int)? onInsert,
    void Function()? onNewEvent,
    void Function()? onUpdate,
    String? eventContextId,
    int? limit = Room.defaultHistoryCount,
  }) async {
    loads++;
    final gate = this.gate;
    if (gate != null) await gate.future;
    final failure = this.failure;
    if (failure != null) throw failure;
    return ConversationTimeline(
      room: this,
      chunk: TimelineChunk(events: sourceEvents),
      onUpdate: onUpdate,
    );
  }
}

/// The inbox: tapping the row preloads the timeline and pushes the chat.
Future<void> _mountInbox(
  WidgetTester tester,
  ConversationClient client,
  Room room,
) async {
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
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  final navigator = Navigator.of(context);
                  await ChatTimelinePreload.warm(room);
                  navigator.push(
                    MaterialPageRoute<void>(
                      builder: (_) => ChatPage(roomId: room.id),
                    ),
                  );
                },
                child: const Text('Open fixture chat'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<ChatController> _mountChat(
  WidgetTester tester,
  ConversationClient client,
  Room room,
) async {
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
        home: ChatPage(roomId: room.id),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return tester.state<ChatController>(find.byType(ChatPageWithRoom));
}

Animation<double> _routeAnimation(WidgetTester tester) =>
    ModalRoute.of(tester.element(find.byType(ChatView)))!.animation!;

/// Every opacity between the list and its rows (the route's own fade is
/// above the page and not counted).
Iterable<double> _rowOpacities(WidgetTester tester) => tester
    .widgetList<Opacity>(
      find.descendant(
        of: find.byType(ChatEventList),
        matching: find.byType(Opacity),
      ),
    )
    .map((opacity) => opacity.opacity);

double _listOpacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find
          .descendant(
            of: find.byType(ChatEventList),
            matching: find.byType(FadeTransition),
          )
          .first,
    )
    .opacity
    .value;

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  late ConversationClient client;
  late _GatedRoom room;
  late ConversationPersonal personal;

  setUp(() {
    client = ConversationClient();
    room = _GatedRoom(client, '!open-path:example.invalid');
    for (var i = 0; i < 30; i++) {
      room.message('\$open-$i', 'Fictional message $i', minute: i);
    }
    personal = ConversationPersonal(client);
    PersonalClient.debugUse(client, personal);
  });
  tearDown(() => personal.dispose());

  group('PF-03 open path', () {
    testWidgets('a preloaded chat has its rows in the first pushed frame', (
      tester,
    ) async {
      await _mountInbox(tester, client, room);
      await tester.tap(find.text('Open fixture chat'));
      // The tap's microtasks (preload) and the push.
      await tester.pump();
      await tester.pump();
      expect(find.byType(ChatView), findsOneWidget);
      expect(_routeAnimation(tester).status, AnimationStatus.forward);
      // The newest rows are there while the page slides in: no placeholder,
      // no per-row entrance, no list fade.
      expect(find.text('Fictional message 29'), findsOneWidget);
      expect(find.byType(ConversationTimelineSkeleton), findsNothing);
      expect(_rowOpacities(tester).every((o) => o == 1), isTrue);
      expect(_listOpacity(tester), 1);
      expect(room.loads, 1);
      // Fully settled well within 350 ms of the tap.
      await tester.pump(const Duration(milliseconds: 340));
      expect(_rowOpacities(tester).every((o) => o == 1), isTrue);
      expect(_listOpacity(tester), 1);
      await _unmount(tester);
    });

    testWidgets('a slow timeline shows mid-slide, without a skeleton flash', (
      tester,
    ) async {
      room.gate = Completer<void>();
      await _mountInbox(tester, client, room);
      await tester.tap(find.text('Open fixture chat'));
      await tester.pump();
      // The tap waits at most ChatTimelinePreload.maxWait, then pushes.
      await tester.pump(ChatTimelinePreload.maxWait);
      await tester.pump();
      expect(find.byType(ChatView), findsOneWidget);
      expect(find.text('Fictional message 29'), findsNothing);
      await tester.pump(const Duration(milliseconds: 60));
      // The placeholder waits for the loader grace: nothing flashes.
      expect(find.byType(ConversationTimelineSkeleton), findsOneWidget);
      expect(find.text('Placeholder message text'), findsNothing);
      room.gate!.complete();
      await tester.pump();
      await tester.pump();
      // Still sliding, already showing the rows (not after the route
      // settled).
      expect(_routeAnimation(tester).status, AnimationStatus.forward);
      expect(find.text('Fictional message 29'), findsOneWidget);
      expect(find.byType(ConversationTimelineSkeleton), findsNothing);
      expect(room.loads, 1);
      // The list replaced the placeholder: one whole-list fade from the
      // refresh opacity, never per row.
      expect(_listOpacity(tester), lessThan(1));
      expect(_listOpacity(tester), greaterThanOrEqualTo(.5));
      expect(_rowOpacities(tester).every((o) => o == 1), isTrue);
      await tester.pump(const Duration(milliseconds: 300));
      expect(_listOpacity(tester), 1);
      expect(_rowOpacities(tester).every((o) => o == 1), isTrue);
      await _unmount(tester);
    });

    testWidgets('a preload of another room is not adopted', (tester) async {
      final other = _GatedRoom(client, '!open-other:example.invalid');
      await ChatTimelinePreload.warm(other);
      await _mountChat(tester, client, room);
      expect(other.loads, 1);
      expect(room.loads, 1);
      expect(find.text('Fictional message 29'), findsOneWidget);
      await _unmount(tester);
    });
  });

  group('UX-09 first unread', () {
    setUp(() {
      // Messages 0–9 read, 10–29 unread (from Anna).
      room.lastEvent = room.sourceEvents.first;
      room.roomAccountData['m.fully_read'] = BasicEvent(
        type: 'm.fully_read',
        content: {'event_id': r'$open-9'},
      );
    });

    testWidgets('opens with the unread divider right under the header', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(400, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = await _mountChat(tester, client, room);
      expect(controller.timelineHold.value, isFalse);
      expect(_listOpacity(tester), 1);
      final divider = find.text('20 unread messages');
      expect(divider, findsOneWidget);
      final header = tester.getBottomLeft(find.byType(AppBar)).dy;
      final top = tester.getTopLeft(divider).dy;
      expect(top, greaterThan(header));
      expect(top, lessThan(header + 48));
      // The divider sits between the last read and the first unread row.
      expect(
        tester.getTopLeft(find.text('Fictional message 9')).dy,
        lessThan(top),
      );
      expect(
        tester.getTopLeft(find.text('Fictional message 10')).dy,
        greaterThan(top),
      );
      // The jump button shows and counts what is unread below.
      expect(controller.jumpButtonVisible.value, isTrue);
      expect(controller.newBelow.value, 20);
      await _unmount(tester);
    });

    testWidgets('the jump button goes to the first unread, then the newest', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(400, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = await _mountChat(tester, client, room);
      final opened = controller.scrollController.position.pixels;
      expect(opened, greaterThan(0));
      // Scroll further up: the divider is now below the screen.
      controller.scrollController.jumpTo(
        controller.scrollController.position.maxScrollExtent,
      );
      await tester.pumpAndSettle();
      expect(find.text('20 unread messages'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('conversation-jump')));
      await tester.pumpAndSettle();
      expect(controller.scrollController.position.pixels, closeTo(opened, 1));
      expect(find.text('20 unread messages'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('conversation-jump')));
      await tester.pumpAndSettle();
      expect(controller.scrollController.position.pixels, 0);
      await _unmount(tester);
    });

    testWidgets('a short unread run opens at the newest message', (
      tester,
    ) async {
      room.roomAccountData['m.fully_read'] = BasicEvent(
        type: 'm.fully_read',
        content: {'event_id': r'$open-27'},
      );
      final controller = await _mountChat(tester, client, room);
      expect(find.text('2 unread messages'), findsOneWidget);
      expect(controller.scrollController.position.pixels, 0);
      expect(controller.newBelow.value, 0);
      await _unmount(tester);
    });
  });

  group('CS-17 load failure', () {
    testWidgets('says so inline with Try again, never in a dialog', (
      tester,
    ) async {
      room.failure = StateError('fixture timeline failure');
      await _mountChat(tester, client, room);
      expect(find.text('Couldn’t load messages'), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('Could not complete this action'), findsNothing);
      room.failure = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Couldn’t load messages'), findsNothing);
      expect(find.text('Fictional message 29'), findsOneWidget);
      expect(room.loads, 2);
      await _unmount(tester);
    });
  });
}
